import Foundation

/// One Arc sidebar tab, resolved from StorableSidebar.json.
public struct TabEntry: Identifiable, Hashable, Sendable {
    public let id: String          // Arc's tab item UUID
    public let title: String
    public let url: String
    public let spaceTitle: String  // owning Space, e.g. "Default"
    public let lastActiveAt: Double // Arc/Cocoa reference-date seconds; 0 if unknown

    public let host: String        // e.g. "wiki.example.com"
    public let path: String        // e.g. "/docx/IZX0dHQ…" (no query/fragment)

    /// Where this row came from. All three are searched together on purpose —
    /// that single prompt is the product — but they activate differently.
    public enum Origin: String, Sendable {
        /// A live Arc tab: switch to its window.
        case arcTab
        /// A saved link: no window exists, so open the URL.
        case vault
        /// A parameterized URL: ask for the values, *then* open.
        case quickOpen
    }

    public let origin: Origin

    /// Kept as a convenience because "does this have a live window" is the
    /// question most callers actually ask.
    public var isVault: Bool { origin != .arcTab }

    /// Second line of the row. Nil means "show the URL", which is what a tab
    /// wants; a saved link would rather show its summary, since that's the
    /// part worth reading.
    public let subtitle: String?

    /// Extra text that should match a query but isn't worth screen space —
    /// a saved link's keywords, so "the one about 接口定义" finds it even when
    /// neither the title nor the URL says that.
    public let note: String

    public init(
        id: String,
        title: String,
        url: String,
        spaceTitle: String,
        lastActiveAt: Double,
        origin: Origin = .arcTab,
        subtitle: String? = nil,
        note: String = ""
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.spaceTitle = spaceTitle
        self.lastActiveAt = lastActiveAt
        self.origin = origin
        self.subtitle = subtitle
        self.note = note

        let comps = URLComponents(string: url)
        self.host = comps?.host ?? ""
        self.path = comps?.path ?? ""
    }

    /// Host + path, for display (more than just the host, no query/fragment noise).
    public var prettyURL: String {
        host.isEmpty ? url : host + path
    }

    /// What the row's second line actually shows.
    public var detailLine: String { subtitle ?? prettyURL }
}
