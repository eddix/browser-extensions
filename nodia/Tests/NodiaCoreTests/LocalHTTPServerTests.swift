import XCTest
import Network
@testable import NodiaCore

/// The server guards a loopback port that script on any visited page can
/// reach, so these tests are about the boundary as much as the routing.
final class LocalHTTPServerTests: XCTestCase {
    private var server: LocalHTTPServer!
    private var port: UInt16 = 0
    private let token = "test-token-abc"

    override func setUpWithError() throws {
        port = UInt16.random(in: 24000...24999)
        server = LocalHTTPServer(port: port, tokenProvider: { self.token }) { request, done in
            done(.ok(["path": request.path, "method": request.method,
                      "body": String(data: request.body, encoding: .utf8) ?? ""]))
        }
        try server.start()
        // Give the listener a moment to reach .ready
        let ready = expectation(description: "listening")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { ready.fulfill() }
        wait(for: [ready], timeout: 2)
    }

    override func tearDownWithError() throws {
        server.stop()
    }

    private func request(
        _ path: String,
        method: String = "GET",
        token: String? = nil,
        origin: String? = nil,
        body: Data? = nil
    ) throws -> (status: Int, headers: [AnyHashable: Any], body: String) {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        req.httpMethod = method
        req.httpBody = body
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let origin { req.setValue(origin, forHTTPHeaderField: "Origin") }

        var result: (Int, [AnyHashable: Any], String)?
        let done = expectation(description: "response")
        URLSession.shared.dataTask(with: req) { data, response, _ in
            if let http = response as? HTTPURLResponse {
                result = (http.statusCode, http.allHeaderFields,
                          String(data: data ?? Data(), encoding: .utf8) ?? "")
            }
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 5)
        return try XCTUnwrap(result)
    }

    /// Writes bytes at the socket and returns whatever comes back.
    ///
    /// URLSession is not a way to test a parser: it composes the request itself
    /// and won't emit a header it considers impossible, which is precisely the
    /// class of request that matters here.
    private func rawRequest(_ text: String) -> String {
        let conn = NWConnection(host: "127.0.0.1",
                                port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let done = expectation(description: "raw reply")
        var reply = Data()
        var finished = false
        func settle() {
            guard !finished else { return }
            finished = true
            done.fulfill()
        }
        func pump() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { chunk, _, isComplete, error in
                if let chunk { reply.append(chunk) }
                if isComplete || error != nil { settle() } else { pump() }
            }
        }
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                conn.send(content: Data(text.utf8), completion: .contentProcessed { _ in })
                pump()
            case .failed, .cancelled:
                settle()
            default:
                break
            }
        }
        conn.start(queue: .global())
        wait(for: [done], timeout: 5)
        conn.cancel()
        return String(data: reply, encoding: .utf8) ?? ""
    }

    // MARK: - The boundary

    func testRejectsRequestWithoutToken() throws {
        let r = try request("/api/health")
        XCTAssertEqual(r.status, 401)
    }

    func testRejectsWrongToken() throws {
        let r = try request("/api/health", token: "not-the-token")
        XCTAssertEqual(r.status, 401)
    }

    func testAcceptsCorrectToken() throws {
        let r = try request("/api/health", token: token)
        XCTAssertEqual(r.status, 200)
        XCTAssertTrue(r.body.contains("/api/health"))
    }

    /// A page on the open web must not be able to read replies, even if it
    /// somehow learned the token. This is what the old backend got wrong by
    /// allowing every origin.
    func testDoesNotGrantCORSToWebPages() throws {
        let r = try request("/api/health", token: token, origin: "https://evil.example.com")
        XCTAssertNil(r.headers["Access-Control-Allow-Origin"],
                     "普通网页不应拿到 CORS 许可")
    }

    func testGrantsCORSToExtensionOrigin() throws {
        let origin = "chrome-extension://abcdefghijklmnop"
        let r = try request("/api/health", token: token, origin: origin)
        XCTAssertEqual(r.headers["Access-Control-Allow-Origin"] as? String, origin)
    }

    // MARK: - Transport

    func testParsesQueryString() throws {
        let r = try request("/api/check-url?url=https%3A%2F%2Fe.com%2Fa", token: token)
        XCTAssertEqual(r.status, 200)
        XCTAssertTrue(r.body.contains("/api/check-url"))
    }

    /// The parser runs before the token check, so anything that can kill it can
    /// be reached by any process able to open a loopback socket. This request
    /// used to take the whole app down: `Content-Length: -1` walked past the
    /// "have we got the body yet" guard and into `prefix`, which traps on a
    /// negative count — measured end to end as exit 133.
    ///
    /// The second half of the test is the half that matters. A server that
    /// answers 400 and then dies has not been fixed.
    func testNegativeContentLengthIsRejectedRatherThanCrashing() throws {
        let reply = rawRequest("POST /api/links HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: -1\r\n\r\n")
        XCTAssertTrue(reply.hasPrefix("HTTP/1.1 400"),
                      "畸形的 Content-Length 应当被拒绝，实际收到：\(reply.prefix(40))")
        XCTAssertEqual(try request("/api/health", token: token).status, 200,
                       "服务应当还活着")
    }

    /// Extracted page text is far bigger than one TCP segment; the reader must
    /// wait for the whole declared body before parsing.
    func testReceivesBodyLargerThanOneSegment() throws {
        let payload = Data(String(repeating: "x", count: 200_000).utf8)
        let r = try request("/api/links", method: "POST", token: token, body: payload)
        XCTAssertEqual(r.status, 200)
        XCTAssertTrue(r.body.contains(String(repeating: "x", count: 1000)))
    }
}
