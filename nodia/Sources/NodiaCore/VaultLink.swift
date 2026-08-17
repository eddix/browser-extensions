import Foundation

/// What a saved link is *for*. The three roles a browser tab bar gets abused
/// as — each with a different lifetime and a different way of coming back to
/// you. See ../../README.md.
public enum LinkKind: String, Codable, CaseIterable, Sendable {
    /// A platform or console you jump to — Ledger, a Grafana board, a ConfigHub
    /// namespace. A staging area, not an asset: the endgame is turning these
    /// into launcher scripts, after which the entry can go. Never summarized:
    /// you save it to click it, not to search it.
    case bookmark
    /// The archive, and the real long-term asset. Most of it will never be
    /// read again — that isn't the point. The point is that months later
    /// "I saved something about opening an HSBC account" finds it, which is
    /// why this is the kind that gets a summary and keywords.
    case readlater
    /// Work to do. Written as a Markdown checkbox so Obsidian Tasks and the
    /// daily note can pick it up — a tab bar can't represent "done".
    case todo

    public var tag: String { "#\(rawValue)" }
}

/// One link on its way into the vault. Field names match the JSON the browser
/// extension posts (which in turn matched the old Rust backend's serde shape,
/// so previously-saved files stay readable).
public struct VaultLink: Codable, Sendable {
    public var title: String
    public var url: String
    public var kind: LinkKind
    public var summary: String?
    /// Search terms for finding this again later — the point of summarizing at
    /// all. Stored as one `- keywords:` line and fed into nodia's matcher.
    public var keywords: [String]
    public var source: String?
    public var mode: String?
    public var windowTitle: String?
    public var createdAt: Date?
    /// Page text extracted by the extension, used only to generate `summary`.
    /// Never written to disk — see the data-safety lines in the README.
    public var content: String?

    public init(
        title: String,
        url: String,
        kind: LinkKind = .readlater,
        summary: String? = nil,
        keywords: [String] = [],
        source: String? = nil,
        mode: String? = nil,
        windowTitle: String? = nil,
        createdAt: Date? = nil,
        content: String? = nil
    ) {
        self.title = title
        self.url = url
        self.kind = kind
        self.summary = summary
        self.keywords = keywords
        self.source = source
        self.mode = mode
        self.windowTitle = windowTitle
        self.createdAt = createdAt
        self.content = content
    }

    enum CodingKeys: String, CodingKey {
        case title, url, kind, summary, keywords, source, mode, content
        case windowTitle = "window_title"
        case createdAt = "created_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawTitle = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        url = try c.decode(String.self, forKey: .url)
        // Old saves and odd pages arrive with an empty title; the URL is a
        // better fallback than a blank bullet.
        title = TextClean.strip(rawTitle).isEmpty ? url : TextClean.strip(rawTitle)
        // Absent `kind` means a client that predates typed saves. Default to
        // readlater: it is the largest bucket and the least committal one.
        kind = try c.decodeIfPresent(LinkKind.self, forKey: .kind) ?? .readlater
        summary = try c.decodeIfPresent(String.self, forKey: .summary).map(TextClean.strip)
        keywords = (try c.decodeIfPresent([String].self, forKey: .keywords) ?? [])
            .map(TextClean.strip)
            .filter { !$0.isEmpty }
        source = try c.decodeIfPresent(String.self, forKey: .source)
        mode = try c.decodeIfPresent(String.self, forKey: .mode)
        windowTitle = try c.decodeIfPresent(String.self, forKey: .windowTitle).map(TextClean.strip)
        content = try c.decodeIfPresent(String.self, forKey: .content)
        if let raw = try c.decodeIfPresent(String.self, forKey: .createdAt) {
            createdAt = ISO8601DateFormatter.vesperParser.date(from: raw)
                ?? ISO8601DateFormatter.vesperParserNoFraction.date(from: raw)
        }
    }
}

/// Cleans text that arrives from web pages.
public enum TextClean {
    /// Drops zero-width and bidi-control characters, preserving everything
    /// else — including leading spaces, which carry meaning in Markdown.
    ///
    /// Some wiki platforms' titles begin with a long run of these as a watermark. They
    /// are not merely ugly: Swift compares strings by grapheme cluster, and a
    /// joiner binds to the character before it, so `"- \u{200C}x".hasPrefix("- ")`
    /// is **false**. Markdown parsing has to strip them before matching, or
    /// every watermarked entry silently loses its title.
    public static func removeInvisible(_ s: String) -> String {
        let cleaned = s.unicodeScalars.filter { scalar in
            switch scalar.value {
            case 0x200B...0x200F, 0x202A...0x202E, 0x2060...0x2064, 0xFEFF:
                return false
            default:
                return true
            }
        }
        return String(String.UnicodeScalarView(cleaned))
    }

    /// `removeInvisible` plus trimming — for values being stored.
    public static func strip(_ s: String) -> String {
        removeInvisible(s).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension ISO8601DateFormatter {
    static let vesperParser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static let vesperParserNoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
