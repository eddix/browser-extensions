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
public struct Summarizer: Sendable {

    public struct Endpoint: Codable, Sendable, Equatable {
        /// OpenAI-compatible chat completions URL, e.g. `.../v1/chat/completions`.
        public var url: String
        public var model: String
        /// Keychain account holding the API key; never the key itself.
        public var keyAccount: String

        public var isConfigured: Bool { !url.isEmpty && !model.isEmpty }

        public init(url: String = "", model: String = "", keyAccount: String) {
            self.url = url
            self.model = model
            self.keyAccount = keyAccount
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

        guard let requestURL = URL(string: endpoint.url) else { return nil }
        let key = SecretStore.get(endpoint.keyAccount) ?? ""

        let prompt = """
        用一句中文概括这个网页的内容，不超过 60 字，直接给结论，不要以「这篇文章」开头。

        标题：\(title)

        正文：
        \(content.prefix(6000))
        """

        let body: [String: Any] = [
            "model": endpoint.model,
            "messages": [["role": "user", "content": prompt]],
            "max_tokens": 200,
            "temperature": 0.3,
        ]

        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                Log.write("summary failed: HTTP \(code) for \(url)")
                return nil
            }
            guard
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let choices = json["choices"] as? [[String: Any]],
                let message = choices.first?["message"] as? [String: Any],
                let text = message["content"] as? String
            else {
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
}
