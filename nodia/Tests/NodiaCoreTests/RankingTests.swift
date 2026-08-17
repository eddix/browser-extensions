import XCTest
@testable import NodiaCore

/// Ranking decides whether a feature is discoverable at all. A jump template
/// that exists but never surfaces is, from the keyboard, the same as one that
/// doesn't exist — which is exactly what happened before these rules.
final class RankingTests: XCTestCase {

    private func tab(_ title: String, url: String = "https://x.com/a", active: Double = 100) -> TabEntry {
        TabEntry(id: title, title: title, url: url, spaceTitle: "S", lastActiveAt: active)
    }

    private func template(_ name: String) -> TabEntry {
        TabEntry(id: "jump:\(name)", title: name, url: "https://x-{r}.com/a",
                 spaceTitle: "跳转", lastActiveAt: 0, origin: .jumpTemplate)
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
        XCTAssertEqual(top.origin, .jumpTemplate)
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
}
