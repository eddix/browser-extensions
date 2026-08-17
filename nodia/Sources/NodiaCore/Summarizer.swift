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

    /// Returns nil when the text must not leave the machine, or on any failure —
    /// callers save the link regardless.
    public func summarize(title: String, url: String, content: String) async -> String? {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let endpoint: Endpoint
        switch route(for: url) {
        case .intranet: endpoint = config.intranet
        case .publicNet: endpoint = config.publicNet
        case .skip(let reason):
            Log.write("summary skipped (\(reason)): \(url)")
            return nil
        }

        guard let requestURL = Self.resolvedURL(endpoint.url, wire: endpoint.wire) else {
            return nil
        }
        let key = SecretStore.get(endpoint.keyAccount) ?? ""

        let request = Self.buildRequest(
            endpoint: endpoint,
            key: key,
            url: requestURL,
            title: title,
            content: String(content.prefix(6000))
        )

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                // The body carries the actual reason (bad model name, missing
                // header, rejected parameter) — without it every failure looks
                // the same.
                let detail = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
                Log.write("summary failed: HTTP \(code) for \(url) — \(detail)")
                return nil
            }
            guard let text = Self.extractText(wire: endpoint.wire, data: data) else {
                Log.write("summary failed: unexpected response shape for \(url)")
                return nil
            }
            // Keep it to a single Markdown line — the vault format is one
            // `- summary: …` field per entry.
            let oneLine = TextClean.strip(text)
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
            return oneLine.isEmpty ? nil : oneLine
        } catch {
            Log.write("summary failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Wire format

    static let instruction =
        "用一句中文概括这个网页的内容，不超过 60 字，直接给结论，不要以「这篇文章」开头。"

    /// Generous relative to a 60-character answer: on a thinking-capable model
    /// `max_tokens` caps reasoning *and* reply together, so a tight budget can
    /// be spent entirely on thinking and return nothing.
    static let maxTokens = 1024

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
        content: String
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
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
                "max_tokens": Self.maxTokens,
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
                "max_tokens": Self.maxTokens,
                "system": Self.instruction,
                "messages": [["role": "user", "content": userText]],
            ]
        }

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func extractText(wire: WireProtocol, data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        switch wire {
        case .openai:
            guard
                let choices = json["choices"] as? [[String: Any]],
                let message = choices.first?["message"] as? [String: Any],
                let text = message["content"] as? String
            else { return nil }
            return text

        case .anthropic:
            // A safety decline is HTTP 200 with an empty content array — it is
            // a normal response, not an error, and must not be read as one.
            if json["stop_reason"] as? String == "refusal" {
                Log.write("summary refused by model policy")
                return nil
            }
            // `content` is an array of blocks. On a thinking-capable model the
            // first block is the reasoning, so blocks must be filtered by type
            // rather than indexed — content[0].text is often empty.
            guard let blocks = json["content"] as? [[String: Any]] else { return nil }
            let text = blocks
                .filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }
                .joined()
            return text.isEmpty ? nil : text
        }
    }
}
