import Foundation

/// One Arc sidebar tab, resolved from StorableSidebar.json.
public struct TabEntry: Identifiable, Hashable, Sendable {
    public let id: String          // Arc's tab item UUID
    public let title: String
    public let url: String
    public let spaceTitle: String  // owning Space, e.g. "Default"
    public let lastActiveAt: Double // Arc/Cocoa reference-date seconds; 0 if unknown

    public init(id: String, title: String, url: String, spaceTitle: String, lastActiveAt: Double) {
        self.id = id
        self.title = title
        self.url = url
        self.spaceTitle = spaceTitle
        self.lastActiveAt = lastActiveAt
    }

    /// Host portion of the URL, used for favicon fallback and display.
    public var host: String {
        URLComponents(string: url)?.host ?? ""
    }
}
