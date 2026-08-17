import XCTest
@testable import NodiaCore

/// Routing decides where a page's text is allowed to go. A mistake here leaks
/// internal documents to a public model, so these are the tests that matter
/// most in this package.
final class SummarizerTests: XCTestCase {

    private func config(
        enabled: Bool = true,
        intranetConfigured: Bool = true,
        publicConfigured: Bool = true
    ) -> Summarizer.Config {
        Summarizer.Config(
            enabled: enabled,
            intranet: Summarizer.Endpoint(
                url: intranetConfigured ? "https://intranet.example/v1/chat/completions" : "",
                model: intranetConfigured ? "internal-model" : "",
                keyAccount: "llm.intranet"
            ),
            publicNet: Summarizer.Endpoint(
                url: publicConfigured ? "https://api.example.com/v1/chat/completions" : "",
                model: publicConfigured ? "public-model" : "",
                keyAccount: "llm.public"
            )
        )
    }

    // MARK: - Intranet stays internal

    func testIntranetHostRoutesToIntranetEndpoint() {
        let s = Summarizer(config: config())
        XCTAssertEqual(s.route(for: "https://wiki.example.com/wiki/abc"), .intranet)
        XCTAssertEqual(s.route(for: "https://console.example.com/x"), .intranet)
        XCTAssertEqual(s.route(for: "https://code.example.com/team/repo"), .intranet)
        XCTAssertEqual(s.route(for: "https://ledger.example.net/a"), .intranet)
    }

    func testSubdomainsOfIntranetSuffixCount() {
        let s = Summarizer(config: config())
        XCTAssertEqual(s.route(for: "https://deep.nested.example.com/x"), .intranet)
    }

    /// A host merely *ending in the same letters* is not the same domain.
    func testLookalikeHostIsNotTreatedAsIntranet() {
        let s = Summarizer(config: config())
        XCTAssertEqual(s.route(for: "https://notexample.com/x"), .publicNet)
        XCTAssertEqual(s.route(for: "https://evil-example.com.attacker.com/x"), .publicNet)
    }

    /// The critical one: an internal page with no internal model configured
    /// must NOT fall back to the public endpoint.
    func testIntranetPageIsSkippedRatherThanSentPublicly() {
        let s = Summarizer(config: config(intranetConfigured: false, publicConfigured: true))
        guard case .skip = s.route(for: "https://wiki.example.com/wiki/abc") else {
            return XCTFail("内网页面在未配置内网模型时必须跳过，绝不能回退到公网模型")
        }
    }

    // MARK: - Public side

    func testPublicHostRoutesToPublicEndpoint() {
        let s = Summarizer(config: config())
        XCTAssertEqual(s.route(for: "https://simonwillison.net/2026/x"), .publicNet)
        XCTAssertEqual(s.route(for: "https://github.com/a/b"), .publicNet)
    }

    func testPublicPageSkippedWhenPublicEndpointMissing() {
        let s = Summarizer(config: config(publicConfigured: false))
        guard case .skip = s.route(for: "https://github.com/a/b") else {
            return XCTFail("未配置公网模型时应跳过")
        }
    }

    // MARK: - Master switch

    func testDisabledSkipsEverything() {
        let s = Summarizer(config: config(enabled: false))
        guard case .skip = s.route(for: "https://github.com/a/b") else {
            return XCTFail("关闭摘要后不应发送任何内容")
        }
        guard case .skip = s.route(for: "https://example.com/x") else {
            return XCTFail("关闭摘要后不应发送任何内容")
        }
    }

    func testUnparsableURLIsSkipped() {
        let s = Summarizer(config: config())
        guard case .skip = s.route(for: "not a url") else {
            return XCTFail("无法解析域名时应跳过")
        }
    }

    func testEmptyContentProducesNoSummary() async {
        let s = Summarizer(config: config())
        let result = await s.summarize(title: "T", url: "https://github.com/a", content: "   ")
        XCTAssertNil(result)
    }

    /// Wiki is on the intranet list even though the domain is publicly
    /// resolvable — internal wikis live there.
    func testWikiIsTreatedAsIntranet() {
        let s = Summarizer(config: config())
        XCTAssertEqual(s.route(for: "https://wiki.example.cn/wiki/x"), .intranet)
    }
}
