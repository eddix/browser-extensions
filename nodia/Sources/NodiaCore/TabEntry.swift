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

    public init(id: String, title: String, url: String, spaceTitle: String, lastActiveAt: Double) {
        self.id = id
        self.title = title
        self.url = url
        self.spaceTitle = spaceTitle
        self.lastActiveAt = lastActiveAt

        let comps = URLComponents(string: url)
        self.host = comps?.host ?? ""
        self.path = comps?.path ?? ""
    }

    /// Host + path, for display (more than just the host, no query/fragment noise).
    public var prettyURL: String {
        host.isEmpty ? url : host + path
    }
}
