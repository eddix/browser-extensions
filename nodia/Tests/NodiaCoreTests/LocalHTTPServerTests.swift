import XCTest
@testable import NodiaCore

/// The server guards a loopback port that script on any visited page can
/// reach, so these tests are about the boundary as much as the routing.
final class LocalHTTPServerTests: XCTestCase {
    private var server: LocalHTTPServer!
    private var port: UInt16 = 0
    private let token = "test-token-abc"

    override func setUpWithError() throws {
        port = UInt16.random(in: 24000...24999)
        server = LocalHTTPServer(port: port, tokenProvider: { self.token }) { request in
            .ok(["path": request.path, "method": request.method,
                 "body": String(data: request.body, encoding: .utf8) ?? ""])
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

    /// Extracted page text is far bigger than one TCP segment; the reader must
    /// wait for the whole declared body before parsing.
    func testReceivesBodyLargerThanOneSegment() throws {
        let payload = Data(String(repeating: "x", count: 200_000).utf8)
        let r = try request("/api/links", method: "POST", token: token, body: payload)
        XCTAssertEqual(r.status, 200)
        XCTAssertTrue(r.body.contains(String(repeating: "x", count: 1000)))
    }
}
