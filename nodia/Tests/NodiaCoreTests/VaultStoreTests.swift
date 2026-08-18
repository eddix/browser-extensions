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

    /// Those titles start with a run of zero-width watermark characters. Swift
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
        _ = s.save([VaultLink(title: "修监控组件", url: "https://example.com/t", kind: .todo)])

        let todo = read("Bookmark/00-Todo.md")
        XCTAssertTrue(todo.contains("- [ ] 修监控组件\n"), "todo 应为 checkbox 形式")
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
        // Those titles carry zero-width watermark characters.
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

    // MARK: - Keywords

    /// Keywords exist to be searched later, so they must survive a round trip
    /// through disk — that's the whole point of writing them.
    func testKeywordsRoundTripThroughDisk() throws {
        let s1 = try store()
        _ = s1.save([VaultLink(
            title: "Atlas 指引", url: "https://example.com/j",
            kind: .bookmark, summary: "开发流程说明",
            keywords: ["Atlas", "接口定义", "上线流程"]
        )])

        XCTAssertTrue(read(inboxFile()).contains("  - keywords: Atlas, 接口定义, 上线流程\n"))

        let s2 = try store()   // re-read from disk
        let entry = try XCTUnwrap(s2.allEntries().first)
        XCTAssertEqual(entry.keywords, ["Atlas", "接口定义", "上线流程"])
    }

    /// Entries saved before keywords existed must still parse.
    func testEntryWithoutKeywordsStillParses() throws {
        let legacy = """
        - 旧条目
          - url: https://example.com/old
          - tag: #from-browser
          - summary: 旧摘要

        """
        try legacy.write(
            to: root.appendingPathComponent("Bookmark/01-Inbox/links-2026-01-01.md"),
            atomically: true, encoding: .utf8
        )
        let entry = try XCTUnwrap(try store().allEntries().first)
        XCTAssertEqual(entry.summary, "旧摘要")
        XCTAssertTrue(entry.keywords.isEmpty)
    }

    func testNoKeywordsLineWhenEmpty() throws {
        let s = try store()
        _ = s.save([VaultLink(title: "T", url: "https://example.com/n", summary: "x")])
        XCTAssertFalse(read(inboxFile()).contains("keywords:"))
    }

    // MARK: - Keeping up with a folder the user also edits

    /// The vault is Markdown in Obsidian, and the index used to be built once
    /// at startup and never again. Deleting an entry by hand therefore made the
    /// link unsaveable rather than saveable: `check-url` still claimed it was
    /// filed, so the extension offered to refresh a summary that
    /// `update-summary` then couldn't find, and 404'd — until nodia restarted.
    func testDeletingAnEntryByHandLetsTheLinkBeSavedAgain() throws {
        let s = try store()
        _ = s.save([VaultLink(title: "会被删掉", url: "https://example.com/gone")])
        XCTAssertNotNil(s.checkDuplicate("https://example.com/gone"))

        // What Obsidian does when you delete the bullet.
        try "---\ndate: 2026-08-18\ntype: browser-links\n---\n\n".write(
            to: root.appendingPathComponent(inboxFile()), atomically: true, encoding: .utf8
        )

        XCTAssertNil(s.checkDuplicate("https://example.com/gone"),
                     "手工删掉的条目不该还被当成重复")
        XCTAssertEqual(s.save([VaultLink(title: "再存一次", url: "https://example.com/gone")]).saved, 1)
    }

    /// The other direction, and the one the search panel lives on: a file
    /// written by anything else has to show up without a restart.
    func testFileWrittenByAnotherProgramShowsUpInTheIndex() throws {
        let s = try store()
        XCTAssertTrue(s.allEntries().isEmpty)

        try """
        - 别处写的
          - url: https://example.com/elsewhere
          - tag: #from-browser #bookmark
          - summary: 外部写入

        """.write(
            to: root.appendingPathComponent("Bookmark/01-Inbox/links-2026-01-05.md"),
            atomically: true, encoding: .utf8
        )

        XCTAssertEqual(s.allEntries().map(\.url), ["https://example.com/elsewhere"])
    }

    /// A rename changes nothing about a file's size or mtime, so the freshness
    /// check has to look at paths too — otherwise the index goes on naming a
    /// file that no longer exists, which is the one thing `updateSummary`
    /// cannot recover from.
    func testRenamingAFileUpdatesWhereEntriesSayTheyLive() throws {
        let s = try store()
        _ = s.save([VaultLink(title: "会被改名", url: "https://example.com/moved")])
        let original = root.appendingPathComponent(inboxFile())

        let renamed = original.deletingLastPathComponent()
            .appendingPathComponent("links-renamed.md")
        try FileManager.default.moveItem(at: original, to: renamed)

        XCTAssertEqual(s.checkDuplicate("https://example.com/moved"),
                       "Bookmark/01-Inbox/links-renamed.md")
    }

    /// Our own writes move the files too, so the freshness check fires right
    /// after a save. It must not throw away what that save just recorded.
    func testSavingDoesNotLoseTheEntryToItsOwnReindex() throws {
        let s = try store()
        _ = s.save([VaultLink(title: "刚存的", url: "https://example.com/fresh", summary: "摘要")])

        let entry = try XCTUnwrap(s.entry(for: "https://example.com/fresh"))
        XCTAssertEqual(entry.title, "刚存的")
        XCTAssertEqual(entry.summary, "摘要")
        XCTAssertEqual(s.allEntries().count, 1, "重扫不应把刚存的条目变成两条")
    }

    /// `check-url` must give the same answer today and after a restart, and it
    /// used not to: disk got the summary flattened onto one line, memory kept
    /// whatever arrived. Two things now hold this — the index is built from the
    /// flattened form, and the reindex above re-reads the file a save just
    /// touched — so this pins the contract rather than either mechanism.
    func testSummaryIsIndexedTheWayItWillReadBackFromDisk() throws {
        let s1 = try store()
        _ = s1.save([VaultLink(
            title: "多行摘要", url: "https://example.com/multiline",
            summary: "第一行\n\n第二行"
        )])
        let inMemory = try XCTUnwrap(s1.entry(for: "https://example.com/multiline")?.summary)

        let fromDisk = try XCTUnwrap(try store().entry(for: "https://example.com/multiline")?.summary)
        XCTAssertEqual(inMemory, fromDisk)
        XCTAssertEqual(inMemory, "第一行 第二行")
    }
}
