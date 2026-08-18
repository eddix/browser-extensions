import XCTest
@testable import NodiaCore

final class QuickOpenFormTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private var state: QuickOpenState!

    override func setUpWithError() throws {
        suite = "nodia-form-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        state = QuickOpenState(defaults: defaults)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
    }

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

    private func form(_ t: QuickOpenTemplate? = nil) -> QuickOpenForm {
        QuickOpenForm(template: t ?? ledger, state: state)
    }

    // MARK: - Opening the form

    /// Focus starts where you'd have to type. Everything before it already has
    /// an answer; stopping on those is a keystroke that buys nothing.
    func testFocusStartsOnTheFirstBlankField() {
        let f = form()
        XCTAssertEqual(f.parameter, "task_id")
        XCTAssertEqual(f.values["region"], "sg", "有候选的字段自动落到第一个候选")
        XCTAssertEqual(f.values["task_id"], "")
    }

    /// Nothing blank means nothing to ask: focus the first field and let ⏎ go.
    func testEverythingRememberedFocusesTheFirstField() {
        state.recordOpen(template: ledger, values: ["region": "us", "task_id": "42"])
        let f = form()
        XCTAssertEqual(f.parameter, "region")
        XCTAssertNil(f.firstBlank)
        XCTAssertEqual(f.url?.absoluteString,
                       "https://ledger.example.net/#/us/detail/42")
    }

    /// The field shows the label, the URL gets the value. Conflating them is
    /// the bug the whole Choice type exists to prevent.
    func testFieldShowsLabelWhileURLGetsValue() {
        state.recordOpen(template: ledger, values: ["region": "eu-central-1", "task_id": "7"])
        let f = form()
        XCTAssertEqual(f.text(of: "region"), "EU")
        XCTAssertEqual(f.values["region"], "eu-central-1")
        XCTAssertTrue(f.url!.absoluteString.contains("/eu-central-1/"))
    }

    // MARK: - Typing

    func testTypingAFreeValueGoesStraightIntoTheURL() {
        var f = form()
        f.type("743188920")
        XCTAssertEqual(f.values["task_id"], "743188920")
        XCTAssertEqual(f.url?.absoluteString,
                       "https://ledger.example.net/#/sg/detail/743188920")
    }

    /// Typing a candidate's label resolves to its value, so you can type "VA"
    /// instead of arrowing to it.
    func testTypingALabelResolvesToItsValue() {
        var f = form()
        f.focusField(0)
        f.type("VA")
        XCTAssertEqual(f.values["region"], "us")
    }

    /// And typing something no candidate matches is still allowed — a region
    /// list can be incomplete, and refusing the value helps nobody.
    func testTypingSomethingUnlistedIsTakenLiterally() {
        var f = form()
        f.focusField(0)
        f.type("ap-south-2")
        XCTAssertEqual(f.values["region"], "ap-south-2")
    }

    func testTypingNarrowsTheCandidateList() {
        var f = form()
        f.focusField(0)
        f.type("e")
        XCTAssertEqual(f.candidates.map(\.label), ["EU"])
    }

    /// Matching looks at the value too: you might remember `us` rather than the
    /// "VA" it's labelled.
    func testCandidatesMatchOnValueAsWellAsLabel() {
        var f = form()
        f.focusField(0)
        f.type("us")
        XCTAssertEqual(f.candidates.map(\.label), ["VA"])
    }

    // MARK: - Arrowing

    /// The regression this design exists for. Moving the highlight rewrites the
    /// field, and if the list narrowed on the *field* rather than on what was
    /// typed, it would collapse to one row under its own cursor and the next ↓
    /// would have nowhere to go.
    func testArrowingDoesNotCollapseTheListUnderItself() {
        var f = form()
        f.focusField(0)
        XCTAssertEqual(f.candidates.count, 3)

        f.moveHighlight(1)
        XCTAssertEqual(f.candidates.count, 3, "光标移动不该重新筛选列表")
        XCTAssertEqual(f.values["region"], "sg", "还没有高亮时，第一下 ↓ 落在第一条")

        f.moveHighlight(1)
        XCTAssertEqual(f.candidates.count, 3)
        XCTAssertEqual(f.values["region"], "us")

        f.moveHighlight(1)
        XCTAssertEqual(f.candidates.count, 3)
        XCTAssertEqual(f.highlighted, 2)
        XCTAssertEqual(f.values["region"], "eu-central-1")
        XCTAssertEqual(f.text(of: "region"), "EU", "字段文本要跟着光标走")
    }

    func testArrowingStopsAtTheEnds() {
        var f = form()
        f.focusField(0)
        f.moveHighlight(-1)
        XCTAssertEqual(f.highlighted, 0)
        for _ in 0..<10 { f.moveHighlight(1) }
        XCTAssertEqual(f.highlighted, 2)
    }

    /// A filter typed first still applies while arrowing — the two compose.
    func testArrowingWalksTheFilteredListOnly() {
        let t = QuickOpenTemplate(
            name: "T", urlTemplate: "https://x.com/{env}",
            params: ["env": .choices([
                Choice(label: "prod", value: "prod"),
                Choice(label: "preprod", value: "ppe"),
                Choice(label: "test", value: "test"),
            ])]
        )
        var f = form(t)
        f.type("pr")
        XCTAssertEqual(f.candidates.map(\.label), ["prod", "preprod"])
        f.moveHighlight(1)
        XCTAssertEqual(f.values["env"], "prod")
        f.moveHighlight(1)
        XCTAssertEqual(f.values["env"], "ppe")
        f.moveHighlight(1)
        XCTAssertEqual(f.highlighted, 1, "筛完只剩两条，走不到第三条")
    }

    // MARK: - Tab

    func testTabWrapsAroundTheFields() {
        var f = form()
        f.focusField(0)
        f.focusNext()
        XCTAssertEqual(f.parameter, "task_id")
        f.focusNext()
        XCTAssertEqual(f.parameter, "region", "最后一个字段回到第一个")
    }

    /// Arrowing onto a candidate and tabbing away has to keep it — otherwise
    /// the highlight is decoration.
    func testTabKeepsTheHighlightedCandidate() {
        var f = form()
        f.focusField(0)
        f.moveHighlight(1)   // first row, SG
        f.moveHighlight(1)   // second row, VA — has to differ from the prefill to prove anything
        f.focusNext()
        XCTAssertEqual(f.values["region"], "us")
    }

    /// The other half of that rule, and the bug it was hiding: ⇥ only keeps a
    /// candidate you actually put the cursor on. `highlighted` used to be an
    /// `Int` that typing reset to 0 without meaning "row 0", so tabbing out of
    /// a field where you'd typed `123` swapped in a remembered value that
    /// merely *contained* it — history matches on `contains`, not on prefix.
    func testTabbingAwayKeepsWhatYouTypedRatherThanACandidate() {
        state.recordOpen(template: ledger, values: ["region": "sg", "task_id": "12345"])
        var f = form()
        f.focusField(1)
        f.type("123")
        XCTAssertEqual(f.candidates.map(\.value), ["12345"],
                       "前提：那条历史确实还在候选里，只是不该被自动选中")
        f.focusNext()
        XCTAssertEqual(f.values["task_id"], "123")
        XCTAssertEqual(f.text(of: "task_id"), "123")
    }

    /// Nothing is highlighted until you move the cursor, so the highlight can
    /// never sit on a row that contradicts the field beside it — which is what
    /// you saw whenever the value you last used wasn't the first candidate.
    func testNothingIsHighlightedUntilYouMoveTheCursor() {
        state.recordOpen(template: ledger, values: ["region": "eu-central-1", "task_id": "7"])
        var f = form()
        XCTAssertNil(f.highlighted)
        XCTAssertEqual(f.text(of: "region"), "EU", "上次用的不是第一个候选")

        f.focusField(0)
        XCTAssertNil(f.highlighted, "换字段也不该凭空高亮一行")
        f.moveHighlight(1)
        XCTAssertEqual(f.highlighted, 0)
    }

    /// Typing drops the highlight rather than resetting it to the top row: the
    /// list refilters as you type, so whatever the cursor was on isn't what
    /// that position names any more.
    func testTypingClearsTheHighlight() {
        var f = form()
        f.focusField(0)
        f.moveHighlight(1)
        XCTAssertNotNil(f.highlighted)
        f.type("e")
        XCTAssertNil(f.highlighted)
    }

    /// A new field shows its own whole list, not what you typed into the last
    /// one.
    func testMovingFieldsClearsTheFilter() {
        var f = form()
        f.focusField(0)
        f.type("e")
        XCTAssertEqual(f.candidates.count, 1)
        f.focusNext()
        f.focusField(0)
        XCTAssertEqual(f.candidates.count, 3)
    }

    // MARK: - Free-input history as the candidate list

    func testRecentInputsBecomeTheCandidateListForFreeInput() {
        state.recordOpen(template: ledger, values: ["region": "sg", "task_id": "111"])
        state.recordOpen(template: ledger, values: ["region": "sg", "task_id": "222"])
        var f = form()
        f.focusField(1)
        XCTAssertEqual(f.candidates.map(\.value), ["222", "111"])
        XCTAssertFalse(f.hasCandidateList, "自由输入没有配置候选，列表是历史")
    }

    func testPickingFromHistoryFillsTheField() {
        state.recordOpen(template: ledger, values: ["task_id": "743188920"])
        var f = form()
        f.focusField(1)
        f.moveHighlight(0)
        XCTAssertEqual(f.values["task_id"], "743188920")
        XCTAssertEqual(f.text(of: "task_id"), "743188920")
    }

    // MARK: - URL

    /// The footer previews this, so it has to be the same value that opening
    /// uses — not a second assembly that can drift.
    func testURLIsNilUntilEveryFieldHasSomething() {
        var f = form()
        XCTAssertNil(f.url, "task_id 还空着")
        f.type("9")
        XCTAssertNotNil(f.url)
    }

    /// Placeholders can sit inside a hostname, and a value landing there must
    /// not be percent-encoded the way a query value would be.
    func testValueInsideAHostnameSurvives() {
        let t = QuickOpenTemplate(
            name: "T", urlTemplate: "https://{site}/x",
            params: ["site": .choices([Choice(label: "i18n", value: "console-i18n.example.com")])]
        )
        XCTAssertEqual(form(t).url?.host, "console-i18n.example.com")
    }
}
