import XCTest
@testable import NodiaCore

/// Rewriting a summary edits a file in the user's long-term archive, in place,
/// years after it was written. The bar is therefore not "the new summary lands"
/// but "nothing else moved" — these tests mostly assert about the lines that
/// were *not* the target.
final class SummaryUpdateTests: XCTestCase {

    private let stamp = "2026-08-17T10:00:00.000+08:00"

    private func rewrite(
        _ text: String, url: String, summary: String, keywords: [String] = []
    ) -> String? {
        VaultStore.rewritingSummary(
            in: text, url: VaultStore.normalize(url),
            summary: summary, keywords: keywords, at: stamp
        )
    }

    // MARK: - The common case

    func testReplacesSummaryLeavingEveryOtherLineByteIdentical() throws {
        let before = """
        ---
        date: 2026-07-01
        type: browser-links
        ---

        - 汇丰香港开户流程
          - url: https://example.com/hsbc
          - saved-at: 2026-07-01T09:00:00.000+08:00
          - source: arc
          - mode: single
          - tag: #from-browser #readlater
          - keywords: 汇丰, 开户
          - summary: 旧摘要

        """
        let after = try XCTUnwrap(rewrite(before, url: "https://example.com/hsbc",
                                          summary: "新摘要", keywords: ["汇丰", "香港", "开户"]))

        XCTAssertTrue(after.contains("  - summary: 新摘要"))
        XCTAssertFalse(after.contains("旧摘要"), "旧摘要应被替换")
        XCTAssertTrue(after.contains("  - keywords: 汇丰, 香港, 开户"))
        XCTAssertTrue(after.contains("  - summary-at: \(stamp)"))

        // saved-at is the date you filed it and must survive a re-summary —
        // that's the whole reason this isn't implemented as delete-and-re-save.
        XCTAssertTrue(after.contains("  - saved-at: 2026-07-01T09:00:00.000+08:00"))
        XCTAssertTrue(after.contains("- 汇丰香港开户流程"))
        XCTAssertTrue(after.contains("type: browser-links"))
        XCTAssertTrue(after.contains("  - tag: #from-browser #readlater"))
    }

    /// Most of the archive predates summarizing entirely: the field simply
    /// isn't there and has to be introduced.
    func testInsertsSummaryWhenTheEntryNeverHadOne() throws {
        let before = """
        - 某篇文档
          - url: https://example.com/a
          - saved-at: 2026-01-02T09:00:00.000+08:00
          - tag: #from-browser #readlater

        """
        let after = try XCTUnwrap(rewrite(before, url: "https://example.com/a",
                                          summary: "补上的摘要", keywords: ["文档"]))
        XCTAssertTrue(after.contains("  - summary: 补上的摘要"))
        XCTAssertTrue(after.contains("  - keywords: 文档"))
        XCTAssertTrue(after.contains("  - tag: #from-browser #readlater"))
    }

    /// The new fields go with the other fields, not after the blank line that
    /// separates entries.
    func testNewFieldsLandInsideTheEntryNotAfterIt() throws {
        let before = """
        - 甲
          - url: https://example.com/a
          - tag: #from-browser #readlater

        - 乙
          - url: https://example.com/b

        """
        let after = try XCTUnwrap(rewrite(before, url: "https://example.com/a", summary: "S"))
        let lines = after.components(separatedBy: "\n")
        let summaryLine = try XCTUnwrap(lines.firstIndex { $0.contains("- summary: S") })
        let nextEntry = try XCTUnwrap(lines.firstIndex { $0 == "- 乙" })
        XCTAssertLessThan(summaryLine, nextEntry)
        XCTAssertTrue(lines[summaryLine].hasPrefix("  - "), "应保持字段缩进")
    }

    // MARK: - Not touching the neighbours

    func testOtherEntriesInTheSameFileAreUntouched() throws {
        let before = """
        - 甲
          - url: https://example.com/a
          - summary: 甲的摘要
          - keywords: 甲

        - 乙
          - url: https://example.com/b
          - summary: 乙的摘要
          - keywords: 乙

        - 丙
          - url: https://example.com/c
          - summary: 丙的摘要

        """
        let after = try XCTUnwrap(rewrite(before, url: "https://example.com/b",
                                          summary: "乙的新摘要", keywords: ["乙", "新"]))
        XCTAssertTrue(after.contains("  - summary: 甲的摘要"))
        XCTAssertTrue(after.contains("  - keywords: 甲"))
        XCTAssertTrue(after.contains("  - summary: 丙的摘要"))
        XCTAssertTrue(after.contains("  - summary: 乙的新摘要"))
        XCTAssertFalse(after.contains("乙的摘要\n"), "只有目标条目该被改写")
        XCTAssertEqual(after.components(separatedBy: "summary-at").count - 1, 1,
                       "只应给目标条目盖时间戳")
    }

    /// Hand-written notes are exactly what a vault accumulates. They are not
    /// ours to reformat.
    func testHandWrittenLinesInsideTheEntrySurvive() throws {
        let before = """
        - 甲
          - url: https://example.com/a
          - summary: 旧
          - 我自己加的一行备注
          - note: 记得跟进

        """
        let after = try XCTUnwrap(rewrite(before, url: "https://example.com/a", summary: "新"))
        XCTAssertTrue(after.contains("  - 我自己加的一行备注"))
        XCTAssertTrue(after.contains("  - note: 记得跟进"))
        XCTAssertTrue(after.contains("  - summary: 新"))
    }

    func testTodoCheckboxEntryKeepsItsCheckbox() throws {
        let before = """
        - [x] 把这件事做完
          - url: https://example.com/t
          - tag: #from-browser #todo

        """
        let after = try XCTUnwrap(rewrite(before, url: "https://example.com/t", summary: "S"))
        XCTAssertTrue(after.contains("- [x] 把这件事做完"), "完成状态不能被抹掉")
        XCTAssertTrue(after.contains("  - summary: S"))
    }

    func testUnknownURLChangesNothing() {
        let before = """
        - 甲
          - url: https://example.com/a
          - summary: 旧

        """
        XCTAssertNil(rewrite(before, url: "https://example.com/zzz", summary: "新"),
                     "找不到就该拒绝，而不是猜一个条目改")
    }

    // MARK: - Value handling

    /// The URL you're standing on carries a fragment; the stored one doesn't.
    /// They're the same page.
    func testMatchesThroughFragmentAndTrailingSlash() throws {
        let before = """
        - 甲
          - url: https://example.com/a
          - summary: 旧

        """
        let after = try XCTUnwrap(rewrite(before, url: "https://example.com/a/#section",
                                          summary: "新"))
        XCTAssertTrue(after.contains("  - summary: 新"))
    }

    /// A field is one line. An edited summary can contain newlines, and writing
    /// them raw would split the value — the parser drops everything after the
    /// break, silently truncating what you thought you saved.
    func testMultiLineSummaryIsFlattenedToOneLine() throws {
        let before = """
        - 甲
          - url: https://example.com/a
          - summary: 旧

        """
        let after = try XCTUnwrap(rewrite(before, url: "https://example.com/a",
                                          summary: "第一段\n\n第二段\n第三段"))
        XCTAssertTrue(after.contains("  - summary: 第一段 第二段 第三段"))
    }

    func testEmptyKeywordsRemovesTheLineRatherThanLeavingItBlank() throws {
        let before = """
        - 甲
          - url: https://example.com/a
          - keywords: 旧词
          - summary: 旧

        """
        let after = try XCTUnwrap(rewrite(before, url: "https://example.com/a",
                                          summary: "新", keywords: []))
        XCTAssertFalse(after.contains("keywords"), "清空后不该留一个空字段")
        XCTAssertTrue(after.contains("  - summary: 新"))
    }

    func testRepeatedUpdatesDoNotAccumulateFields() throws {
        let before = """
        - 甲
          - url: https://example.com/a
          - summary: v1

        """
        let once = try XCTUnwrap(rewrite(before, url: "https://example.com/a",
                                         summary: "v2", keywords: ["a"]))
        let twice = try XCTUnwrap(rewrite(once, url: "https://example.com/a",
                                          summary: "v3", keywords: ["b"]))
        XCTAssertEqual(twice.components(separatedBy: "- summary:").count - 1, 1)
        XCTAssertEqual(twice.components(separatedBy: "- summary-at:").count - 1, 1)
        XCTAssertEqual(twice.components(separatedBy: "- keywords:").count - 1, 1)
        XCTAssertTrue(twice.contains("  - summary: v3"))
        XCTAssertTrue(twice.contains("  - keywords: b"))
    }

    /// Those titles carry zero-width watermarks; the block finder has to see
    /// past them or the entry looks like it isn't there.
    func testFindsEntryUnderAWatermarkedTitle() throws {
        let before = """
        - \u{200C}\u{200B}带水印的标题
          - url: https://example.com/a
          - summary: 旧

        """
        let after = try XCTUnwrap(rewrite(before, url: "https://example.com/a", summary: "新"))
        XCTAssertTrue(after.contains("  - summary: 新"))
        XCTAssertTrue(after.contains("带水印的标题"), "标题原样保留，水印也不动")
    }

    // MARK: - Through the store, onto disk

    private func makeVault(_ contents: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nodia-update-\(UUID().uuidString)")
        let inbox = root.appendingPathComponent("Bookmark/01-Inbox")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        try contents.write(to: inbox.appendingPathComponent("links-2026-07-01.md"),
                           atomically: true, encoding: .utf8)
        return root
    }

    func testUpdateReachesDiskAndTheIndexAgrees() throws {
        let root = try makeVault("""
        - 汇丰香港开户流程
          - url: https://example.com/hsbc
          - saved-at: 2026-07-01T09:00:00.000+08:00
          - tag: #from-browser #readlater
          - summary: 旧摘要

        """)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try VaultStore(vaultRoot: root)
        XCTAssertEqual(store.entry(for: "https://example.com/hsbc")?.summary, "旧摘要")

        let result = store.updateSummary(
            url: "https://example.com/hsbc", summary: "新摘要", keywords: ["汇丰", "开户"]
        )
        XCTAssertTrue(result.success, result.error ?? "")
        XCTAssertEqual(result.file, "Bookmark/01-Inbox/links-2026-07-01.md")

        // In memory, so search reflects it without re-reading the vault.
        let updated = try XCTUnwrap(store.entry(for: "https://example.com/hsbc"))
        XCTAssertEqual(updated.summary, "新摘要")
        XCTAssertEqual(updated.keywords, ["汇丰", "开户"])
        XCTAssertNotNil(updated.summaryAt)

        // And on disk, where a fresh store has to see the same thing.
        let reopened = try VaultStore(vaultRoot: root)
        let reread = try XCTUnwrap(reopened.entry(for: "https://example.com/hsbc"))
        XCTAssertEqual(reread.summary, "新摘要")
        XCTAssertEqual(reread.keywords, ["汇丰", "开户"])
        XCTAssertNotNil(reread.summaryAt, "summary-at 要能被重新读出来")
        XCTAssertEqual(reopened.allEntries().count, 1, "更新不该产生第二条记录")
    }

    /// `summary-at` must not be mistaken for `summary` on the way back in.
    func testSummaryAtDoesNotShadowSummaryWhenParsed() throws {
        let root = try makeVault("""
        - 甲
          - url: https://example.com/a
          - summary: 真正的摘要
          - summary-at: 2026-08-17T10:00:00.000+08:00

        """)
        defer { try? FileManager.default.removeItem(at: root) }

        let entry = try XCTUnwrap(try VaultStore(vaultRoot: root).entry(for: "https://example.com/a"))
        XCTAssertEqual(entry.summary, "真正的摘要")
        XCTAssertEqual(entry.summaryAt, "2026-08-17T10:00:00.000+08:00")
    }

    func testUpdatingAnUnsavedURLFailsWithoutWriting() throws {
        let root = try makeVault("""
        - 甲
          - url: https://example.com/a
          - summary: 旧

        """)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try VaultStore(vaultRoot: root)
        let result = store.updateSummary(url: "https://example.com/never", summary: "x", keywords: [])
        XCTAssertFalse(result.success)
        XCTAssertNotNil(result.error)

        let file = root.appendingPathComponent("Bookmark/01-Inbox/links-2026-07-01.md")
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("- summary: 旧"))
    }

    /// Saved, then re-summarized, then re-saved: the second save must still be
    /// reported as a duplicate, i.e. the update kept the index intact.
    func testEntryStaysADuplicateAfterItsSummaryChanges() throws {
        let root = try makeVault("""
        - 甲
          - url: https://example.com/a
          - summary: 旧

        """)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try VaultStore(vaultRoot: root)
        XCTAssertTrue(store.updateSummary(url: "https://example.com/a",
                                          summary: "新", keywords: ["k"]).success)

        let again = store.save([VaultLink(title: "甲", url: "https://example.com/a")])
        XCTAssertEqual(again.saved, 0)
        XCTAssertEqual(again.duplicates.first?.exists_in, "Bookmark/01-Inbox/links-2026-07-01.md")
    }
}
