import Foundation

/// Turns extracted page text into a one-line summary, so a saved link is
/// findable later by what it *said* rather than only by its title.
///
/// **Routing is the whole point.** Most of what gets saved here is internal
/// documentation. Sending that to a public model would leak it, so a link is
/// classified by host first and only ever sent to the matching endpoint:
///
/// - intranet host → intranet endpoint
/// - public host   → public endpoint
///
/// If the matching endpoint isn't configured, the text is **not sent anywhere**
/// and the entry is simply saved without a summary. Failing closed is the only
/// safe default: a missing summary costs nothing, a leak can't be undone.
/// Wire format of an LLM endpoint. Gateways commonly speak one or both; the
/// two differ in more than the URL, so it has to be an explicit choice.
public enum WireProtocol: String, Codable, Sendable, CaseIterable {
    /// `POST /v1/chat/completions` — `Authorization: Bearer`, text at
    /// `choices[0].message.content`.
    case openai
    /// `POST /v1/messages` — `x-api-key` + `anthropic-version`, `max_tokens`
    /// required, text spread across a `content` block array.
    case anthropic

    public var label: String {
        switch self {
        case .openai: return "OpenAI 兼容"
        case .anthropic: return "Anthropic 兼容"
        }
    }
}

public struct Summarizer: Sendable {

    public struct Endpoint: Codable, Sendable, Equatable {
        /// Full request URL — `.../v1/chat/completions` for OpenAI,
        /// `.../v1/messages` for Anthropic.
        public var url: String
        public var model: String
        /// Keychain account holding the API key; never the key itself.
        public var keyAccount: String
        public var wire: WireProtocol

        public var isConfigured: Bool { !url.isEmpty && !model.isEmpty }

        public init(
            url: String = "",
            model: String = "",
            keyAccount: String,
            wire: WireProtocol = .openai
        ) {
            self.url = url
            self.model = model
            self.keyAccount = keyAccount
            self.wire = wire
        }

        // `wire` was added after the first release; settings saved before that
        // decode without it, so it needs a default rather than a hard failure.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
            model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
            keyAccount = try c.decode(String.self, forKey: .keyAccount)
            wire = try c.decodeIfPresent(WireProtocol.self, forKey: .wire) ?? .openai
        }
    }

    public struct Config: Codable, Sendable, Equatable {
        public var enabled: Bool
        public var intranet: Endpoint
        public var publicNet: Endpoint
        /// Host suffixes treated as internal. Anything matching goes to the
        /// intranet endpoint or nowhere at all.
        public var intranetSuffixes: [String]

        public static let defaultIntranetSuffixes = [
            "example.com", "example.com", "example.com", "example.net",
            "example.net", "example.net", "example.com", "example.cn",
            "wiki.example.cn", "wiki.example.com",
        ]

        public init(
            enabled: Bool = false,
            intranet: Endpoint = Endpoint(keyAccount: "llm.intranet"),
            publicNet: Endpoint = Endpoint(keyAccount: "llm.public"),
            intranetSuffixes: [String] = Config.defaultIntranetSuffixes
        ) {
            self.enabled = enabled
            self.intranet = intranet
            self.publicNet = publicNet
            self.intranetSuffixes = intranetSuffixes
        }
    }

    public enum Route: Equatable, Sendable {
        case intranet
        case publicNet
        /// Matched a network whose endpoint isn't set up — send nothing.
        case skip(reason: String)
    }

    private let config: Config

    public init(config: Config) {
        self.config = config
    }

    /// Which endpoint, if any, may see this page's text.
    public func route(for urlString: String) -> Route {
        guard config.enabled else { return .skip(reason: "摘要未启用") }
        guard let host = URL(string: urlString)?.host?.lowercased() else {
            return .skip(reason: "无法解析域名")
        }

        let isIntranet = config.intranetSuffixes.contains { suffix in
            host == suffix || host.hasSuffix("." + suffix)
        }

        if isIntranet {
            return config.intranet.isConfigured
                ? .intranet
                : .skip(reason: "内网页面，但未配置内网模型")
        }
        return config.publicNet.isConfigured
            ? .publicNet
            : .skip(reason: "未配置公网模型")
    }

    /// Either a summary, or why there isn't one — phrased for the panel.
    ///
    /// "It failed, check the log" makes the user do the diagnosis. The reasons
    /// that actually occur (wrong model name, unset key, reasoning that ate the
    /// token budget) each imply a different fix, so they're worth telling apart
    /// at the point where you can still act on it.
    public enum Outcome: Sendable, Equatable {
        case summarized(Result)
        case failed(reason: String)
    }

    /// A summary plus the words you might search for months from now.
    public struct Result: Sendable, Equatable {
        public var summary: String
        public var keywords: [String]

        public init(summary: String, keywords: [String] = []) {
            self.summary = summary
            self.keywords = keywords
        }
    }

    /// Never throws and never blocks the save: a link with no summary is still
    /// a saved link, so every failure comes back as a reason to show.
    public func summarize(title: String, url: String, content: String) async -> Outcome {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failed(reason: "没抓到正文")
        }

        let endpoint: Endpoint
        switch route(for: url) {
        case .intranet: endpoint = config.intranet
        case .publicNet: endpoint = config.publicNet
        case .skip(let reason):
            Log.write("summary skipped (\(reason)): \(url)")
            return .failed(reason: reason)
        }

        guard let requestURL = Self.resolvedURL(endpoint.url, wire: endpoint.wire) else {
            return .failed(reason: "接口地址无法解析：\(endpoint.url)")
        }
        let key = SecretStore.get(endpoint.keyAccount) ?? ""

        // Second pass only happens if the endpoint rejects the budget itself.
        for budget in [Self.maxTokens, Self.fallbackMaxTokens] {
            let request = Self.buildRequest(
                endpoint: endpoint,
                key: key,
                url: requestURL,
                title: title,
                content: String(content.prefix(6000)),
                maxTokens: budget
            )

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                    // The body carries the actual reason (bad model name, missing
                    // header, rejected parameter) — without it every failure looks
                    // the same.
                    let detail = String(data: data, encoding: .utf8)?.prefix(300) ?? ""
                    Log.write("summary failed: HTTP \(code) at max_tokens=\(budget) for \(url) — \(detail)")
                    // A rejected budget is the one failure a second attempt can
                    // fix. Everything else — bad key, unknown model — would fail
                    // identically, so don't spend another round trip on it.
                    if Self.rejectedTheTokenBudget(code: code, body: String(detail)),
                       budget != Self.fallbackMaxTokens {
                        continue
                    }
                    return .failed(reason: "模型返回 HTTP \(code)")
                }
                switch Self.extractText(wire: endpoint.wire, data: data) {
                case .text(let text):
                    guard let result = Self.parseResult(text) else {
                        Log.write("summary failed: empty reply for \(url)")
                        return .failed(reason: "模型返回了空内容")
                    }
                    return .summarized(result)
                case .failed(let reason, let detail):
                    Log.write("summary failed: \(detail) for \(url)")
                    return .failed(reason: reason)
                }
            } catch {
                Log.write("summary failed: \(error.localizedDescription)")
                return .failed(reason: error.localizedDescription)
            }
        }
        return .failed(reason: "模型不接受这个输出长度上限")
    }

    /// Whether a 400 is the endpoint objecting to `max_tokens` specifically.
    ///
    /// Matched on the body because the wire has no dedicated code for it —
    /// Ark answers `integer above maximum value, expected a value <= 128000`.
    /// Deliberately narrow: a false positive only costs one retry, but treating
    /// every 400 as retryable would double the cost of every real mistake.
    static func rejectedTheTokenBudget(code: Int, body: String) -> Bool {
        code == 400 && body.contains("max_tokens")
    }

    // MARK: - Wire format

    /// What a summary is *for* here: finding the page again months later, from
    /// a half-memory. That is worth more words than a one-liner — the model
    /// call already costs seconds, so the output should earn them.
    static let instruction = """
    为这个网页写一条便于日后检索的记录，只输出 JSON，不要加代码块标记：

    {"summary": "...", "keywords": ["...", "..."]}

    summary：100~150 字中文。说清楚这个页面讲什么、解决什么问题、包含哪些关键内容或结论。\
    直接陈述，不要以「这篇文章」「本文」开头，不要评价。
    keywords：3~8 个检索词，覆盖主题、涉及的系统或工具名、关键概念、适用场景。\
    专有名词保留原文（中英文均可）。日后我可能凭其中任何一个想起这个页面。
    """

    /// Vastly more than the answer needs, and that is the point.
    ///
    /// `max_tokens` is a **cap, not a reservation** — an unused budget costs
    /// nothing. It is also not the context window: the window covers input
    /// plus output, while this bounds output alone and every endpoint caps it
    /// far lower (Ark rejects anything above 128000 for `glm-5.3`).
    ///
    /// It has to be generous because on a thinking-capable model it covers
    /// reasoning *and* reply, reasoning goes first, and reasoning length is
    /// wildly unstable. The same 6000-character page, summarized four times:
    /// 764, 1335, 1835, 4313 output tokens — a 5.6× spread, 8.7s to 39.9s.
    /// Any budget fitted to the average silently truncates the tail, which is
    /// what 1024 was doing: a full thinking block and an empty text one.
    static let maxTokens = 32768

    /// Tried once if the endpoint rejects the budget above as too large.
    /// Smaller gateways cap output far below Ark's 128000, and being wrong
    /// about a cap shouldn't cost every summary.
    static let fallbackMaxTokens = 8192

    /// Completes a configured address into the endpoint actually being called.
    ///
    /// Gateways publish a **base** URL (`ANTHROPIC_BASE_URL` style), so that is
    /// what people paste — while the request has to go to `/v1/messages` or
    /// `/v1/chat/completions`. Posting to the bare base returns an auth error
    /// rather than a routing one, which sends you looking at the key. Accept
    /// either form instead.
    static func resolvedURL(_ raw: String, wire: WireProtocol) -> URL? {
        var base = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty else { return nil }

        // A trailing version segment is the gateway's own — don't add a second
        // one. Volcengine's OpenAI base ends in `/api/v3`, so matching only
        // `/v1` would produce `/api/v3/v1/chat/completions`.
        let lastSegment = base.split(separator: "/").last.map(String.init) ?? ""
        let endsWithVersion =
            lastSegment.range(of: "^v[0-9]+$", options: .regularExpression) != nil

        let path: String
        switch wire {
        case .anthropic:
            if base.hasSuffix("/messages") { path = "" }
            else if endsWithVersion { path = "/messages" }
            else { path = "/v1/messages" }
        case .openai:
            if base.hasSuffix("/chat/completions") { path = "" }
            else if endsWithVersion { path = "/chat/completions" }
            else { path = "/v1/chat/completions" }
        }
        return URL(string: base + path)
    }

    static func buildRequest(
        endpoint: Endpoint,
        key: String,
        url: URL,
        title: String,
        content: String,
        maxTokens: Int = Summarizer.maxTokens
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // Reasoning time swings as much as reasoning length: the same page
        // measured 8.7s to 39.9s. At 60s the slow tail would time out, which
        // looks identical to a broken endpoint.
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let userText = "标题：\(title)\n\n正文：\n\(content)"
        let body: [String: Any]

        switch endpoint.wire {
        case .openai:
            if !key.isEmpty {
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
            body = [
                "model": endpoint.model,
                "messages": [
                    ["role": "system", "content": Self.instruction],
                    ["role": "user", "content": userText],
                ],
                "max_tokens": maxTokens,
                "temperature": 0.3,
            ]

        case .anthropic:
            // Anthropic authenticates with x-api-key, not a bearer token, and
            // rejects requests without a version header.
            if !key.isEmpty {
                request.setValue(key, forHTTPHeaderField: "x-api-key")
            }
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            // `system` is a top-level field here, not a message role, and
            // `max_tokens` is required rather than optional. `temperature` is
            // deliberately absent: current Claude models reject it with a 400.
            body = [
                "model": endpoint.model,
                "max_tokens": maxTokens,
                "system": Self.instruction,
                "messages": [["role": "user", "content": userText]],
            ]
        }

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Turns the model's reply into a summary and keywords.
    ///
    /// Models wrap JSON in code fences or add a sentence around it often enough
    /// that strict parsing would throw away good answers — so the JSON object
    /// is located within the reply, and anything unparseable degrades to being
    /// the summary itself rather than to nothing.
    static func parseResult(_ raw: String) -> Result? {
        let cleaned = TextClean.strip(raw)
        guard !cleaned.isEmpty else { return nil }

        if let start = cleaned.firstIndex(of: "{"),
           let end = cleaned.lastIndex(of: "}"),
           start < end,
           let data = String(cleaned[start...end]).data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let summary = (json["summary"] as? String).map(TextClean.strip) ?? ""
            let keywords = (json["keywords"] as? [Any])?
                .compactMap { $0 as? String }
                .map(TextClean.strip)
                .filter { !$0.isEmpty } ?? []
            if !summary.isEmpty {
                return Result(summary: oneLine(summary), keywords: keywords)
            }
        }

        // Not JSON — treat the whole reply as the summary rather than losing it.
        return Result(summary: oneLine(cleaned), keywords: [])
    }

    /// The vault format is one `- summary: …` field per entry, so the text has
    /// to survive as a single line.
    private static func oneLine(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// The reply text, or why it couldn't be read: a user-facing reason and a
    /// longer line for the log.
    enum Extraction: Equatable {
        case text(String)
        case failed(reason: String, detail: String)
    }

    static func extractText(wire: WireProtocol, data: Data) -> Extraction {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failed(reason: "模型返回的不是 JSON", detail: "response was not JSON")
        }

        // Truncation is worth naming on both wires: it's the one failure the
        // user can act on, and the action isn't obvious from "it failed".
        let truncated = "模型思考占满了输出额度，没留下摘要正文"

        switch wire {
        case .openai:
            guard
                let choices = json["choices"] as? [[String: Any]],
                let first = choices.first,
                let message = first["message"] as? [String: Any]
            else {
                return .failed(reason: "无法解析模型返回", detail: "no choices[0].message")
            }
            guard let text = message["content"] as? String, !text.isEmpty else {
                if first["finish_reason"] as? String == "length" {
                    return .failed(reason: truncated, detail: "finish_reason=length, empty content")
                }
                return .failed(reason: "模型返回了空内容", detail: "choices[0].message.content empty")
            }
            return .text(text)

        case .anthropic:
            // A safety decline is HTTP 200 with an empty content array — it is
            // a normal response, not an error, and must not be read as one.
            if json["stop_reason"] as? String == "refusal" {
                return .failed(reason: "模型以内容策略拒绝了这个页面",
                               detail: "stop_reason=refusal")
            }
            // `content` is an array of blocks. On a thinking-capable model the
            // first block is the reasoning, so blocks must be filtered by type
            // rather than indexed — content[0].text is often empty.
            guard let blocks = json["content"] as? [[String: Any]] else {
                return .failed(reason: "无法解析模型返回", detail: "no content array")
            }
            let text = blocks
                .filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }
                .joined()
            guard !text.isEmpty else {
                // Reasoning runs before the answer and shares the same budget,
                // so hitting the cap yields a thinking block and an empty text
                // one. Saying "unexpected response shape" here sent the user
                // to the log for something the panel could have just told them.
                if json["stop_reason"] as? String == "max_tokens" {
                    let thought = blocks
                        .filter { $0["type"] as? String == "thinking" }
                        .compactMap { ($0["thinking"] as? String)?.count }
                        .reduce(0, +)
                    return .failed(
                        reason: truncated,
                        detail: "stop_reason=max_tokens, thinking=\(thought) chars, text=0"
                    )
                }
                let types = blocks.compactMap { $0["type"] as? String }.joined(separator: ",")
                return .failed(reason: "模型返回了空内容", detail: "no text block (blocks: \(types))")
            }
            return .text(text)
        }
    }
}
