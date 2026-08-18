import XCTest
@testable import NodiaCore

final class QuickOpenStateTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUpWithError() throws {
        suite = "nodia-state-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private func state() -> QuickOpenState { QuickOpenState(defaults: defaults) }

    private let ledger = QuickOpenTemplate(
        name: "对账任务详情",
        urlTemplate: "https://ledger.example.net/#/{region}/detail/{task_id}",
        params: [
            "region": .choices([
                Choice(label: "SG", value: "sg"),
                Choice(label: "VA", value: "us"),
                Choice(label: "EU", value: "eu-central-1"),
            ]),
            "task_id": .input,
        ]
    )

    private let pipeline = QuickOpenTemplate(
        name: "任务节点",
        urlTemplate: "https://pipeline-{region}.example.net/node/{node}",
        params: ["region": .choices([Choice(label: "新加坡", value: "sg"),
                                     Choice(label: "挪威", value: "norway")])]
    )

    // MARK: - Ranking

    /// The point of decaying per opening rather than per day: a template used
    /// often stays on top, and one used once drifts down as you use others.
    func testFrequentTemplateOutscoresAOneOff() {
        let s = state()
        for _ in 0..<5 { s.recordOpen(template: ledger, values: [:]) }
        s.recordOpen(template: pipeline, values: [:])
        XCTAssertGreaterThan(s.score(named: ledger.name), s.score(named: pipeline.name))
    }

    /// …but not forever. Keep using the other one and it takes over, which is
    /// what separates this from a plain counter.
    func testSustainedUseOvertakesAnOldFavourite() {
        let s = state()
        for _ in 0..<5 { s.recordOpen(template: ledger, values: [:]) }
        for _ in 0..<10 { s.recordOpen(template: pipeline, values: [:]) }
        XCTAssertGreaterThan(s.score(named: pipeline.name), s.score(named: ledger.name))
    }

    /// Nothing happens to the ordering while you aren't opening anything —
    /// the reason decay counts openings instead of days. Two weeks off, then
    /// back to the list exactly as you left it.
    func testScoresDoNotMoveWithoutOpenings() {
        let s = state()
        for _ in 0..<3 { s.recordOpen(template: ledger, values: [:]) }
        let before = s.scores()
        XCTAssertEqual(state().scores(), before, "只读不该改动分数")
    }

    /// A halving takes ~34 openings. Verified against the closed form rather
    /// than a hand-picked number, so changing `decay` can't silently drift.
    func testHalfLifeIsAboutThirtyFourOpenings() {
        let s = state()
        s.recordOpen(template: ledger, values: [:])
        let start = s.score(named: ledger.name)
        let halfLife = Int((log(0.5) / log(QuickOpenState.decay)).rounded())
        for _ in 0..<halfLife { s.recordOpen(template: pipeline, values: [:]) }
        XCTAssertEqual(s.score(named: ledger.name), start / 2, accuracy: 0.01)
        XCTAssertEqual(halfLife, 34)
    }

    /// A deleted or renamed template must not sit in the dictionary forever.
    func testScoreIsDroppedOnceItFadesToNothing() {
        let s = state()
        s.recordOpen(template: ledger, values: [:])
        for _ in 0..<250 { s.recordOpen(template: pipeline, values: [:]) }
        XCTAssertNil(s.scores()[ledger.name], "衰减到地板以下应被剪掉")
        XCTAssertNotNil(s.scores()[pipeline.name])
    }

    // MARK: - Prefill

    /// The case that makes cross-template memory worth having: same parameter
    /// name, same meaning, different template.
    func testRememberedValueCarriesAcrossTemplates() {
        let s = state()
        s.recordOpen(template: ledger, values: ["region": "sg", "task_id": "743188920"])
        XCTAssertEqual(s.prefill(for: pipeline, parameter: "region"), "sg")
    }

    /// And the case that makes it dangerous: same name, different candidates.
    /// `us` is a real region on one platform and nonexistent on the other, so
    /// it's discarded rather than expanded into a URL that can't resolve.
    func testRememberedValueOutsideThisTemplatesChoicesFallsBack() {
        let s = state()
        s.recordOpen(template: ledger, values: ["region": "us"])
        XCTAssertEqual(s.prefill(for: pipeline, parameter: "region"), "sg",
                       "候选里没有的值应退回第一个候选")
    }

    func testFirstCandidateIsUsedBeforeAnythingIsRemembered() {
        XCTAssertEqual(state().prefill(for: ledger, parameter: "region"), "sg")
    }

    /// Free input has no candidate list to fall back to, so an unremembered
    /// one starts empty — and that emptiness is what ⏎ jumps to.
    func testUnusedFreeInputStartsEmpty() {
        XCTAssertEqual(state().prefill(for: ledger, parameter: "task_id"), "")
    }

    func testPrefillCoversEveryParameter() {
        let s = state()
        s.recordOpen(template: ledger, values: ["region": "eu-central-1", "task_id": "42"])
        XCTAssertEqual(s.prefill(for: ledger), ["region": "eu-central-1", "task_id": "42"])
    }

    // MARK: - Free-input history

    func testRecentInputsAreMostRecentFirstAndDeduplicated() {
        let s = state()
        for id in ["1", "2", "1", "3"] {
            s.recordOpen(template: ledger, values: ["region": "sg", "task_id": id])
        }
        XCTAssertEqual(s.recentInputs(for: "task_id"), ["3", "1", "2"])
    }

    func testRecentInputsAreCapped() {
        let s = state()
        for id in ["1", "2", "3", "4", "5", "6", "7"] {
            s.recordOpen(template: ledger, values: ["task_id": id])
        }
        XCTAssertEqual(s.recentInputs(for: "task_id"), ["7", "6", "5", "4", "3"])
    }

    /// A parameter with candidates already has its list in the config; a second
    /// shorter copy of the same strings would just be another thing to keep in
    /// sync.
    func testParametersWithCandidatesKeepNoHistory() {
        let s = state()
        s.recordOpen(template: ledger, values: ["region": "sg", "task_id": "1"])
        XCTAssertTrue(s.recentInputs(for: "region").isEmpty)
        XCTAssertEqual(s.lastValue(for: "region"), "sg", "但上次的值仍然要记")
    }

    func testEmptyValuesAreNotRecorded() {
        let s = state()
        s.recordOpen(template: ledger, values: ["region": "sg", "task_id": ""])
        XCTAssertNil(s.lastValue(for: "task_id"))
        XCTAssertTrue(s.recentInputs(for: "task_id").isEmpty)
    }

    /// Everything must survive the trip through UserDefaults, not just live in
    /// one instance — the whole point is that tomorrow's panel remembers.
    func testStateRoundTripsThroughDefaults() {
        state().recordOpen(template: ledger, values: ["region": "us", "task_id": "77"])
        let fresh = state()
        XCTAssertEqual(fresh.lastValue(for: "task_id"), "77")
        XCTAssertEqual(fresh.recentInputs(for: "task_id"), ["77"])
        XCTAssertEqual(fresh.score(named: ledger.name), 1, accuracy: 0.0001)
    }
}
