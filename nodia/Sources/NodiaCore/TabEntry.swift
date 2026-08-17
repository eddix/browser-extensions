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

    /// True for rows that come from the Obsidian vault rather than a live Arc
    /// tab. They have no window to switch to, so they open by URL — and being
    /// searchable next to real tabs is the point: it's what makes closing a
    /// tab safe, because the saved copy surfaces the same way.
    public let isVault: Bool

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
        isVault: Bool = false,
        note: String = ""
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.spaceTitle = spaceTitle
        self.lastActiveAt = lastActiveAt
        self.isVault = isVault
        self.note = note

        let comps = URLComponents(string: url)
        self.host = comps?.host ?? ""
        self.path = comps?.path ?? ""
    }

    /// Host + path, for display (more than just the host, no query/fragment noise).
    public var prettyURL: String {
        host.isEmpty ? url : host + path
    }
}
