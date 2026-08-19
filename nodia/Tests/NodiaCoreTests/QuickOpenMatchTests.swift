import XCTest
@testable import NodiaCore

final class QuickOpenMatchTests: XCTestCase {

    private func tab(_ url: String, space: String = "Work") -> TabEntry {
        TabEntry(id: url, title: "T", url: url, spaceTitle: space, lastActiveAt: 1)
    }

    private func url(_ s: String) throws -> URL { try XCTUnwrap(URL(string: s)) }

    func testFindsTheTabShowingExactlyThisURL() throws {
        let tabs = [tab("https://example.com/a"), tab("https://ledger.example.net/#/sg/detail/1")]
        let hit = QuickOpenMatch.liveTab(for: try url("https://ledger.example.net/#/sg/detail/1"),
                                         in: tabs)
        XCTAssertEqual(hit?.url, "https://ledger.example.net/#/sg/detail/1")
    }

    func testTrailingSlashDoesNotCountAsADifferentPage() throws {
        let hit = QuickOpenMatch.liveTab(for: try url("https://example.com/console"),
                                         in: [tab("https://example.com/console/")])
        XCTAssertNotNil(hit)
    }

    /// DNS doesn't care about the case of a hostname and neither does the
    /// browser, so a tab opened from a link that shouted the host is the same
    /// page a template builds in lowercase. Treating them as two left a second
    /// window open on a page you already had.
    func testHostCaseDoesNotCountAsADifferentPage() throws {
        let hit = QuickOpenMatch.liveTab(for: try url("https://console.example.com/metrics"),
                                         in: [tab("https://Console.EXAMPLE.com/metrics")])
        XCTAssertNotNil(hit)
        XCTAssertNotNil(
            QuickOpenMatch.liveTab(for: try url("HTTPS://console.example.com/metrics"),
                                   in: [tab("https://console.example.com/metrics")]),
            "scheme 同理，也是大小写无关的"
        )
    }

    /// But only the host. Everything after it is case-*sensitive*, and a
    /// blanket `lowercased()` would have collapsed two different objects onto
    /// one another — the reason this isn't just one call.
    func testEverythingAfterTheHostStaysCaseSensitive() throws {
        XCTAssertNil(
            QuickOpenMatch.liveTab(for: try url("https://example.com/detail/AbC"),
                                   in: [tab("https://example.com/detail/abc")]),
            "路径大小写不同就是不同的对象"
        )
        XCTAssertNil(
            QuickOpenMatch.liveTab(for: try url("https://example.com/m?service=Team.Shop"),
                                   in: [tab("https://example.com/m?service=team.shop")])
        )
        XCTAssertNil(
            QuickOpenMatch.liveTab(for: try url("https://ledger.example.net/#/sg/detail/Ab"),
                                   in: [tab("https://ledger.example.net/#/sg/detail/ab")])
        )
    }

    /// The trap that ruled out reusing `VaultStore.normalize`: it truncates at
    /// `#`, so every task on a fragment-routed platform would look like the
    /// same page. Asking for task 1 would have switched you to task 2.
    func testFragmentIsPartOfTheIdentity() throws {
        let open = tab("https://ledger.example.net/#/sg/detail/222")
        XCTAssertNil(
            QuickOpenMatch.liveTab(for: try url("https://ledger.example.net/#/sg/detail/111"),
                                   in: [open]),
            "fragment 不同就是不同的页面"
        )
        XCTAssertEqual(VaultStore.normalize(open.url), "https://ledger.example.net",
                       "对照：收藏用的归一化确实会把它们抹成同一个")
    }

    /// A dashboard's subject lives in the query string, so it's part of the
    /// identity too — otherwise one service's board would switch you to
    /// another's.
    func testQueryIsPartOfTheIdentity() throws {
        let open = tab("https://console.example.com/metrics?service=team.shop.api")
        XCTAssertNil(
            QuickOpenMatch.liveTab(
                for: try url("https://console.example.com/metrics?service=team.trade.checkout"),
                in: [open]
            )
        )
    }

    /// Two views of the same board over different windows are two pages. They
    /// look alike; they aren't, and guessing otherwise means silently showing
    /// you the wrong hour.
    func testDifferentTimeWindowsAreDifferentPages() throws {
        let open = tab("https://console.example.com/metrics?service=a&from=now-1h")
        XCTAssertNil(
            QuickOpenMatch.liveTab(
                for: try url("https://console.example.com/metrics?service=a&from=now-24h"),
                in: [open]
            )
        )
    }

    /// Top Apps hang off the sidebar root, so Arc's `spaces → tabs` can't reach
    /// them: "switching" means walking every Space for several seconds and then
    /// opening the URL anyway. Skip straight to opening it.
    func testTopAppsAreNotOfferedAsASwitchTarget() throws {
        let favourite = tab("https://example.com/app", space: SidebarParser.topAppsSpaceTitle)
        XCTAssertNil(QuickOpenMatch.liveTab(for: try url("https://example.com/app"),
                                            in: [favourite]))
    }

    /// A saved link is a line in a Markdown file, not a window to raise.
    func testSavedLinksAreNotSwitchTargets() throws {
        let saved = TabEntry(id: "v", title: "T", url: "https://example.com/a",
                             spaceTitle: "档案", lastActiveAt: 0, origin: .vault)
        XCTAssertNil(QuickOpenMatch.liveTab(for: try url("https://example.com/a"), in: [saved]))
    }

    /// Host case folds, everything after it does not — and userinfo is after
    /// it. A password is not a hostname, and lowercasing one would change it.
    func testUserinfoKeepsItsCaseWhileTheHostFolds() {
        XCTAssertEqual(
            QuickOpenMatch.normalize("https://User:PaSS@Example.COM/Detail/AbC"),
            "https://User:PaSS@example.com/Detail/AbC"
        )
    }

    func testNoMatchWhenNothingIsOpen() throws {
        XCTAssertNil(QuickOpenMatch.liveTab(for: try url("https://example.com/x"),
                                            in: [tab("https://example.com/y")]))
    }
}
