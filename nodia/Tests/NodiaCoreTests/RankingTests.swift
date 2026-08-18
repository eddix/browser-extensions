import XCTest
@testable import NodiaCore

/// Ranking decides whether a feature is discoverable at all. A quick-open template
/// that exists but never surfaces is, from the keyboard, the same as one that
/// doesn't exist — which is exactly what happened before these rules.
final class RankingTests: XCTestCase {

    private func tab(_ title: String, url: String = "https://x.com/a", active: Double = 100) -> TabEntry {
        TabEntry(id: title, title: title, url: url, spaceTitle: "S", lastActiveAt: active)
    }

    private func template(_ name: String) -> TabEntry {
        TabEntry(id: "qo:\(name)", title: name, url: "https://x-{r}.com/a",
                 spaceTitle: "快速打开", lastActiveAt: 0, origin: .quickOpen)
    }

    /// The bug this file exists for: a template tied with nine open tabs on
    /// score, then lost every tiebreak because its lastActiveAt is 0.
    func testTemplateOutranksTabsThatMerelyContainTheQuery() throws {
        let rows = [
            tab("什么是 MetricsDuty - 观测诊断 - 文档中心"),
            tab("报警值班计划列表 | Metrics-I18N"),
            tab("日志关键字检索 | Metrics-US"),
            template("Metrics 服务大盘"),
        ]
        let top = try XCTUnwrap(FuzzyMatcher.rank(rows, query: "metrics").first)
        XCTAssertEqual(top.origin, .quickOpen)
        XCTAssertEqual(top.title, "Metrics 服务大盘")
    }

    /// Why it wins: starting with the query beats containing it.
    func testPrefixMatchScoresHigherThanMidStringMatch() throws {
        let needle = Array("metrics")
        let prefix = try XCTUnwrap(FuzzyMatcher.score(tab("metrics 服务大盘"), query: "metrics", needle: needle))
        let middle = try XCTUnwrap(FuzzyMatcher.score(tab("什么是 metricsduty"), query: "metrics", needle: needle))
        XCTAssertGreaterThan(prefix, middle)
    }

    /// The tiebreak only applies at equal scores — a genuinely better match
    /// still wins regardless of where it came from.
    func testBetterMatchBeatsTemplatePriority() throws {
        let rows = [template("Metrics 服务大盘"), tab("Metrics")]
        let top = try XCTUnwrap(FuzzyMatcher.rank(rows, query: "metrics").first)
        XCTAssertEqual(top.origin, .arcTab, "完全匹配的标签页应胜过模板")
    }

    /// The ⌘⇧K ordering rule, stated as a test: on a genuine tie the open tab
    /// wins, over both a template and a saved link. Reusing a window you
    /// already have is the behaviour the whole panel is meant to encourage —
    /// and it costs the template nothing, since ⌘T lists every one of them.
    func testOpenTabWinsTheTieOverTemplateAndVault() throws {
        let saved = TabEntry(id: "v", title: "Ledger", url: "https://x.com/a",
                             spaceTitle: "档案", lastActiveAt: 0, origin: .vault)
        let rows = [saved, template("Ledger"), tab("Ledger", active: 0)]
        let ranked = FuzzyMatcher.rank(rows, query: "ledger")
        XCTAssertEqual(ranked.map(\.origin), [.arcTab, .quickOpen, .vault],
                       "同分时：已打开标签 > 模板 > 档案收藏")
    }

    /// Two templates that tie on everything else are ordered by how much you
    /// use them — the `lastActiveAt` slot carries a usage score for a row that
    /// has no "last active" of its own.
    func testMoreUsedTemplateWinsTheTie() throws {
        let often = TabEntry(id: "qo:A", title: "ConfigHub 配置", url: "https://x.com/{a}",
                             spaceTitle: "快速打开", lastActiveAt: 4.2, origin: .quickOpen)
        let rarely = TabEntry(id: "qo:B", title: "ConfigHub 权限", url: "https://x.com/{a}",
                              spaceTitle: "快速打开", lastActiveAt: 0.3, origin: .quickOpen)
        let ranked = FuzzyMatcher.rank([rarely, often], query: "confighub")
        XCTAssertEqual(ranked.map(\.title), ["ConfigHub 配置", "ConfigHub 权限"])
    }

    /// Swift's sort isn't stable, so rows that tie on *everything* — two unused
    /// templates on a fresh install, say — used to come back in whatever order
    /// the sort happened to leave them, differing between keystrokes.
    func testFullyTiedRowsComeBackInAStableOrder() throws {
        let rows = (1...6).map {
            TabEntry(id: "qo:\($0)", title: "模板 \($0)", url: "https://x.com/a",
                     spaceTitle: "快速打开", lastActiveAt: 0, origin: .quickOpen)
        }
        let first = FuzzyMatcher.rank(rows, query: "模板").map(\.id)
        XCTAssertEqual(FuzzyMatcher.rank(rows.reversed(), query: "模板").map(\.id), first,
                       "同分行的顺序不该取决于输入顺序")
        XCTAssertEqual(first, rows.map(\.id).sorted())
    }

    /// A live tab beats a saved copy of the same page: switching to an open
    /// window beats reopening the URL.
    func testLiveTabOutranksSavedLinkOnATie() throws {
        let saved = TabEntry(id: "v", title: "同名页面", url: "https://x.com/a",
                             spaceTitle: "档案", lastActiveAt: 0, origin: .vault)
        let live = tab("同名页面", active: 0)
        let top = try XCTUnwrap(FuzzyMatcher.rank([saved, live], query: "同名").first)
        XCTAssertEqual(top.origin, .arcTab)
    }

    /// With no query the list is recency-ordered, so templates and saved links
    /// (both lastActiveAt 0) must not push live tabs down.
    func testEmptyQueryStillOrdersByRecency() throws {
        let rows = [template("T"), tab("最近用过的", active: 999)]
        let top = try XCTUnwrap(FuzzyMatcher.rank(rows, query: "").first)
        XCTAssertEqual(top.title, "最近用过的")
    }

    // MARK: - Space names are not searchable

    /// A tab must not match just because it sits in a Space of that name.
    /// Measured on a real sidebar, "ledger" pulled in 23 such tabs against 21
    /// genuine ones — a performance-review doc among them.
    func testTabDoesNotMatchItsSpaceName() {
        let inLedgerSpace = TabEntry(
            id: "t", title: "某人的绩效面谈记录 - 内部文档",
            url: "https://wiki.example.com/wiki/abc",
            spaceTitle: "Ledger", lastActiveAt: 100
        )
        XCTAssertTrue(FuzzyMatcher.rank([inLedgerSpace], query: "ledger").isEmpty,
                      "仅因所在 Workspace 名而命中的标签不应出现")
    }

    /// The same field on a saved link holds its kind, which *is* worth
    /// matching — searching 待办 should filter to todos.
    func testSavedLinkStillMatchesItsKindLabel() throws {
        let todo = TabEntry(
            id: "v", title: "修监控组件", url: "https://x.com/a",
            spaceTitle: "待办", lastActiveAt: 0, origin: .vault
        )
        XCTAssertEqual(FuzzyMatcher.rank([todo], query: "待办").count, 1)
    }

    func testQuickOpenTemplateStillMatchesItsTag() throws {
        let template = TabEntry(
            id: "j", title: "Metrics 服务大盘", url: "https://x-{r}.com/a",
            spaceTitle: "快速打开", lastActiveAt: 0, origin: .quickOpen
        )
        XCTAssertEqual(FuzzyMatcher.rank([template], query: "快速打开").count, 1)
    }

    /// Excluding the Space name must not cost a real hit: a tab whose title or
    /// URL genuinely contains the term still matches.
    func testGenuineHitInsideThatSpaceStillMatches() {
        let real = TabEntry(
            id: "t2", title: "ledger 对账任务", url: "https://ledger.example.com/x",
            spaceTitle: "Ledger", lastActiveAt: 100
        )
        XCTAssertEqual(FuzzyMatcher.rank([real], query: "ledger").count, 1)
    }
}
