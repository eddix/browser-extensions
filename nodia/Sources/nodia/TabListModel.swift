import AppKit
import SwiftUI
import NodiaCore

/// Observable state behind the search panel. `results` is a *computed* value
/// derived from `query` + the loaded tabs, so the search field, list, and count
/// can never drift out of sync (no `@Published` mutated inside another's didSet).
final class TabListModel: ObservableObject {
    enum Mode { case search, duplicates, byDomain }

    @Published var query: String = "" {
        didSet { if selectedIndex != 0 { selectedIndex = 0 } }
    }
    @Published var mode: Mode = .search
    @Published var selectedIndex: Int = 0
    @Published var focusRequest: Int = 0   // bumped to (re)focus the search field

    private var arcTabs: [TabEntry] = []
    private var vaultTabs: [TabEntry] = []
    private var tabs: [TabEntry] { arcTabs + vaultTabs }
    private weak var vaultStore: VaultStore?
    private let favicons: FaviconStore?
    private var iconCache: [String: NSImage] = [:]

    init() {
        favicons = FaviconStore()
        reload()
    }

    /// Lets search reach saved links, not just open tabs.
    func attachVault(_ store: VaultStore?) {
        vaultStore = store
        reloadVault()
    }

    /// Re-read the sidebar (cheap; ~ms for a few hundred tabs).
    func reload() {
        do {
            arcTabs = try SidebarParser.parse()
            let spaces = Set(arcTabs.map(\.spaceTitle)).count
            Log.write("reload: parsed \(arcTabs.count) tabs across \(spaces) spaces")
        } catch {
            arcTabs = []
            Log.write("reload: parse FAILED: \(error)")
        }
        reloadVault()
        fillIconCache()
    }

    private static let kindLabel: [LinkKind: String] = [
        .bookmark: "书签", .readlater: "稍后读", .todo: "待办",
    ]

    /// Vault entries ride the same pipeline as tabs, so ranking, highlighting
    /// and the keyboard all work unchanged. A URL that is *also* an open tab is
    /// dropped here — switching to the live tab always beats reopening it.
    private func reloadVault() {
        guard let vaultStore else { vaultTabs = []; return }

        let openURLs = Set(arcTabs.map { VaultStore.normalize($0.url) })
        vaultTabs = vaultStore.allEntries().compactMap { entry in
            guard !openURLs.contains(VaultStore.normalize(entry.url)) else { return nil }
            // The subtitle slot carries the kind and the summary: visible at a
            // glance, and searchable, since this field is ranked too.
            var subtitle = Self.kindLabel[entry.kind] ?? "收藏"
            if let summary = entry.summary, !summary.isEmpty {
                subtitle += " · \(summary)"
            }
            return TabEntry(
                id: "vault:\(entry.relativePath):\(entry.url)",
                title: entry.title,
                url: entry.url,
                spaceTitle: subtitle,
                lastActiveAt: 0,          // sorts below live tabs on an empty query
                isVault: true,
                // Matched but not shown: the row already carries the summary.
                note: entry.keywords.joined(separator: " ")
            )
        }
        Log.write("reload: \(vaultTabs.count) vault entries (\(vaultStore.allEntries().count) total)")
    }

    func requestFocus() { focusRequest &+= 1 }

    var results: [TabEntry] { FuzzyMatcher.rank(tabs, query: query) }

    func moveSelection(_ delta: Int) {
        let count: Int
        switch mode {
        case .search:     count = results.count
        case .duplicates: count = clusters.count
        case .byDomain:   count = flatDomainTabs.count
        }
        guard count > 0 else { return }
        selectedIndex = max(0, min(count - 1, selectedIndex + delta))
    }

    /// ⌘D: toggle the duplicates view against search.
    func toggleMode() {
        mode = (mode == .duplicates) ? .search : .duplicates
        selectedIndex = 0
    }

    /// ⌘G: toggle the by-domain view against search.
    func toggleDomainMode() {
        mode = (mode == .byDomain) ? .search : .byDomain
        selectedIndex = 0
    }

    var selectedTab: TabEntry? {
        let list: [TabEntry]
        switch mode {
        case .search:     list = results
        case .byDomain:   list = flatDomainTabs
        case .duplicates: return nil   // duplicates mode selects clusters, not tabs
        }
        return list.indices.contains(selectedIndex) ? list[selectedIndex] : nil
    }

    // Duplicate clusters (most-duplicated first), filtered by the current query
    // so the view and the keyboard selection always agree on the same list.
    var clusters: [TabCluster] {
        let all = DuplicateFinder.clusters(from: tabs)
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter {
            $0.keeper.title.lowercased().contains(q)
                || $0.keeper.url.lowercased().contains(q)
                || $0.spaces.joined(separator: " ").lowercased().contains(q)
        }
    }
    var redundantCount: Int { clusters.reduce(0) { $0 + $1.duplicates.count } }
    var selectedCluster: TabCluster? {
        let c = clusters
        return c.indices.contains(selectedIndex) ? c[selectedIndex] : nil
    }
    var allDuplicates: [TabEntry] { clusters.flatMap(\.duplicates) }

    // Tabs grouped by domain (arc-tab-sorter parity), filtered by the current
    // query as a plain substring over title/url/domain. `flatDomainTabs` is the
    // group order flattened — the view renders `domainGroups`, the keyboard
    // walks `flatDomainTabs`, and both stay in lockstep via `selectedIndex`.
    var domainGroups: [DomainGroup] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = q.isEmpty ? tabs : tabs.filter {
            $0.title.lowercased().contains(q)
                || $0.url.lowercased().contains(q)
                || DomainFinder.domain(for: $0).lowercased().contains(q)
        }
        return DomainFinder.groups(from: filtered)
    }
    var flatDomainTabs: [TabEntry] { domainGroups.flatMap(\.tabs) }

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
