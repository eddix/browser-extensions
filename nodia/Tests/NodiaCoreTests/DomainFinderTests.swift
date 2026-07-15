import XCTest
@testable import NodiaCore

final class DomainFinderTests: XCTestCase {
    private func tab(_ url: String, _ title: String) -> TabEntry {
        TabEntry(id: "\(url)#\(title)", title: title, url: url, spaceTitle: "", lastActiveAt: 0)
    }

    // MARK: domain(for:)

    func testStripsLeadingWww() {
        XCTAssertEqual(DomainFinder.domain(for: tab("https://www.google.com/x", "t")), "google.com")
    }

    func testKeepsHostWithoutWwwPrefix() {
        // "wwwx.com" must NOT be treated as a www-prefixed host.
        XCTAssertEqual(DomainFinder.domain(for: tab("https://wwwx.com/", "t")), "wwwx.com")
        XCTAssertEqual(DomainFinder.domain(for: tab("https://docs.google.com/", "t")), "docs.google.com")
    }

    func testEmptyHostFallsBackToOther() {
        XCTAssertEqual(DomainFinder.domain(for: tab("about:blank", "t")), "其他")
        XCTAssertEqual(DomainFinder.domain(for: tab("", "t")), "其他")
    }

    // MARK: groups(from:)

    func testEmptyInputYieldsEmpty() {
        XCTAssertTrue(DomainFinder.groups(from: []).isEmpty)
    }

    func testGroupsSameDomainAcrossWwwVariants() {
        let groups = DomainFinder.groups(from: [
            tab("https://www.google.com/a", "Alpha"),
            tab("https://google.com/b", "Beta"),
        ])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].domain, "google.com")
        XCTAssertEqual(groups[0].count, 2)
    }

    func testGroupsSortedByDomain() {
        let groups = DomainFinder.groups(from: [
            tab("https://zebra.com/", "z"),
            tab("https://apple.com/", "a"),
            tab("https://mango.com/", "m"),
        ])
        XCTAssertEqual(groups.map(\.domain), ["apple.com", "mango.com", "zebra.com"])
    }

    func testTabsWithinGroupSortedByTitleCaseInsensitive() {
        let groups = DomainFinder.groups(from: [
            tab("https://x.com/3", "Cherry"),
            tab("https://x.com/1", "apple"),
            tab("https://x.com/2", "Banana"),
        ])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].tabs.map(\.title), ["apple", "Banana", "Cherry"])
    }

    func testChineseTitlesSortByPinyin() {
        // zh collation: 北京(běi) < 上海(shàng) < 西安(xī...) — arc parity check.
        let groups = DomainFinder.groups(from: [
            tab("https://x.com/1", "上海"),
            tab("https://x.com/2", "北京"),
            tab("https://x.com/3", "西安"),
        ])
        XCTAssertEqual(groups[0].tabs.map(\.title), ["北京", "上海", "西安"])
    }
}
