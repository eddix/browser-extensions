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
        let outcome = await s.summarize(title: "T", url: "https://github.com/a", content: "   ")
        XCTAssertEqual(outcome, .failed(reason: "没抓到正文"))
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

    /// Unwraps a successful extraction, failing the test with the reason.
    private func text(_ e: Summarizer.Extraction) throws -> String {
        guard case .text(let t) = e else {
            XCTFail("应解析出文本，实际是 \(e)")
            throw XCTSkip("no text")
        }
        return t
    }

    /// The user-facing half of a failure — what the panel shows.
    private func reason(_ e: Summarizer.Extraction) -> String? {
        guard case .failed(let reason, _) = e else { return nil }
        return reason
    }

    func testParsesOpenAIResponse() throws {
        let json = Data(#"{"choices":[{"message":{"content":"一句话摘要"}}]}"#.utf8)
        XCTAssertEqual(try text(Summarizer.extractText(wire: .openai, data: json)), "一句话摘要")
    }

    /// The critical one: `content` is a block array, and on a thinking-capable
    /// model the reasoning block comes first. Indexing content[0] yields empty
    /// text — blocks have to be filtered by type.
    func testParsesAnthropicResponseWithLeadingThinkingBlock() throws {
        let json = Data("""
        {"stop_reason":"end_turn","content":[
          {"type":"thinking","thinking":""},
          {"type":"text","text":"一句话摘要"}
        ]}
        """.utf8)
        XCTAssertEqual(try text(Summarizer.extractText(wire: .anthropic, data: json)), "一句话摘要")
    }

    func testJoinsMultipleAnthropicTextBlocks() throws {
        let json = Data("""
        {"content":[{"type":"text","text":"前半"},{"type":"text","text":"后半"}]}
        """.utf8)
        XCTAssertEqual(try text(Summarizer.extractText(wire: .anthropic, data: json)), "前半后半")
    }

    /// A policy decline is HTTP 200 with an empty content array — a normal
    /// response that must not be mistaken for a summary or an error.
    func testAnthropicRefusalYieldsNoSummary() {
        let json = Data(#"{"stop_reason":"refusal","content":[]}"#.utf8)
        XCTAssertEqual(reason(Summarizer.extractText(wire: .anthropic, data: json)),
                       "模型以内容策略拒绝了这个页面")
    }

    func testMismatchedShapeYieldsNil() {
        let openAIShaped = Data(#"{"choices":[{"message":{"content":"x"}}]}"#.utf8)
        XCTAssertNotNil(reason(Summarizer.extractText(wire: .anthropic, data: openAIShaped)),
                        "协议选错时应报错，而不是崩溃或写入垃圾摘要")
    }

    // MARK: - Reasoning that ate the whole budget

    /// Reproduced against glm-5.3: reasoning runs first and shares max_tokens
    /// with the reply, so hitting the cap returns a full thinking block and an
    /// empty text one. HTTP 200, valid JSON, no summary.
    ///
    /// This has to be named, not lumped in with "unexpected response shape" —
    /// it is the one failure whose fix (a bigger budget) is knowable from the
    /// response itself.
    func testAnthropicTruncatedByThinkingIsReportedAsTruncation() {
        let json = Data("""
        {"stop_reason":"max_tokens","usage":{"output_tokens":1024},"content":[
          {"type":"thinking","thinking":"很长的推理过程"},
          {"type":"text","text":""}
        ]}
        """.utf8)
        let extraction = Summarizer.extractText(wire: .anthropic, data: json)
        XCTAssertEqual(reason(extraction), "模型思考占满了输出额度，没留下摘要正文")

        guard case .failed(_, let detail) = extraction else { return XCTFail("应为失败") }
        XCTAssertTrue(detail.contains("max_tokens"), detail)
        XCTAssertTrue(detail.contains("thinking="), "日志里要带上思考长度，便于判断额度够不够")
    }

    /// Same failure on the OpenAI wire, where truncation is `finish_reason`.
    func testOpenAITruncatedResponseIsReportedAsTruncation() {
        let json = Data(#"{"choices":[{"finish_reason":"length","message":{"content":""}}]}"#.utf8)
        XCTAssertEqual(reason(Summarizer.extractText(wire: .openai, data: json)),
                       "模型思考占满了输出额度，没留下摘要正文")
    }

    /// An empty reply that wasn't truncated is a different problem and must
    /// not borrow the truncation message.
    func testEmptyButCompleteReplyIsNotCalledTruncation() {
        let json = Data(#"{"stop_reason":"end_turn","content":[{"type":"thinking","thinking":"x"}]}"#.utf8)
        XCTAssertEqual(reason(Summarizer.extractText(wire: .anthropic, data: json)),
                       "模型返回了空内容")
    }

    /// The budget has to cover the tail, not the average. Summarizing the same
    /// 6000-character page four times produced 764, 1335, 1835 and 4313 output
    /// tokens — so anything at or below ~4096 truncates some runs.
    func testTokenBudgetCoversTheMeasuredTail() {
        XCTAssertGreaterThan(Summarizer.maxTokens, 4313,
                            "实测最大一次就用了 4313 token，额度必须高于观测尾部")
        XCTAssertLessThan(Summarizer.fallbackMaxTokens, Summarizer.maxTokens)
    }

    /// max_tokens is an output cap, not the context window, and every endpoint
    /// sets its own ceiling — Ark refuses anything above 128000. Being wrong
    /// about a ceiling should cost one retry, not every summary.
    func testOnlyARejectedBudgetIsWorthRetrying() {
        let arkBody = """
        {"error":{"message":"The parameter `max_tokens` specified in the request is not \
        valid: integer above maximum value, expected a value <= 128000"}}
        """
        XCTAssertTrue(Summarizer.rejectedTheTokenBudget(code: 400, body: arkBody))

        // A second identical request won't fix any of these.
        XCTAssertFalse(Summarizer.rejectedTheTokenBudget(
            code: 400, body: #"{"error":{"message":"model not found"}}"#))
        XCTAssertFalse(Summarizer.rejectedTheTokenBudget(code: 401, body: "unauthorized"))
        XCTAssertFalse(Summarizer.rejectedTheTokenBudget(code: 429, body: "rate limited"))
        XCTAssertFalse(Summarizer.rejectedTheTokenBudget(code: 500, body: "max_tokens"),
                       "只有 400 才是参数被拒，5xx 是服务端问题")
    }

    // MARK: - How much of the page is sent

    func testShortPagesAreSentWhole() {
        let text = String(repeating: "文", count: 100)
        XCTAssertEqual(Summarizer.condense(text, limit: 1000), text)
    }

    /// The failure this exists for: a doc whose last section says the thing is
    /// decommissioned. A head-only cap drops it and the summary reads as if the
    /// content were current.
    func testTheEndOfALongPageSurvives() {
        let body = String(repeating: "正", count: 5000)
        let conclusion = "最终结论：已于 2026 年 7 月下线，迁移至 Falcon 通道。"
        let condensed = Summarizer.condense(body + conclusion, limit: 1000)

        XCTAssertTrue(condensed.contains("Falcon"), "结论在末尾，必须保留")
        XCTAssertTrue(condensed.hasPrefix("正正正"), "开头也要保留")
        XCTAssertTrue(condensed.contains("中间略去"), "要说明中间被省略了")
    }

    /// Weighted toward the head — that's where a page says what it is — but
    /// never so far that the tail vanishes.
    func testCondensedTextStaysWithinBudget() {
        let text = String(repeating: "字", count: 50_000)
        let condensed = Summarizer.condense(text, limit: 1000)
        // The elision marker is the only thing added beyond the limit.
        XCTAssertLessThan(condensed.count, 1000 + 40)
        XCTAssertGreaterThan(condensed.count, 900)
    }

    /// 6000 characters was roughly 3000 tokens against a window that accepted
    /// 720,012 — the cap was never the constraint people assumed it was.
    func testContentBudgetIsNotStuckAtTheOldCap() {
        XCTAssertGreaterThanOrEqual(Summarizer.maxContentChars, 32000)
    }

    func testRequestCarriesTheBudgetItWasGiven() throws {
        let endpoint = Summarizer.Endpoint(
            url: "https://x.test/v1/messages", model: "m",
            keyAccount: "unused", wire: .anthropic
        )
        let request = Summarizer.buildRequest(
            endpoint: endpoint, key: "k",
            url: URL(string: "https://x.test/v1/messages")!,
            title: "T", content: "正文", maxTokens: 8192
        )
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["max_tokens"] as? Int, 8192)

        // The slow tail measured 39.9s; a 60s timeout left too little margin.
        XCTAssertGreaterThanOrEqual(request.timeoutInterval, 120)
    }

    /// Settings saved before the protocol picker existed decode without the
    /// field; they must keep working as OpenAI rather than failing to load.
    func testEndpointWithoutWireFieldDecodesAsOpenAI() throws {
        let legacy = Data(#"{"url":"https://x/y","model":"m","keyAccount":"llm.public"}"#.utf8)
        let decoded = try JSONDecoder().decode(Summarizer.Endpoint.self, from: legacy)
        XCTAssertEqual(decoded.wire, .openai)
        XCTAssertEqual(decoded.model, "m")
    }

    // MARK: - Structured result parsing

    func testParsesSummaryAndKeywords() throws {
        let raw = #"{"summary":"讲了 Atlas 的开发流程。","keywords":["Atlas","接口定义"]}"#
        let r = try XCTUnwrap(Summarizer.parseResult(raw))
        XCTAssertEqual(r.summary, "讲了 Atlas 的开发流程。")
        XCTAssertEqual(r.keywords, ["Atlas", "接口定义"])
    }

    /// Models wrap JSON in code fences often enough that strict parsing would
    /// throw away perfectly good answers.
    func testParsesJSONInsideCodeFence() throws {
        let raw = "```json\n{\"summary\":\"摘要内容\",\"keywords\":[\"A\"]}\n```"
        let r = try XCTUnwrap(Summarizer.parseResult(raw))
        XCTAssertEqual(r.summary, "摘要内容")
        XCTAssertEqual(r.keywords, ["A"])
    }

    /// A reply that isn't JSON is still a summary — degrade, don't discard.
    func testNonJSONReplyBecomesTheSummary() throws {
        let r = try XCTUnwrap(Summarizer.parseResult("这就是一段普通的摘要文字。"))
        XCTAssertEqual(r.summary, "这就是一段普通的摘要文字。")
        XCTAssertTrue(r.keywords.isEmpty)
    }

    /// The vault format is one field per line, so newlines can't survive.
    func testSummaryIsFlattenedToOneLine() throws {
        let raw = #"{"summary":"第一行\n第二行","keywords":[]}"#
        let r = try XCTUnwrap(Summarizer.parseResult(raw))
        XCTAssertFalse(r.summary.contains("\n"))
        XCTAssertEqual(r.summary, "第一行 第二行")
    }

    func testEmptyReplyYieldsNil() {
        XCTAssertNil(Summarizer.parseResult("   "))
    }
}
