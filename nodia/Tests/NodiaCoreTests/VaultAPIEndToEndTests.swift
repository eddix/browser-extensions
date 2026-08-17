import XCTest
@testable import NodiaCore

/// The whole path the extension actually travels: real HTTP request → routing
/// → Markdown on disk → reply. Unit tests cover the pieces; this proves they
/// are wired together.
final class VaultAPIEndToEndTests: XCTestCase {
    private var root: URL!
    private var store: VaultStore!
    private var server: LocalHTTPServer!
    private var port: UInt16 = 0
    private let token = "e2e-token"
    private var summarizedContent: [String] = []

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nodia-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Bookmark/01-Inbox"),
            withIntermediateDirectories: true
        )
        store = try VaultStore(vaultRoot: root)

        let captured = Captured()
        self.captured = captured
        let api = VaultAPI(store: store) { links in
            captured.append(links.compactMap { $0.content })
        }

        port = UInt16.random(in: 25000...25999)
        server = LocalHTTPServer(port: port, tokenProvider: { self.token }) { api.handle($0) }
        try server.start()

        let ready = expectation(description: "listening")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { ready.fulfill() }
        wait(for: [ready], timeout: 2)
    }

    override func tearDownWithError() throws {
        server.stop()
        try? FileManager.default.removeItem(at: root)
    }

    /// Thread-safe box: the save callback fires on a connection queue.
    private final class Captured: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func append(_ new: [String]) { lock.lock(); items += new; lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
    }
    private var captured: Captured!

    private func send(
        _ path: String, method: String = "GET", body: Data? = nil, token: String? = nil
    ) throws -> (status: Int, body: String) {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        req.httpMethod = method
        req.httpBody = body
        req.setValue("Bearer \(token ?? self.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var out: (Int, String)?
        let done = expectation(description: "response \(path)")
        URLSession.shared.dataTask(with: req) { data, response, _ in
            out = ((response as? HTTPURLResponse)?.statusCode ?? -1,
                   String(data: data ?? Data(), encoding: .utf8) ?? "")
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 5)
        return try XCTUnwrap(out)
    }

    private func todayInboxText() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        let file = root.appendingPathComponent("Bookmark/01-Inbox/links-\(f.string(from: Date())).md")
        return (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    }

    // MARK: - The real flow

    func testSavingAPageWritesItToDiskAndThenReportsItAsDuplicate() throws {
        let payload = Data("""
        {"title":"Ledger 迁移方案","url":"https://wiki.example.com/wiki/ABC",
         "kind":"bookmark","source":"arc","mode":"single","content":"正文若干"}
        """.utf8)

        let saved = try send("/api/links", method: "POST", body: payload)
        XCTAssertEqual(saved.status, 200)
        XCTAssertTrue(saved.body.contains("\"saved\":1"), saved.body)

        let text = todayInboxText()
        XCTAssertTrue(text.contains("- Ledger 迁移方案"), text)
        XCTAssertTrue(text.contains("- url: https://wiki.example.com/wiki/ABC"))
        XCTAssertTrue(text.contains("#bookmark"))

        // Page text must never be written to the vault — it only feeds the summary.
        XCTAssertFalse(text.contains("正文若干"), "正文不得写入收藏库")
        XCTAssertEqual(captured.all, ["正文若干"], "正文应交给摘要回调")

        // The extension asks this on every tab switch to color its icon.
        let check = try send("/api/check-url?url=https%3A%2F%2Fwiki.example.com%2Fwiki%2FABC")
        XCTAssertTrue(check.body.contains("\"exists\":true"), check.body)

        // Saving the same page again is a duplicate, not a second copy.
        let again = try send("/api/links", method: "POST", body: payload)
        XCTAssertTrue(again.body.contains("\"saved\":0"), again.body)
        XCTAssertTrue(again.body.contains("links-"), again.body)
    }

    func testTodoLandsInItsOwnFileAsACheckbox() throws {
        let payload = Data("""
        {"title":"修 监控组件 的告警","url":"https://tasks.example.net/x","kind":"todo"}
        """.utf8)
        XCTAssertEqual(try send("/api/links", method: "POST", body: payload).status, 200)

        let todo = (try? String(
            contentsOf: root.appendingPathComponent("Bookmark/00-Todo.md"), encoding: .utf8
        )) ?? ""
        XCTAssertTrue(todo.contains("- [ ] 修 监控组件 的告警"), todo)
        XCTAssertTrue(todayInboxText().isEmpty, "待办不应混进当日 inbox")
    }

    func testBulkSaveOfSeveralTabs() throws {
        let payload = Data("""
        [{"title":"A","url":"https://a.example.com/1","kind":"readlater"},
         {"title":"B","url":"https://b.example.com/2","kind":"readlater"}]
        """.utf8)
        let r = try send("/api/links", method: "POST", body: payload)
        XCTAssertTrue(r.body.contains("\"saved\":2"), r.body)
        XCTAssertEqual(store.allEntries().count, 2)
    }

    func testUnauthorizedRequestNeverTouchesTheVault() throws {
        let payload = Data(#"{"title":"偷偷写入","url":"https://evil.example.com/x"}"#.utf8)
        let r = try send("/api/links", method: "POST", body: payload, token: "wrong")

        XCTAssertEqual(r.status, 401)
        XCTAssertEqual(store.allEntries().count, 0, "无效令牌不得写入任何内容")
        XCTAssertTrue(todayInboxText().isEmpty)
    }

    func testSummaryIsPatchedIntoTheSavedEntry() throws {
        let payload = Data(#"{"title":"T","url":"https://example.com/s","content":"x"}"#.utf8)
        XCTAssertEqual(try send("/api/links", method: "POST", body: payload).status, 200)
        XCTAssertTrue(todayInboxText().contains("- summary: \n"), "初始摘要为空")

        XCTAssertTrue(store.updateSummary(url: "https://example.com/s", summary: "一句话摘要"))
        XCTAssertTrue(todayInboxText().contains("- summary: 一句话摘要"), todayInboxText())

        // And it survives a reload from disk, so search can use it.
        let reloaded = try VaultStore(vaultRoot: root)
        XCTAssertEqual(reloaded.allEntries().first?.summary, "一句话摘要")
    }
}
