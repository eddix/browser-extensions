import XCTest
@testable import NodiaCore

final class JumpTemplateTests: XCTestCase {

    private let metrics = JumpTemplate(
        name: "Metrics 服务大盘",
        urlTemplate: "https://console-{region}.example.com/metrics/overview/server_overview?service={service}&from={window}",
        choices: ["region": ["i18n", "us", "eu"], "window": ["now-1h", "now-24h"]],
        keywords: ["metrics", "监控"]
    )

    // MARK: - Parameters

    /// Asked in the order they appear, so filling them reads like the URL.
    func testParametersAreOrderedAndDeduplicated() {
        XCTAssertEqual(metrics.parameters, ["region", "service", "window"])

        let twice = JumpTemplate(
            name: "T",
            urlTemplate: "https://x-{env}.com/a/{env}?q={id}"
        )
        XCTAssertEqual(twice.parameters, ["env", "id"], "同名占位符只问一次")
    }

    func testFreeInputParameterHasNoOptions() {
        XCTAssertEqual(metrics.options(for: "region"), ["i18n", "us", "eu"])
        XCTAssertTrue(metrics.options(for: "service").isEmpty, "service 无候选，应为自由输入")
    }

    // MARK: - Expansion

    func testExpandsAllThreeLayers() throws {
        let url = try XCTUnwrap(metrics.expand([
            "region": "us", "service": "team.trade.checkout", "window": "now-1h",
        ]))
        XCTAssertEqual(
            url.absoluteString,
            "https://console-us.example.com/metrics/overview/server_overview?service=team.trade.checkout&from=now-1h"
        )
    }

    /// A value substituted into the *hostname* must not be percent-encoded the
    /// way a query value would be, or the host breaks.
    func testHostValuesSurviveEncoding() throws {
        let url = try XCTUnwrap(metrics.expand([
            "region": "us", "service": "team.shop.api", "window": "now-6h",
        ]))
        XCTAssertEqual(url.host, "console-us.example.com")
        XCTAssertFalse(url.absoluteString.contains("%2E"), "点号不该被编码")
        XCTAssertFalse(url.absoluteString.contains("%2D"), "连字符不该被编码")
    }

    /// But something that would actually break the URL still gets encoded.
    func testDangerousCharactersAreEncoded() throws {
        let t = JumpTemplate(name: "T", urlTemplate: "https://x.com/s?q={q}")
        let url = try XCTUnwrap(t.expand(["q": "a b&c"]))
        XCTAssertFalse(url.absoluteString.contains(" "))
        XCTAssertTrue(url.absoluteString.contains("%20") || url.absoluteString.contains("%26"))
    }

    /// Half-filled means no jump — better than opening a URL with a literal
    /// `{service}` in it.
    func testMissingValueYieldsNoURL() {
        XCTAssertNil(metrics.expand(["region": "i18n"]))
    }

    // MARK: - Parsing

    func testParsesTemplatesFromMarkdown() throws {
        let templates = JumpStore.parse("""
        ---
        type: nodia-jumps
        ---

        - Metrics 服务大盘
          - url: https://console-{region}.example.com/metrics/overview/server_overview?service={service}
          - region: i18n, us, eu
          - keywords: metrics, 监控
          - note: 看某个 service 的服务大盘

        - Pipeline 任务节点
          - url: https://pipeline-{region}.example.net/pipeline/development/node/{node}?project={project}
          - region: sg, norway
        """)

        XCTAssertEqual(templates.count, 2)
        let a = templates[0]
        XCTAssertEqual(a.name, "Metrics 服务大盘")
        XCTAssertEqual(a.choices["region"], ["i18n", "us", "eu"])
        XCTAssertEqual(a.keywords, ["metrics", "监控"])
        XCTAssertEqual(a.note, "看某个 service 的服务大盘")
        XCTAssertEqual(a.parameters, ["region", "service"])

        XCTAssertEqual(templates[1].parameters, ["region", "node", "project"])
    }

    /// An entry with no url line is a comment or a mistake, not a template.
    func testEntryWithoutURLIsSkipped() {
        let templates = JumpStore.parse("""
        - 只是一个标题
          - keywords: a, b

        - 真模板
          - url: https://x.com/{a}
        """)
        XCTAssertEqual(templates.count, 1)
        XCTAssertEqual(templates.first?.name, "真模板")
    }

    /// The starter file is the format's documentation — it has to parse.
    func testStarterFileParses() {
        let templates = JumpStore.parse(JumpStore.starterFile())
        XCTAssertEqual(templates.count, 3)
        let metrics = templates.first { $0.name.contains("Metrics") }
        XCTAssertEqual(metrics?.parameters, ["region", "service", "window"])
        XCTAssertEqual(metrics?.options(for: "region"), ["i18n", "us", "eu"])

        // Every starter template must actually expand to a valid URL.
        for t in templates {
            let values = Dictionary(uniqueKeysWithValues: t.parameters.map {
                ($0, t.options(for: $0).first ?? "x")
            })
            XCTAssertNotNil(t.expand(values), "\(t.name) 应能展开成合法 URL")
        }
    }

    /// Ledger differs only by suffix across regions — the placeholder has to be
    /// able to carry a whole domain fragment, not just a path segment.
    func testPlaceholderCanCarryDomainSuffix() throws {
        let t = JumpStore.parse("""
        - Ledger
          - url: https://ledger{suffix}/
          - suffix: .example.net, -i18n.example.com
        """).first
        let url = try XCTUnwrap(t?.expand(["suffix": ".example.net"]))
        XCTAssertEqual(url.host, "ledger.example.net")
    }
}
