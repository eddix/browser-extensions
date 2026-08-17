import XCTest
@testable import NodiaCore

final class VaultStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nodia-vault-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Bookmark/01-Inbox"),
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func store() throws -> VaultStore { try VaultStore(vaultRoot: root) }

    private func read(_ relative: String) -> String {
        (try? String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)) ?? ""
    }

    private func inboxFile() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return "Bookmark/01-Inbox/links-\(f.string(from: Date())).md"
    }

    // MARK: - Reading what the old Rust backend wrote

    /// The vault already holds files in this exact shape. If the index can't
    /// read them, every existing bookmark would look new and get re-saved.
    func testIndexesLegacyFormat() throws {
        let legacy = """
        ---
        date: 2026-08-13
        type: browser-links
        ---

        - 内部工具 2.0 用户手册 - 内部文档
          - url: https://wiki.example.com/wiki/NMJWwGpBJiFmRpkkUaYcGnsenIc
          - saved-at: 2026-08-13T11:57:33.496+08:00
          - source: chrome
          - mode: single
          - tag: #from-browser
          - summary:

        """
        try legacy.write(
            to: root.appendingPathComponent("Bookmark/01-Inbox/links-2026-08-13.md"),
            atomically: true, encoding: .utf8
        )

        let s = try store()
        XCTAssertEqual(
            s.checkDuplicate("https://wiki.example.com/wiki/NMJWwGpBJiFmRpkkUaYcGnsenIc"),
            "Bookmark/01-Inbox/links-2026-08-13.md"
        )
        XCTAssertEqual(s.allEntries().count, 1)
        XCTAssertEqual(s.allEntries().first?.title, "内部工具 2.0 用户手册 - 内部文档")
    }

    /// Wiki titles start with a run of zero-width watermark characters. Swift
    /// compares by grapheme cluster and a joiner binds to the preceding space,
    /// so `"- \u{200C}x".hasPrefix("- ")` is false — parsing has to strip
    /// invisibles first or these entries lose their title and summary.
    func testParsesTitleWatermarkedWithZeroWidthCharacters() throws {
        let watermarked = """
        - \u{200C}\u{2062}\u{202C}\u{200B}\u{2064}\u{FEFF}告警助手接入与工单处理跟进 - 内部文档
          - url: https://wiki.example.com/wiki/BFcJwV
          - saved-at: 2026-02-27T17:48:58.755+08:00
          - source: chrome
          - tag: #from-browser
          - summary: 告警助手接入指南与工单处理流程。

        """
        let areas = root.appendingPathComponent("Bookmark/03-Areas")
        try FileManager.default.createDirectory(at: areas, withIntermediateDirectories: true)
        try watermarked.write(
            to: areas.appendingPathComponent("运维工具.md"),
            atomically: true, encoding: .utf8
        )

        let entry = try XCTUnwrap(try store().allEntries().first)
        XCTAssertEqual(entry.title, "告警助手接入与工单处理跟进 - 内部文档")
        XCTAssertEqual(entry.summary, "告警助手接入指南与工单处理流程。")
    }

    func testDuplicateIgnoresFragmentAndTrailingSlash() throws {
        let s = try store()
        _ = s.save([VaultLink(title: "T", url: "https://example.com/a")])
        XCTAssertNotNil(s.checkDuplicate("https://example.com/a/"))
        XCTAssertNotNil(s.checkDuplicate("https://example.com/a#section"))
        XCTAssertNil(s.checkDuplicate("https://example.com/b"))
    }

    // MARK: - Writing

    func testReadlaterWritesLegacyCompatibleBullet() throws {
        let s = try store()
        let result = s.save([VaultLink(
            title: "Some Page", url: "https://example.com/x",
            kind: .readlater, summary: "一句话摘要", source: "arc"
        )])

        XCTAssertEqual(result.saved, 1)
        let text = read(inboxFile())
        XCTAssertTrue(text.contains("---\ndate:"), "新文件应带 frontmatter")
        XCTAssertTrue(text.contains("- Some Page\n"))
        XCTAssertTrue(text.contains("  - url: https://example.com/x\n"))
        XCTAssertTrue(text.contains("  - tag: #from-browser #readlater\n"))
        XCTAssertTrue(text.contains("  - summary: 一句话摘要\n"))
    }

    /// A todo must be a Markdown checkbox, otherwise Obsidian Tasks and the
    /// daily note can't pick it up — the whole reason todos leave the tab bar.
    func testTodoWritesCheckboxIntoItsOwnFile() throws {
        let s = try store()
        _ = s.save([VaultLink(title: "修 监控组件", url: "https://example.com/t", kind: .todo)])

        let todo = read("Bookmark/00-Todo.md")
        XCTAssertTrue(todo.contains("- [ ] 修 监控组件\n"), "todo 应为 checkbox 形式")
        XCTAssertTrue(todo.contains("  - tag: #from-browser #todo\n"))
        XCTAssertTrue(read(inboxFile()).isEmpty, "todo 不应写进当日 inbox 文件")
    }

    func testTodoRoundTripsThroughIndex() throws {
        let s1 = try store()
        _ = s1.save([VaultLink(title: "待办一号", url: "https://example.com/t", kind: .todo)])

        let s2 = try store()   // 重新扫描磁盘
        let entry = try XCTUnwrap(s2.allEntries().first { $0.url == "https://example.com/t" })
        XCTAssertEqual(entry.kind, .todo)
        XCTAssertEqual(entry.title, "待办一号")
    }

    func testSecondSaveOfSameURLIsReportedAsDuplicate() throws {
        let s = try store()
        _ = s.save([VaultLink(title: "A", url: "https://example.com/dup")])
        let again = s.save([VaultLink(title: "A again", url: "https://example.com/dup")])

        XCTAssertEqual(again.saved, 0)
        XCTAssertEqual(again.duplicates.count, 1)
        XCTAssertEqual(again.duplicates.first?.url, "https://example.com/dup")
    }

    func testBracketsInTitleAreEscaped() throws {
        let s = try store()
        _ = s.save([VaultLink(title: "[草稿] 方案", url: "https://example.com/b")])
        XCTAssertTrue(read(inboxFile()).contains("- \\[草稿\\] 方案"))
    }

    // MARK: - Decoding what the extension posts

    func testDecodesExtensionPayloadAndStripsZeroWidth() throws {
        // Wiki titles carry zero-width watermark characters.
        let json = """
        {"title":"\u{200B}\u{2060}下单链路监控打点 - 内部文档",
         "url":"https://wiki.example.com/wiki/W",
         "created_at":"2026-08-13T11:57:33.496Z",
         "window_title":"Arc","source":"arc","mode":"single"}
        """
        let link = try JSONDecoder().decode(VaultLink.self, from: Data(json.utf8))
        XCTAssertEqual(link.title, "下单链路监控打点 - 内部文档")
        XCTAssertEqual(link.kind, .readlater, "缺省类型应为 readlater")
        XCTAssertNotNil(link.createdAt)
    }

    func testDecodesExplicitKind() throws {
        let json = #"{"title":"T","url":"https://e.com","kind":"bookmark"}"#
        let link = try JSONDecoder().decode(VaultLink.self, from: Data(json.utf8))
        XCTAssertEqual(link.kind, .bookmark)
    }

    func testEmptyTitleFallsBackToURL() throws {
        let json = #"{"title":"","url":"https://e.com/x"}"#
        let link = try JSONDecoder().decode(VaultLink.self, from: Data(json.utf8))
        XCTAssertEqual(link.title, "https://e.com/x")
    }
}
