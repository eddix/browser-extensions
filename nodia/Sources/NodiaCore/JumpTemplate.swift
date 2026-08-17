import Foundation

/// A "platform + parameters" jump: one entry that stands in for every URL you
/// can reach by swapping a value.
///
/// Internal platforms encode the same three things over and over — the site in
/// the hostname, the feature in the path, the target in the query:
///
///     https://{site}/metrics/overview/server_overview?service={service}
///             └─┬──┘ └──────────┬──────────┘        └──┬──┘
///              site          feature                 target
///
/// Without this, each combination has to be saved separately — which is why
/// the same monitoring console ends up bookmarked once per region.
///
/// Parameterize the **whole** host rather than a prefix of it: regions don't
/// reliably share a domain (`console-i18n.example.com` but
/// `console-eu.example.net`), so `console-{region}.example.com` builds
/// hostnames that don't resolve.
public struct JumpTemplate: Sendable, Equatable {
    public let name: String
    /// URL with `{placeholder}` markers, e.g. `https://{site}/x?service={service}`
    public let urlTemplate: String
    /// Known values per placeholder. A placeholder with no list is free input.
    public let choices: [String: [String]]
    public let keywords: [String]
    public let note: String?

    public init(
        name: String,
        urlTemplate: String,
        choices: [String: [String]] = [:],
        keywords: [String] = [],
        note: String? = nil
    ) {
        self.name = name
        self.urlTemplate = urlTemplate
        self.choices = choices
        self.keywords = keywords
        self.note = note
    }

    /// Placeholders in the order they appear, deduplicated — that's the order
    /// you'll be asked to fill them in.
    public var parameters: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for match in Self.placeholderPattern.matches(
            in: urlTemplate,
            range: NSRange(urlTemplate.startIndex..., in: urlTemplate)
        ) {
            guard let r = Range(match.range(at: 1), in: urlTemplate) else { continue }
            let name = String(urlTemplate[r])
            if seen.insert(name).inserted { ordered.append(name) }
        }
        return ordered
    }

    public func options(for parameter: String) -> [String] {
        choices[parameter] ?? []
    }

    /// Substitutes values and returns the URL to open. Missing values leave
    /// their placeholder in place, which yields nil rather than a broken URL.
    public func expand(_ values: [String: String]) -> URL? {
        var filled = urlTemplate
        for (key, value) in values {
            filled = filled.replacingOccurrences(of: "{\(key)}", with: Self.encode(value))
        }
        guard !filled.contains("{"), let url = URL(string: filled), url.host != nil else {
            return nil
        }
        return url
    }

    /// Percent-encodes only what would actually break a URL.
    ///
    /// Values land in hostnames as often as in query strings (`{site}`),
    /// and blanket query-encoding would corrupt a host. Everything a service,
    /// region, or time window is made of passes through untouched.
    static func encode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: ".-_~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static let placeholderPattern = try! NSRegularExpression(
        pattern: "\\{([A-Za-z0-9_]+)\\}"
    )
}

/// Reads jump templates from `Bookmark/00-Jumps.md`.
///
/// They live in the vault as Markdown for the same reason everything else
/// does: the file outlives this app, and is editable without it.
public struct JumpStore: Sendable {

    public static let fileName = "Bookmark/00-Jumps.md"

    public static func load(vaultRoot: URL) -> [JumpTemplate] {
        let file = vaultRoot.appendingPathComponent(fileName)
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return parse(text)
    }

    /// Same bullet shape as saved links: a top-level `- Name`, then indented
    /// `- key: value` fields. `url:` carries the template; any other key is
    /// read as the candidate list for the placeholder of that name.
    public static func parse(_ text: String) -> [JumpTemplate] {
        var templates: [JumpTemplate] = []
        var name: String?
        var url: String?
        var choices: [String: [String]] = [:]
        var keywords: [String] = []
        var note: String?

        func flush() {
            defer { name = nil; url = nil; choices = [:]; keywords = []; note = nil }
            guard let name, let url, !url.isEmpty else { return }
            templates.append(JumpTemplate(
                name: name, urlTemplate: url,
                choices: choices, keywords: keywords, note: note
            ))
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = TextClean.removeInvisible(String(rawLine))
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indented = line.hasPrefix(" ") || line.hasPrefix("\t")

            if !indented, trimmed.hasPrefix("- ") {
                flush()
                name = TextClean.strip(String(trimmed.dropFirst(2)))
                continue
            }
            guard indented, trimmed.hasPrefix("- "),
                  let colon = trimmed.firstIndex(of: ":") else { continue }

            let key = TextClean.strip(String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<colon]))
            let value = TextClean.strip(String(trimmed[trimmed.index(after: colon)...]))
            guard !key.isEmpty else { continue }

            switch key {
            case "url":
                url = value
            case "note":
                note = value.isEmpty ? nil : value
            case "keywords":
                keywords = value.split(separator: ",").map { TextClean.strip(String($0)) }
                    .filter { !$0.isEmpty }
            default:
                let list = value.split(separator: ",").map { TextClean.strip(String($0)) }
                    .filter { !$0.isEmpty }
                if !list.isEmpty { choices[key] = list }
            }
        }
        flush()
        return templates
    }

    /// Written on first run so the format is discoverable by example rather
    /// than by reading docs. Seeded from patterns actually present in the
    /// vault: site in the host, namespace or service as the target.
    public static func starterFile() -> String {
        """
        ---
        type: nodia-jumps
        ---

        <!-- nodia 跳转模板。⌘T 浏览全部，或 ⌘⇧K 直接搜名字，{参数} 会逐个让你填。
             同名的字段提供候选值（逗号分隔），没有候选的参数为自由输入。
             站点整体写成 {site} 而不是 console-{region}.example.com——不同区域
             可能位于完全不同的域名（EU 在 example.net 上）。 -->

        - Metrics 服务大盘
          - url: https://{site}/metrics/overview/server_overview?service={service}&from={window}
          - site: console-i18n.example.com, console-us.example.com, console-eu.example.net
          - window: now-1h, now-6h, now-24h, now-7d
          - keywords: metrics, 服务大盘, 监控, service
          - note: 看某个 service 的服务监控总览

        - ConfigHub 配置
          - url: https://{site}/confighub/namespace/{namespace}?env={env}&dir_path=all_dir&region=all_region&scope=all&tab=config
          - site: console-i18n.example.com, console-us.example.com, console-eu.example.net, console-staging.example.com
          - env: prod, ppe, staging
          - keywords: confighub, 配置, 配置中心, namespace, 动态配置
          - note: 某个 namespace 的配置列表

        - ConfigHub 变更历史
          - url: https://{site}/confighub/namespace/{namespace}?scope=history&env={env}&release_status=running&region=all_region&rn=10
          - site: console-i18n.example.com, console-us.example.com, console-eu.example.net, console-staging.example.com
          - env: prod, ppe, staging
          - keywords: confighub, 变更, 历史, 发布记录, 回滚
          - note: 谁改的、改了什么、能否回滚

        - Pipeline 任务节点
          - url: https://pipeline-{region}.example.net/pipeline/development/node/{node}?project={project}&version=-1
          - region: sg, norway, oceanus
          - keywords: pipeline, pipeline, 任务, 节点

        - Ledger 对账平台
          - url: https://ledger{suffix}/
          - suffix: .example.net, -i18n.example.com
          - keywords: ledger, 对账

        """
    }
}
