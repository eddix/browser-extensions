import AppKit
import SwiftUI
import NodiaCore

/// Observable state behind the search panel. `results` is a *computed* value
/// derived from `query` + the loaded tabs, so the search field, list, and count
/// can never drift out of sync (no `@Published` mutated inside another's didSet).
final class TabListModel: ObservableObject {
    enum Mode { case search, duplicates, byDomain, jumps }

    @Published var query: String = "" {
        didSet { if selectedIndex != 0 { selectedIndex = 0 } }
    }
    @Published var mode: Mode = .search
    @Published var selectedIndex: Int = 0
    @Published var focusRequest: Int = 0   // bumped to (re)focus the search field

    private var arcTabs: [TabEntry] = []
    private var vaultTabs: [TabEntry] = []
    private var jumpRows: [TabEntry] = []
    private var tabs: [TabEntry] { arcTabs + jumpRows + vaultTabs }
    private weak var vaultStore: VaultStore?

    // MARK: - Jump templates

    private var templates: [JumpTemplate] = []

    /// Set while filling in a jump's parameters. The search field becomes the
    /// input for one parameter at a time, so the same keyboard drives both
    /// finding a jump and completing it.
    @Published private(set) var filling: Filling?

    struct Filling {
        let template: JumpTemplate
        var values: [String: String] = [:]
        var index: Int = 0

        var parameter: String { template.parameters[index] }
        var isLast: Bool { index == template.parameters.count - 1 }
        var progress: String { "\(index + 1)/\(template.parameters.count)" }
    }
    private let favicons: FaviconStore?
    private var iconCache: [String: NSImage] = [:]

    init() {
        favicons = FaviconStore()
        reload()
    }

    /// Lets search reach saved links and jump templates, not just open tabs.
    func attachVault(_ store: VaultStore?) {
        vaultStore = store
        reloadVault()
        reloadJumps()
    }

    /// Jump templates are rows like any other, so one prompt covers open tabs,
    /// saved links, and parameterized platform jumps.
    private func reloadJumps() {
        guard let vaultStore else { templates = []; jumpRows = []; return }
        templates = JumpStore.load(vaultRoot: vaultStore.vaultRoot)
        jumpRows = templates.map { t in
            let params = t.parameters.map { "{\($0)}" }.joined(separator: " ")
            return TabEntry(
                id: "jump:\(t.name)",
                title: t.name,
                url: t.urlTemplate,
                spaceTitle: "跳转",
                lastActiveAt: 0,
                origin: .jumpTemplate,
                subtitle: t.note ?? (params.isEmpty ? t.urlTemplate : "参数：\(params)"),
                note: (t.keywords + [t.urlTemplate]).joined(separator: " ")
            )
        }
        Log.write("reload: \(templates.count) jump templates")
    }

    func template(for entry: TabEntry) -> JumpTemplate? {
        guard entry.origin == .jumpTemplate else { return nil }
        return templates.first { "jump:\($0.name)" == entry.id }
    }

    /// Enters parameter-filling mode. Returns false if this isn't a template.
    @discardableResult
    func beginFilling(_ entry: TabEntry) -> Bool {
        guard let t = template(for: entry), !t.parameters.isEmpty else { return false }
        filling = Filling(template: t)
        query = ""
        selectedIndex = 0
        return true
    }

    /// Candidates for the parameter being filled, narrowed by what's typed.
    /// A parameter with no candidate list is free input — the typed text is
    /// offered back as the single option.
    var fillingOptions: [String] {
        guard let filling else { return [] }
        let all = filling.template.options(for: filling.parameter)
        let q = query.trimmingCharacters(in: .whitespaces)
        if all.isEmpty { return q.isEmpty ? [] : [q] }
        guard !q.isEmpty else { return all }
        let matched = all.filter { $0.lowercased().contains(q.lowercased()) }
        // Typed something that isn't in the list — still allow it.
        return matched.isEmpty ? [q] : matched
    }

    /// Commits one value. Returns the URL once every parameter is filled.
    func commitFillingValue(_ value: String) -> URL? {
        guard var f = filling else { return nil }
        f.values[f.parameter] = value
        if f.isLast {
            filling = nil
            query = ""
            return f.template.expand(f.values)
        }
        f.index += 1
        filling = f
        query = ""
        selectedIndex = 0
        return nil
    }

    func cancelFilling() {
        filling = nil
        query = ""
        selectedIndex = 0
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
        reloadJumps()
        fillIconCache()
    }

    // Labels name what each kind is *for*: a console link is somewhere you
    // jump to, an archive entry is something you'll want to find again.
    private static let kindLabel: [LinkKind: String] = [
        .bookmark: "平台", .readlater: "档案", .todo: "待办",
    ]

    /// Vault entries ride the same pipeline as tabs, so ranking, highlighting
    /// and the keyboard all work unchanged. A URL that is *also* an open tab is
    /// dropped here — switching to the live tab always beats reopening it.
    private func reloadVault() {
        guard let vaultStore else { vaultTabs = []; return }

        let openURLs = Set(arcTabs.map { VaultStore.normalize($0.url) })
        vaultTabs = vaultStore.allEntries().compactMap { entry in
            guard !openURLs.contains(VaultStore.normalize(entry.url)) else { return nil }
            // The right-hand tag stays short — it shares a line with the title.
            // The summary goes on the detail line, where a URL would be: for a
            // saved link the summary is the part worth reading.
            let summary = entry.summary ?? ""
            return TabEntry(
                id: "vault:\(entry.relativePath):\(entry.url)",
                title: entry.title,
                url: entry.url,
                spaceTitle: Self.kindLabel[entry.kind] ?? "收藏",
                lastActiveAt: 0,          // sorts below live tabs on an empty query
                origin: .vault,
                subtitle: summary.isEmpty ? nil : summary,
                // Keywords match without taking space; the summary is matchable
                // too, so searching a phrase from it finds the entry.
                note: (entry.keywords + [summary]).joined(separator: " ")
            )
        }
        Log.write("reload: \(vaultTabs.count) vault entries (\(vaultStore.allEntries().count) total)")
    }

    func requestFocus() { focusRequest &+= 1 }

    var results: [TabEntry] { FuzzyMatcher.rank(tabs, query: query) }

    func moveSelection(_ delta: Int) {
        if filling != nil {
            let count = fillingOptions.count
            guard count > 0 else { return }
            selectedIndex = max(0, min(count - 1, selectedIndex + delta))
            return
        }
        let count: Int
        switch mode {
        case .search:     count = results.count
        case .duplicates: count = clusters.count
        case .byDomain:   count = flatDomainTabs.count
        case .jumps:      count = jumpResults.count
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

    /// ⌘T: browse the jump templates. They already surface in plain search,
    /// but only if you remember one exists — this is the answer to "what can
    /// I jump to?", which is not a question search can answer.
    func toggleJumpMode() {
        mode = (mode == .jumps) ? .search : .jumps
        query = ""
        selectedIndex = 0
    }

    /// Templates in ⌘T mode, filtered by a plain substring so browsing stays
    /// predictable — this list is short enough not to need ranking.
    var jumpResults: [TabEntry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return jumpRows }
        return jumpRows.filter {
            $0.title.lowercased().contains(q) || $0.note.lowercased().contains(q)
                || $0.url.lowercased().contains(q)
        }
    }

    var selectedTab: TabEntry? {
        let list: [TabEntry]
        switch mode {
        case .search:     list = results
        case .byDomain:   list = flatDomainTabs
        case .jumps:      list = jumpResults
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
