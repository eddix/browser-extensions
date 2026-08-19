import Foundation

/// One value a parameter can take: what you see, and what goes into the URL.
///
/// These are not the same thing often enough that conflating them is a bug
/// waiting to happen. A region picker reads `VA`, but that region's path
/// segment is `us`; another is `eu-central-1`. A format that can only substitute
/// the label verbatim can't express the platforms it's meant to open.
public struct Choice: Sendable, Hashable {
    public let label: String
    public let value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }

    /// Parses `显示名=值`. Without `=`, the value doubles as its own label.
    ///
    /// Splits on the **first** `=` only: values are URL fragments and routinely
    /// contain more (`?tab=1`).
    public static func parse(_ raw: String) -> Choice {
        let text = TextClean.strip(raw)
        guard let split = text.firstIndex(of: "=") else {
            return Choice(label: text, value: text)
        }
        let label = TextClean.strip(String(text[text.startIndex..<split]))
        let value = TextClean.strip(String(text[text.index(after: split)...]))
        // A trailing `=` means "the label is the value" rather than an empty value.
        return Choice(label: label, value: value.isEmpty ? label : value)
    }
}

/// What a parameter accepts. The distinction is the whole point of the
/// redesign: a list you pick from and a box you type into are different
/// gestures, and a UI that renders them identically leaves you guessing.
public enum ParameterKind: Sendable, Equatable {
    case choices([Choice])
    case input
}

/// A "platform + parameters" entry: one template standing in for every URL you
/// can reach by swapping a value.
///
/// Internal platforms encode the same three things over and over — the site in
/// the hostname, the feature in the path, the target in the query:
///
///     https://{site}/metrics/overview/server_overview?service={service}
///             └─┬──┘ └──────────┬──────────┘        └──┬──┘
///              site          feature                 target
///
/// Parameterize the **whole** host rather than a prefix of it: regions don't
/// reliably share a domain (`console-i18n.example.com` but
/// `console-eu.example.net`), so `console-{region}.example.com` builds
/// hostnames that don't resolve.
public struct QuickOpenTemplate: Sendable, Equatable {
    public let name: String
    /// URL with `{placeholder}` markers.
    public let urlTemplate: String
    public let params: [String: ParameterKind]
    public let keywords: [String]
    public let note: String?

    public init(
        name: String,
        urlTemplate: String,
        params: [String: ParameterKind] = [:],
        keywords: [String] = [],
        note: String? = nil
    ) {
        self.name = name
        self.urlTemplate = urlTemplate
        self.params = params
        self.keywords = keywords
        self.note = note
    }

    /// Placeholders in the order they appear, deduplicated.
    ///
    /// This is deliberately derived from the URL rather than from the config's
    /// key order: JSON objects have no order once parsed, and the URL is the
    /// one place the sequence is unambiguous. It also reads the way you'd fill
    /// a form — left to right through the address.
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

    /// A placeholder nobody described is free input — the least surprising
    /// default, and it keeps a minimal template down to a name and a URL.
    public func kind(of parameter: String) -> ParameterKind {
        params[parameter] ?? .input
    }

    public func choices(for parameter: String) -> [Choice] {
        if case .choices(let list) = kind(of: parameter) { return list }
        return []
    }

    /// Substitutes values and returns the URL to open. A missing value leaves
    /// its placeholder in place, which yields nil rather than a broken URL.
    ///
    /// An *empty* value counts as missing. The form hands over every parameter
    /// from the moment it opens, blanks included, and substituting those would
    /// quietly produce `…/detail/` — a URL that looks finished, parses fine,
    /// and goes nowhere.
    ///
    /// "Still has a hole in it" is decided by the same pattern that decided what
    /// to ask you about, not by searching for a bare `{`. Plenty of real URLs
    /// carry literal braces — a query parameter holding a JSON filter is the
    /// common one — and treating those as unfilled made such a template
    /// permanently unopenable: every field answered, and the footer still
    /// reading "还缺一个值". Anything shaped like `{name}` is a placeholder here
    /// by definition, because `parameters` reads it the same way and puts a
    /// field on screen for it; anything else is text the URL wanted.
    public func expand(_ values: [String: String]) -> URL? {
        var filled = urlTemplate
        for (key, value) in values where !value.isEmpty {
            filled = filled.replacingOccurrences(of: "{\(key)}", with: Self.encode(value))
        }
        let unfilled = Self.placeholderPattern.firstMatch(
            in: filled, range: NSRange(filled.startIndex..., in: filled)
        )
        guard unfilled == nil, let url = URL(string: filled), url.host != nil else {
            return nil
        }
        return url
    }

    /// Percent-encodes only what would actually break a URL.
    ///
    /// Values land in hostnames as often as in query strings (`{site}`), and
    /// blanket query-encoding would corrupt a host. Everything a service name,
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

/// Reads quick-open templates from `Bookmark/00-QuickOpen.json`.
///
/// JSON rather than Markdown because this file is *configuration you write*,
/// not *content the app wrote for you to read* — the rest of the vault is the
/// latter. Hand-rolling a config syntax on top of Markdown bullets had already
/// cost one arbitrary limitation (no commas in a value) before any of it was
/// built. JSON also round-trips cleanly, which matters for the planned "make a
/// template from this tab": rewriting YAML without destroying its comments and
/// anchors is a project of its own.
///
/// The cost, stated plainly: JSON has no comments. Per-template `note` covers
/// explaining an entry; file-level commentary has nowhere to go.
public struct QuickOpenStore: Sendable {

    public static let fileName = "Bookmark/00-QuickOpen.json"

    public struct LoadResult: Sendable {
        public var templates: [QuickOpenTemplate]
        /// Problems worth showing rather than swallowing: a template that
        /// references a shared list that doesn't exist would otherwise just
        /// silently offer no candidates.
        public var problems: [String]

        public init(templates: [QuickOpenTemplate] = [], problems: [String] = []) {
            self.templates = templates
            self.problems = problems
        }
    }

    public static func load(vaultRoot: URL) -> LoadResult {
        guard let data = try? Data(contentsOf: vaultRoot.appendingPathComponent(fileName)) else {
            return LoadResult()
        }
        return parse(data)
    }

    // MARK: - JSON

    /// Collects every problem rather than failing on the first one: a typo in
    /// template 3 shouldn't hide templates 4 through 40.
    public static func parse(_ data: Data) -> LoadResult {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return LoadResult(problems: ["配置不是合法的 JSON 对象"])
        }

        var problems: [String] = []
        var shared: [String: [Choice]] = [:]
        for (name, raw) in (root["shared"] as? [String: Any]) ?? [:] {
            guard let list = raw as? [String] else {
                problems.append("shared.\(name) 应该是字符串数组")
                continue
            }
            shared[name] = list.map(Choice.parse)
        }

        guard let entries = root["templates"] as? [[String: Any]] else {
            problems.append("缺少 templates 数组")
            return LoadResult(problems: problems)
        }

        var templates: [QuickOpenTemplate] = []
        var takenNames = Set<String>()
        for (index, entry) in entries.enumerated() {
            let label = (entry["name"] as? String).map { "「\($0)」" } ?? "第 \(index + 1) 条"
            guard let name = (entry["name"] as? String).map(TextClean.strip), !name.isEmpty else {
                problems.append("\(label) 缺少 name")
                continue
            }
            // The name is the identity, not just a caption: rows are keyed
            // `qo:<name>`, the usage score is stored under it, and lookup takes
            // the first match. So a second template with the same name isn't a
            // second template — it's a row you can see in the list and can
            // never open, because selecting it opens the first one's URL. Kept
            // out of the list entirely rather than merely reported, since the
            // alternative is leaving that row on screen to lie about itself.
            guard takenNames.insert(name).inserted else {
                problems.append("\(label) 与前面某条重名，这一条被忽略")
                continue
            }
            guard let url = (entry["url"] as? String).map(TextClean.strip), !url.isEmpty else {
                problems.append("\(label) 缺少 url")
                continue
            }

            var params: [String: ParameterKind] = [:]
            for (param, raw) in (entry["params"] as? [String: Any]) ?? [:] {
                guard let spec = raw as? [String: Any] else {
                    problems.append("\(label) 的参数 \(param) 应该是对象")
                    continue
                }
                // nil means the parameter asked for free input; an empty array
                // means it asked for a list and named nothing.
                let listed: [Choice]?
                if let use = spec["use"] as? String {
                    guard let list = shared[use] else {
                        problems.append("\(label) 的参数 \(param) 引用了不存在的 shared.\(use)")
                        continue
                    }
                    listed = list
                } else if let list = spec["choices"] as? [String] {
                    listed = list.map(Choice.parse)
                } else if spec["input"] as? Bool == true {
                    listed = nil
                } else {
                    problems.append("\(label) 的参数 \(param) 需要 choices / input / use 之一")
                    continue
                }

                // A list with nothing in it is one you meant to fill in, and it
                // used to pass without a word: the field then rendered as a
                // closed set offering "无匹配的候选值", which is a door that
                // isn't there — you can type into it and it works. Reported so
                // the mistake is visible, and demoted to free input so the form
                // describes what the field actually does. Doing only the first
                // leaves the UI lying; only the second hides the typo.
                switch listed {
                case .some(let list) where !list.isEmpty:
                    params[param] = .choices(list)
                case .some:
                    problems.append("\(label) 的参数 \(param) 没有候选值，按自由输入处理")
                    params[param] = .input
                case .none:
                    params[param] = .input
                }
            }

            let template = QuickOpenTemplate(
                name: name,
                urlTemplate: url,
                params: params,
                keywords: ((entry["keywords"] as? [String]) ?? []).map(TextClean.strip)
                    .filter { !$0.isEmpty },
                note: (entry["note"] as? String).map(TextClean.strip).flatMap {
                    $0.isEmpty ? nil : $0
                }
            )
            // A described parameter that appears nowhere in the URL is dead
            // config — usually a rename that only got applied on one side.
            let placeholders = Set(template.parameters)
            for param in params.keys where !placeholders.contains(param) {
                problems.append("\(label) 描述了参数 \(param)，但 url 里没有 {\(param)}")
            }
            // A template with no parameters is already a finished URL, so it
            // can be checked now rather than discovered at the moment you press
            // ⏎ and nothing happens. One with parameters can't: its URL isn't
            // knowable until the values are.
            if template.parameters.isEmpty, template.expand([:]) == nil {
                problems.append("\(label) 的 url 不是一个能打开的地址")
            }
            templates.append(template)
        }
        return LoadResult(templates: templates, problems: problems)
    }

    /// Written on first run so the format is discoverable by example rather
    /// than from docs. Seeded from shapes actually present in a real sidebar:
    /// the site in the host, an object id or service name as the target.
    public static func starterFile() -> String {
        """
        {
          "shared": {
            "console": [
              "i18n=console-i18n.example.com",
              "us=console-us.example.com",
              "eu=console-eu.example.net"
            ]
          },

          "templates": [
            {
              "name": "Metrics 服务大盘",
              "note": "看某个服务的监控总览",
              "keywords": ["metrics", "监控", "服务大盘"],
              "url": "https://{site}/metrics/overview/server_overview?service={service}&from={window}",
              "params": {
                "site": { "use": "console" },
                "window": { "choices": ["1 小时=now-1h", "6 小时=now-6h", "24 小时=now-24h"] },
                "service": { "input": true }
              }
            },
            {
              "name": "ConfigHub 配置",
              "note": "某个 namespace 的配置列表",
              "keywords": ["confighub", "配置中心", "namespace"],
              "url": "https://{site}/confighub/namespace/{namespace}?env={env}&scope=all&tab=config",
              "params": {
                "site": { "use": "console" },
                "env": { "choices": ["生产=prod", "预发=staging", "测试=test"] },
                "namespace": { "input": true }
              }
            },
            {
              "name": "对账任务详情",
              "note": "区域的显示名和 URL 片段不是一回事，所以候选写成「显示名=值」",
              "keywords": ["ledger", "对账"],
              "url": "https://ledger.example.net/#/{region}/reconciliation-detail/{task_id}?env=sg",
              "params": {
                "region": { "choices": ["SG=sg", "VA=us", "EU=eu-central-1"] },
                "task_id": { "input": true }
              }
            }
          ]
        }

        """
    }
}
