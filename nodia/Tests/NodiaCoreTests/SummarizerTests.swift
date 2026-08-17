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

    // MARK: - Wire formats

    private func body(_ request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func request(_ wire: WireProtocol) -> URLRequest {
        Summarizer.buildRequest(
            endpoint: Summarizer.Endpoint(
                url: "https://gw.example/x", model: "some-model",
                keyAccount: "acct", wire: wire
            ),
            key: "secret-key",
            url: URL(string: "https://gw.example/x")!,
            title: "标题", content: "正文"
        )
    }

    func testOpenAIRequestShape() throws {
        let r = request(.openai)
        XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), "Bearer secret-key")
        XCTAssertNil(r.value(forHTTPHeaderField: "x-api-key"))

        let b = try body(r)
        let messages = try XCTUnwrap(b["messages"] as? [[String: String]])
        XCTAssertEqual(messages.first?["role"], "system", "OpenAI 的 system 是一条消息")
        XCTAssertNil(b["system"], "OpenAI 没有顶层 system 字段")
        XCTAssertNotNil(b["temperature"])
    }

    /// Anthropic authenticates with `x-api-key` and rejects requests with no
    /// version header — a bearer token alone gets a 401.
    func testAnthropicUsesApiKeyAndVersionHeaders() throws {
        let r = request(.anthropic)
        XCTAssertEqual(r.value(forHTTPHeaderField: "x-api-key"), "secret-key")
        XCTAssertEqual(r.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertNil(r.value(forHTTPHeaderField: "Authorization"))
    }

    func testAnthropicBodyShape() throws {
        let b = try body(request(.anthropic))
        XCTAssertEqual(b["system"] as? String, Summarizer.instruction,
                       "Anthropic 的 system 是顶层字段，不是消息")
        XCTAssertNotNil(b["max_tokens"], "Anthropic 的 max_tokens 是必填")

        let messages = try XCTUnwrap(b["messages"] as? [[String: String]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?["role"], "user")

        // Current Claude models reject temperature with a 400.
        XCTAssertNil(b["temperature"], "Anthropic 请求不得带 temperature")
    }

    // MARK: - URL completion

    /// Gateways publish a base URL, so that's what gets pasted; posting to the
    /// bare base returns an auth error that sends you debugging the key.
    func testCompletesBaseURLForAnthropic() {
        let u = Summarizer.resolvedURL("https://ark.example.com/api/coding", wire: .anthropic)
        XCTAssertEqual(u?.absoluteString, "https://ark.example.com/api/coding/v1/messages")
    }

    func testCompletesBaseURLForOpenAI() {
        let u = Summarizer.resolvedURL("https://ark.example.com/api/v3", wire: .openai)
        XCTAssertEqual(u?.absoluteString, "https://ark.example.com/api/v3/chat/completions")
    }

    func testLeavesCompleteURLAlone() {
        let a = Summarizer.resolvedURL("https://x.com/v1/messages", wire: .anthropic)
        XCTAssertEqual(a?.absoluteString, "https://x.com/v1/messages")
        let o = Summarizer.resolvedURL("https://x.com/v1/chat/completions", wire: .openai)
        XCTAssertEqual(o?.absoluteString, "https://x.com/v1/chat/completions")
    }

    /// A base ending in /v1 needs only the verb appended, not a second /v1.
    func testDoesNotDoubleVersionSegment() {
        let a = Summarizer.resolvedURL("https://x.com/v1", wire: .anthropic)
        XCTAssertEqual(a?.absoluteString, "https://x.com/v1/messages")
        let o = Summarizer.resolvedURL("https://x.com/v1/", wire: .openai)
        XCTAssertEqual(o?.absoluteString, "https://x.com/v1/chat/completions")
    }

    func testTrailingSlashAndBlankHandling() {
        XCTAssertEqual(
            Summarizer.resolvedURL("https://x.com/api/  ", wire: .anthropic)?.absoluteString,
            "https://x.com/api/v1/messages"
        )
        XCTAssertNil(Summarizer.resolvedURL("   ", wire: .anthropic))
    }

    // MARK: - Response parsing

    func testParsesOpenAIResponse() {
        let json = Data(#"{"choices":[{"message":{"content":"一句话摘要"}}]}"#.utf8)
        XCTAssertEqual(Summarizer.extractText(wire: .openai, data: json), "一句话摘要")
    }

    /// The critical one: `content` is a block array, and on a thinking-capable
    /// model the reasoning block comes first. Indexing content[0] yields empty
    /// text — blocks have to be filtered by type.
    func testParsesAnthropicResponseWithLeadingThinkingBlock() {
        let json = Data("""
        {"stop_reason":"end_turn","content":[
          {"type":"thinking","thinking":""},
          {"type":"text","text":"一句话摘要"}
        ]}
        """.utf8)
        XCTAssertEqual(Summarizer.extractText(wire: .anthropic, data: json), "一句话摘要")
    }

    func testJoinsMultipleAnthropicTextBlocks() {
        let json = Data("""
        {"content":[{"type":"text","text":"前半"},{"type":"text","text":"后半"}]}
        """.utf8)
        XCTAssertEqual(Summarizer.extractText(wire: .anthropic, data: json), "前半后半")
    }

    /// A policy decline is HTTP 200 with an empty content array — a normal
    /// response that must not be mistaken for a summary or an error.
    func testAnthropicRefusalYieldsNoSummary() {
        let json = Data(#"{"stop_reason":"refusal","content":[]}"#.utf8)
        XCTAssertNil(Summarizer.extractText(wire: .anthropic, data: json))
    }

    func testMismatchedShapeYieldsNil() {
        let openAIShaped = Data(#"{"choices":[{"message":{"content":"x"}}]}"#.utf8)
        XCTAssertNil(Summarizer.extractText(wire: .anthropic, data: openAIShaped),
                     "协议选错时应返回 nil，而不是崩溃或写入垃圾摘要")
    }

    /// Settings saved before the protocol picker existed decode without the
    /// field; they must keep working as OpenAI rather than failing to load.
    func testEndpointWithoutWireFieldDecodesAsOpenAI() throws {
        let legacy = Data(#"{"url":"https://x/y","model":"m","keyAccount":"llm.public"}"#.utf8)
        let decoded = try JSONDecoder().decode(Summarizer.Endpoint.self, from: legacy)
        XCTAssertEqual(decoded.wire, .openai)
        XCTAssertEqual(decoded.model, "m")
    }
}
