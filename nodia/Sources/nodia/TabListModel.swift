import AppKit
import SwiftUI
import NodiaCore

/// Observable state behind the search panel. `results` is a *computed* value
/// derived from `query` + the loaded tabs, so the search field, list, and count
/// can never drift out of sync (no `@Published` mutated inside another's didSet).
final class TabListModel: ObservableObject {
    @Published var query: String = "" {
        didSet { if selectedIndex != 0 { selectedIndex = 0 } }
    }
    @Published var selectedIndex: Int = 0
    @Published var focusRequest: Int = 0   // bumped to (re)focus the search field

    private var tabs: [TabEntry] = []
    private let favicons: FaviconStore?
    private var iconCache: [String: NSImage] = [:]

    init() {
        favicons = FaviconStore()
        reload()
    }

    /// Re-read the sidebar (cheap; ~ms for a few hundred tabs).
    func reload() {
        do {
            tabs = try SidebarParser.parse()
            let spaces = Set(tabs.map(\.spaceTitle)).count
            Log.write("reload: parsed \(tabs.count) tabs across \(spaces) spaces")
        } catch {
            tabs = []
            Log.write("reload: parse FAILED: \(error)")
        }
        fillIconCache()
    }

    func requestFocus() { focusRequest &+= 1 }

    var results: [TabEntry] { FuzzyMatcher.rank(tabs, query: query) }

    func moveSelection(_ delta: Int) {
        let count = results.count
        guard count > 0 else { return }
        selectedIndex = max(0, min(count - 1, selectedIndex + delta))
    }

    var selectedTab: TabEntry? {
        let r = results
        return r.indices.contains(selectedIndex) ? r[selectedIndex] : nil
    }

    func icon(for tab: TabEntry) -> NSImage? { iconCache[tab.url] }

    private func fillIconCache() {
        guard let favicons else { return }
        for tab in tabs where iconCache[tab.url] == nil {
            if let data = favicons.favicon(forURL: tab.url), let image = NSImage(data: data) {
                iconCache[tab.url] = image
            }
        }
    }
}
