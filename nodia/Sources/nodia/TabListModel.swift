import AppKit
import SwiftUI
import NodiaCore

/// Observable state behind the search panel. `results` is a *computed* value
/// derived from `query` + the loaded tabs, so the search field, list, and count
/// can never drift out of sync (no `@Published` mutated inside another's didSet).
final class TabListModel: ObservableObject {
    enum Mode { case search, duplicates, byDomain, quickOpen }

    @Published var query: String = "" {
        didSet { if selectedIndex != 0 { selectedIndex = 0 } }
    }
    @Published var mode: Mode = .search
    @Published var selectedIndex: Int = 0
    @Published var focusRequest: Int = 0   // bumped to (re)focus the search field

    private var arcTabs: [TabEntry] = []
    private var vaultTabs: [TabEntry] = []
    private var quickOpenRows: [TabEntry] = []
    private var tabs: [TabEntry] { arcTabs + quickOpenRows + vaultTabs }
    private weak var vaultStore: VaultStore?

    // MARK: - Jump templates

    private var templates: [QuickOpenTemplate] = []

    let quickOpenState = QuickOpenState()

    /// Set while filling in a template's parameters. The state machine itself
    /// lives in NodiaCore (`QuickOpenForm`) so its rules — which are fussier
    /// than they look — can be tested without standing up a window.
    @Published private(set) var filling: QuickOpenForm?

    private let favicons: FaviconStore?
    private var iconCache: [String: NSImage] = [:]

    init() {
        favicons = FaviconStore()
        reload()
    }

    /// Lets search reach saved links and quick-open templates, not just open tabs.
    func attachVault(_ store: VaultStore?) {
        vaultStore = store
        reloadVault()
        reloadQuickOpen()
    }

    /// Quick-open templates are rows like any other, so one prompt covers open
    /// tabs, saved links, and parameterized platform URLs.
    private func reloadQuickOpen() {
        guard let vaultStore else { templates = []; quickOpenRows = []; return }
        templates = QuickOpenStore.load(vaultRoot: vaultStore.vaultRoot).templates
        quickOpenRows = templates.map { t in
            let params = t.parameters.map { "{\($0)}" }.joined(separator: " ")
            return TabEntry(
                id: "qo:\(t.name)",
                title: t.name,
                url: t.urlTemplate,
                spaceTitle: "快速打开",
                // A template has no "last active" the way a tab does, so this
                // slot carries its usage score instead — the same question
                // (which of these did you mean) asked of a different kind of
                // row. Scores are small and tab timestamps are epoch seconds,
                // so templates still sit below live tabs on an empty query.
                lastActiveAt: quickOpenState.score(named: t.name),
                origin: .quickOpen,
                subtitle: t.note ?? (params.isEmpty ? t.urlTemplate : "参数：\(params)"),
                note: (t.keywords + [t.urlTemplate]).joined(separator: " ")
            )
        }
        // Most-used first, so ⌘T settles into an order worth learning by
        // position. Name breaks ties — including the all-zeros tie on a fresh
        // install, where an unstable sort would otherwise reshuffle the list
        // every time you opened it.
        quickOpenRows.sort {
            $0.lastActiveAt != $1.lastActiveAt
                ? $0.lastActiveAt > $1.lastActiveAt
                : $0.title < $1.title
        }
        Log.write("reload: \(templates.count) quick-open templates")
    }

    func template(for entry: TabEntry) -> QuickOpenTemplate? {
        guard entry.origin == .quickOpen else { return nil }
        return templates.first { "qo:\($0.name)" == entry.id }
    }

    /// Enters the parameter form. Returns false if this isn't a template with
    /// parameters — one without any is just a URL, and should open.
    @discardableResult
    func beginFilling(_ entry: TabEntry) -> Bool {
        guard let t = template(for: entry) else { return false }
        return beginFilling(t)
    }

    @discardableResult
    func beginFilling(_ t: QuickOpenTemplate) -> Bool {
        guard !t.parameters.isEmpty else { return false }
        filling = QuickOpenForm(template: t, state: quickOpenState)
        return true
    }

    func fieldText(_ parameter: String) -> String { filling?.text(of: parameter) ?? "" }
    var fillingCandidates: [Choice] { filling?.candidates ?? [] }
    var fillingHasCandidateList: Bool { filling?.hasCandidateList ?? false }
    var fillingHighlight: Int { filling?.highlighted ?? 0 }
    var fillingURL: URL? { filling?.url }

    /// A tab already showing exactly this URL, if there is one.
    func liveTab(for url: URL) -> TabEntry? {
        QuickOpenMatch.liveTab(for: url, in: arcTabs)
    }
    var firstBlankField: Int? { filling?.firstBlank }

    func setDraft(_ text: String) {
        guard var f = filling, text != f.draft else { return }
        f.type(text)
        filling = f
    }

    func takeCandidate(_ choice: Choice) {
        guard var f = filling else { return }
        f.take(choice)
        filling = f
    }

    func focusNextField() {
        guard var f = filling else { return }
        f.focusNext()
        filling = f
    }

    func focusField(_ index: Int) {
        guard var f = filling else { return }
        f.focusField(index)
        filling = f
    }

    func cancelFilling() {
        filling = nil
        query = ""
        selectedIndex = 0
        // The form took the keyboard away from the search field, and nothing
        // gives it back on the way out — `show()` is the only other place that
        // asks for focus, and esc doesn't go through it. Without this you land
        // on the list with the caret nowhere and have to click the field before
        // you can type again.
        requestFocus()
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
        reloadQuickOpen()
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
        if var f = filling {
            f.moveHighlight(delta)
            filling = f
            return
        }
        let count: Int
        switch mode {
        case .search:     count = results.count
        case .duplicates: count = clusters.count
        case .byDomain:   count = flatDomainTabs.count
        case .quickOpen:      count = quickOpenResults.count
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

    /// ⌘T: browse the quick-open templates. They already surface in plain
    /// search, but only if you remember one exists — this is the answer to
    /// "what can I open?", which is not a question search can answer.
    func toggleQuickOpenMode() {
        mode = (mode == .quickOpen) ? .search : .quickOpen
        query = ""
        selectedIndex = 0
    }

    /// Templates in ⌘T mode, filtered by a plain substring so browsing stays
    /// predictable — this list is short enough not to need ranking.
    var quickOpenResults: [TabEntry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return quickOpenRows }
        return quickOpenRows.filter {
            $0.title.lowercased().contains(q) || $0.note.lowercased().contains(q)
                || $0.url.lowercased().contains(q)
        }
    }

    var selectedTab: TabEntry? {
        let list: [TabEntry]
        switch mode {
        case .search:     list = results
        case .byDomain:   list = flatDomainTabs
        case .quickOpen:      list = quickOpenResults
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
