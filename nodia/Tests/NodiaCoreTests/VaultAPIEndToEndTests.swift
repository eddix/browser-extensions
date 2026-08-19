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
        // Stand-in summarizer: records the page text it was handed and returns
        // a fixed summary, so the route can be tested without a model.
        let api = VaultAPI(store: store) { _, _, content, onProgress, done in
            captured.append([content])
            // Emit one progress tick so the polling endpoint has something to
            // report, exactly as a real streamed summary would.
            onProgress(Summarizer.Progress(thinkingChars: 42, textChars: 7))
            done(VaultAPI.Preview(
                summary: content.isEmpty ? nil : "摘要：\(content)",
                keywords: content.isEmpty ? [] : ["关键词A", "关键词B"],
                reason: content.isEmpty ? "没抓到正文" : nil
            ))
        }

        port = UInt16.random(in: 25000...25999)
        server = LocalHTTPServer(port: port, tokenProvider: { self.token }) { req, done in
            api.handle(req, completion: done)
        }
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

    // MARK: - Watching a summary as it's written

    /// The panel polls this once a second during a wait that can run 40s. It
    /// has to report real counters, not just "busy".
    func testProgressEndpointReportsWhatTheModelHasWritten() throws {
        let payload = Data("""
        {"title":"甲","url":"https://example.com/a","kind":"readlater","content":"正文若干"}
        """.utf8)
        let preview = try send("/api/preview?job=job-abc", method: "POST", body: payload)
        XCTAssertEqual(preview.status, 200, preview.body)

        // The stand-in summarizer emitted one tick before finishing, so the
        // entry survives the request and carries those counts.
        let progress = try send("/api/preview-progress?job=job-abc")
        XCTAssertEqual(progress.status, 200)
        XCTAssertTrue(progress.body.contains("\"found\":true"), progress.body)
        XCTAssertTrue(progress.body.contains("\"thinking_chars\":42"), progress.body)
        XCTAssertTrue(progress.body.contains("\"text_chars\":7"), progress.body)
        XCTAssertTrue(progress.body.contains("\"done\":true"),
                      "预览已返回，轮询应看到完成而不是「查无此任务」：\(progress.body)")
    }

    /// A poll for a job that never started is "nothing to show", not an error —
    /// the panel polls before the request has necessarily registered.
    func testProgressForUnknownJobIsNotAnError() throws {
        let r = try send("/api/preview-progress?job=never-started")
        XCTAssertEqual(r.status, 200)
        XCTAssertTrue(r.body.contains("\"found\":false"), r.body)
    }

    func testProgressRequiresAJob() throws {
        XCTAssertEqual(try send("/api/preview-progress").status, 400)
    }

    /// A preview without a job id must still work — the id is optional, and a
    /// client that doesn't poll shouldn't be forced to invent one.
    func testPreviewWithoutJobIdStillSummarizes() throws {
        let payload = Data("""
        {"title":"乙","url":"https://example.com/b","kind":"readlater","content":"正文"}
        """.utf8)
        let r = try send("/api/preview", method: "POST", body: payload)
        XCTAssertEqual(r.status, 200)
        XCTAssertTrue(r.body.contains("摘要：正文"), r.body)
    }

    // MARK: - Re-summarizing what's already saved

    /// The round trip the panel makes: save, come back later, read what it
    /// says, replace it. `check-url` carrying the stored summary is what lets
    /// the panel show the old text without a second request.
    func testSavedSummaryComesBackFromCheckURLAndCanBeReplaced() throws {
        let payload = Data("""
        {"title":"汇丰开户","url":"https://example.com/hsbc","kind":"readlater",
         "summary":"当时的摘要","keywords":["汇丰"],"source":"arc"}
        """.utf8)
        XCTAssertEqual(try send("/api/links", method: "POST", body: payload).status, 200)

        let check = try send("/api/check-url?url=https://example.com/hsbc")
        XCTAssertEqual(check.status, 200)
        XCTAssertTrue(check.body.contains("\"exists\":true"), check.body)
        XCTAssertTrue(check.body.contains("当时的摘要"), check.body)
        XCTAssertTrue(check.body.contains("readlater"), check.body)

        let patch = Data("""
        {"url":"https://example.com/hsbc","summary":"重新生成的摘要","keywords":["汇丰","开户"]}
        """.utf8)
        let updated = try send("/api/update-summary", method: "POST", body: patch)
        XCTAssertEqual(updated.status, 200, updated.body)

        let text = todayInboxText()
        XCTAssertTrue(text.contains("- summary: 重新生成的摘要"), text)
        XCTAssertFalse(text.contains("当时的摘要"), "旧摘要应被替换")
        XCTAssertTrue(text.contains("- keywords: 汇丰, 开户"), text)

        // Updating must not call a model — the text was approved in the panel.
        XCTAssertTrue(captured.all.isEmpty, "更新摘要不该再调一次模型")

        let after = try send("/api/check-url?url=https://example.com/hsbc")
        XCTAssertTrue(after.body.contains("重新生成的摘要"), after.body)
        XCTAssertTrue(after.body.contains("summary_at"), after.body)
    }

    /// An empty summary would erase a good one, so it's refused at the door
    /// rather than written and regretted.
    func testUpdateRefusesAnEmptySummary() throws {
        let payload = Data("""
        {"title":"甲","url":"https://example.com/a","kind":"readlater","summary":"有用的摘要"}
        """.utf8)
        XCTAssertEqual(try send("/api/links", method: "POST", body: payload).status, 200)

        // Empty, whitespace-only, and absent — all three must be refused.
        for body in [#"{"url":"https://example.com/a","summary":""}"#,
                     #"{"url":"https://example.com/a","summary":"   "}"#,
                     #"{"url":"https://example.com/a"}"#] {
            let r = try send("/api/update-summary", method: "POST", body: Data(body.utf8))
            XCTAssertEqual(r.status, 400, body)
        }
        XCTAssertTrue(todayInboxText().contains("- summary: 有用的摘要"), "原摘要必须还在")
    }

    func testUpdatingAURLThatWasNeverSavedIs404() throws {
        let patch = Data(#"{"url":"https://example.com/nope","summary":"x"}"#.utf8)
        XCTAssertEqual(try send("/api/update-summary", method: "POST", body: patch).status, 404)
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
        // Saving no longer summarizes: that happened at /api/preview, and the
        // approved text arrives on the payload. A save must not call a model.
        XCTAssertEqual(captured.all, [], "保存阶段不应再触发摘要")

        // The extension asks this on every tab switch to color its icon.
        let check = try send("/api/check-url?url=https%3A%2F%2Fwiki.example.com%2Fwiki%2FABC")
        XCTAssertTrue(check.body.contains("\"exists\":true"), check.body)

        // Saving the same page again is a duplicate, not a second copy.
        let again = try send("/api/links", method: "POST", body: payload)
        XCTAssertTrue(again.body.contains("\"saved\":0"), again.body)
        XCTAssertTrue(again.body.contains("links-"), again.body)
    }

    // MARK: - Preview before save

    /// The review step: summarize and hand the text back, writing nothing.
    /// Seeing what got captured is what makes closing the tab feel safe, so
    /// this must not touch the vault.
    func testPreviewReturnsSummaryWithoutWritingAnything() throws {
        let payload = Data("""
        {"title":"某文档","url":"https://example.com/p","content":"正文若干"}
        """.utf8)

        let r = try send("/api/preview", method: "POST", body: payload)
        XCTAssertEqual(r.status, 200)
        XCTAssertTrue(r.body.contains("摘要：正文若干"), r.body)
        XCTAssertEqual(captured.all, ["正文若干"], "正文应交给摘要器")

        XCTAssertEqual(store.allEntries().count, 0, "预览不得写入任何内容")
        XCTAssertTrue(todayInboxText().isEmpty)
    }

    /// A page already in the vault is flagged in the panel, so a duplicate is
    /// visible before saving rather than reported after.
    func testPreviewReportsAnExistingEntry() throws {
        _ = store.save([VaultLink(title: "旧的", url: "https://example.com/dup")])

        let payload = Data(#"{"title":"新的","url":"https://example.com/dup","content":"x"}"#.utf8)
        let r = try send("/api/preview", method: "POST", body: payload)
        XCTAssertTrue(r.body.contains("exists_in"), r.body)
        XCTAssertFalse(r.body.contains("\"exists_in\":null"), r.body)
    }

    /// No summary must still be a usable outcome: the reason is shown and the
    /// save buttons stay live — a link with no summary beats no link.
    func testPreviewExplainsWhyThereIsNoSummary() throws {
        let payload = Data(#"{"title":"T","url":"https://example.com/q","content":""}"#.utf8)
        let r = try send("/api/preview", method: "POST", body: payload)
        XCTAssertEqual(r.status, 200)
        XCTAssertTrue(r.body.contains("没抓到正文"), r.body)
    }

    /// The approved summary rides along with the save and lands verbatim —
    /// including edits made in the panel.
    func testApprovedSummaryIsWrittenAsGiven() throws {
        let payload = Data("""
        {"title":"T","url":"https://example.com/s","kind":"bookmark","summary":"我改过的摘要"}
        """.utf8)
        XCTAssertEqual(try send("/api/links", method: "POST", body: payload).status, 200)
        XCTAssertTrue(todayInboxText().contains("- summary: 我改过的摘要"), todayInboxText())
    }

    func testTodoLandsInItsOwnFileAsACheckbox() throws {
        let payload = Data("""
        {"title":"修监控组件的告警","url":"https://tasks.example.net/x","kind":"todo"}
        """.utf8)
        XCTAssertEqual(try send("/api/links", method: "POST", body: payload).status, 200)

        let todo = (try? String(
            contentsOf: root.appendingPathComponent("Bookmark/00-Todo.md"), encoding: .utf8
        )) ?? ""
        XCTAssertTrue(todo.contains("- [ ] 修监控组件的告警"), todo)
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

    // MARK: - Removing

    func testRemoveDeletesTheEntryAndReportsWhere() throws {
        _ = try send("/api/links", method: "POST", body: try JSONSerialization.data(
            withJSONObject: [["title": "要删的", "url": "https://example.com/gone",
                              "kind": "readlater"]]))
        XCTAssertNotNil(store.entry(for: "https://example.com/gone"))

        let (status, body) = try send(
            "/api/remove", method: "POST",
            body: try JSONSerialization.data(withJSONObject: ["url": "https://example.com/gone"])
        )
        XCTAssertEqual(status, 200)
        XCTAssertTrue(body.contains("\"removed\":1"), "实际回包：\(body)")
        XCTAssertNil(store.entry(for: "https://example.com/gone"))
    }

    /// The one endpoint that destroys data must not be reachable without the
    /// token — and it must fail *before* touching anything.
    func testRemoveNeedsTheToken() throws {
        _ = try send("/api/links", method: "POST", body: try JSONSerialization.data(
            withJSONObject: [["title": "A", "url": "https://example.com/keep",
                              "kind": "bookmark"]]))

        let (status, _) = try send(
            "/api/remove", method: "POST",
            body: try JSONSerialization.data(withJSONObject: ["url": "https://example.com/keep"]),
            token: "wrong-token"
        )
        XCTAssertEqual(status, 401)
        XCTAssertNotNil(store.entry(for: "https://example.com/keep"), "鉴权失败不该删掉任何东西")
    }

    func testRemovingSomethingNotSavedIs404() throws {
        let (status, _) = try send(
            "/api/remove", method: "POST",
            body: try JSONSerialization.data(withJSONObject: ["url": "https://example.com/nope"])
        )
        XCTAssertEqual(status, 404)
    }

    func testRemoveRejectsAnEmptyURL() throws {
        let (status, _) = try send(
            "/api/remove", method: "POST",
            body: try JSONSerialization.data(withJSONObject: ["url": "   "])
        )
        XCTAssertEqual(status, 400)
    }

}
