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
    private func rawRequest(_ text: String, port: UInt16? = nil, timeout: TimeInterval = 5) -> String {
        let port = port ?? self.port
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
        wait(for: [done], timeout: timeout)
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
    /// A length nobody can parse is not a length of zero.
    ///
    /// Folding it to zero made the request look like one with no body at all,
    /// so a client with a perfectly good token got a 401 — the body it sent had
    /// been silently truncated to nothing on the way in.
    func testUnparseableContentLengthIsRejectedRatherThanTreatedAsEmpty() throws {
        for raw in ["abc", "99999999999999999999", "1.5", ""] {
            let reply = rawRequest(
                "POST /api/links HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: \(raw)\r\n\r\n"
            )
            XCTAssertTrue(reply.hasPrefix("HTTP/1.1 400"),
                          "Content-Length: \(raw) 应当被拒绝，实际收到：\(reply.prefix(40))")
        }
        XCTAssertEqual(try request("/api/health", token: token).status, 200,
                       "服务应当还活着")
    }

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

    // MARK: - What an unauthenticated caller may cost us

    /// Everything about how much memory to allocate is decided before the
    /// token is looked at, so an anonymous caller used to set that budget.
    /// Declaring 200 MiB and delivering it took the app to 427 MB resident;
    /// the declaration alone is enough to refuse on, and refusing on it is
    /// what keeps the bytes from ever being read.
    func testRefusesAnAbsurdlyLargeDeclaredBodyWithoutReadingIt() throws {
        let reply = rawRequest(
            "POST /api/links HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 209715200\r\n\r\n"
        )
        XCTAssertTrue(reply.hasPrefix("HTTP/1.1 413"),
                      "过大的 body 应当被拒绝，实际收到：\(reply.prefix(40))")
        XCTAssertEqual(try request("/api/health", token: token).status, 200, "服务应当还活着")
    }

    /// A header block with no end is not a slow request, it's an open tap: the
    /// buffer holding it was the thing that grew, and it grew past 60 MiB.
    func testRefusesAHeaderBlockThatNeverEnds() throws {
        let reply = rawRequest(
            "GET / HTTP/1.1\r\nX-Pad: " + String(repeating: "a", count: 70_000)
        )
        XCTAssertTrue(reply.hasPrefix("HTTP/1.1 431"),
                      "无休止的 header 应当被拒绝，实际收到：\(reply.prefix(40))")
        XCTAssertEqual(try request("/api/health", token: token).status, 200, "服务应当还活着")
    }

    /// A connection that goes quiet mid-request used to keep its slot forever;
    /// measured at fifteen seconds and still there.
    func testHangsUpOnAConnectionThatStopsMidRequest() throws {
        let (server, port) = try startServer(readTimeout: 0.4) { _, done in done(.ok(["ok": true])) }
        defer { server.stop() }

        XCTAssertTrue(
            connectionClosed(afterSending: "POST /api/links HTTP/1.1\r\nHost: 127.0",
                             to: port, within: 3),
            "半截 header 的连接应当被挂断"
        )
    }

    /// The other half of that timer, and the one worth guarding: summarizing
    /// takes tens of seconds, so the clock has to stop the moment the request
    /// is whole. A timeout that kept running would hang up on our own reply.
    func testTheReadTimeoutDoesNotApplyOnceWeAreAnswering() throws {
        let (server, port) = try startServer(readTimeout: 0.4) { _, done in
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { done(.ok(["slow": true])) }
        }
        defer { server.stop() }

        let reply = rawRequest(
            "GET /api/health HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer \(token)\r\n\r\n",
            port: port, timeout: 8
        )
        XCTAssertTrue(reply.hasPrefix("HTTP/1.1 200"),
                      "慢 handler 的回复应当发得出去，实际收到：\(reply.prefix(40))")
        XCTAssertTrue(reply.contains("\"slow\""))
    }

    // MARK: - Helpers for the two timeout tests

    /// A second server on its own port, so the timeout can be short enough to
    /// watch without making every other test in this file wait ten seconds.
    private func startServer(
        readTimeout: TimeInterval,
        handler: @escaping LocalHTTPServer.Handler
    ) throws -> (server: LocalHTTPServer, port: UInt16) {
        let port = UInt16.random(in: 25000...25999)
        let server = LocalHTTPServer(
            port: port, tokenProvider: { self.token },
            readTimeout: readTimeout, handler: handler
        )
        try server.start()
        let ready = expectation(description: "second listener")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { ready.fulfill() }
        wait(for: [ready], timeout: 2)
        // Binding fails asynchronously, and a port nobody is listening on
        // refuses connections instantly — which `connectionClosed` would
        // happily report as the server hanging up on us.
        XCTAssertTrue(server.isRunning, "第二个 server 没起来：\(server.lastError ?? "?")")
        return (server, port)
    }

    /// Whether the server hung up on us within `within`. Waits through an
    /// `XCTWaiter` of its own so that "it never closed" comes back as a false
    /// to assert on rather than as a timeout failure with no explanation.
    ///
    /// The expectation is constructed directly rather than through
    /// `expectation(description:)`, which hands back one owned by the test case
    /// and only valid to wait on through the test case. Waiting on such an
    /// expectation with a private waiter returns `.completed` straight away —
    /// this helper reported a hang-up that had not happened, and passed against
    /// a server whose timer was disabled.
    private func connectionClosed(
        afterSending text: String, to port: UInt16, within: TimeInterval
    ) -> Bool {
        let conn = NWConnection(host: "127.0.0.1",
                                port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let closed = XCTestExpectation(description: "server hung up")
        var finished = false
        func settle() {
            guard !finished else { return }
            finished = true
            closed.fulfill()
        }
        func pump() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, isComplete, error in
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
        let outcome = XCTWaiter().wait(for: [closed], timeout: within)
        conn.cancel()
        return outcome == .completed
    }
}
