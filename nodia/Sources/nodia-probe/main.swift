import Foundation
import NodiaCore

// Headless smoke test for nodia's data layer.
// Usage: swift run nodia-probe [query]

let query = CommandLine.arguments.dropFirst().joined(separator: " ")

do {
    let tabs = try SidebarParser.parse()
    print("✅ parsed \(tabs.count) tabs from StorableSidebar.json")

    // Per-space breakdown (sanity-check against the AppleScript probe).
    let bySpace = Dictionary(grouping: tabs, by: \.spaceTitle)
        .sorted { $0.value.count > $1.value.count }
    for (space, list) in bySpace {
        print("   space «\(space)»: \(list.count)")
    }

    // Favicon coverage.
    let favicons = FaviconStore()
    if favicons == nil { print("⚠️  Favicons DB not readable") }
    if let favicons {
        let hits = tabs.filter { favicons.favicon(forURL: $0.url) != nil }.count
        print("🖼  favicon hit rate: \(hits)/\(tabs.count)")
    }

    // Search demo.
    let q = query.isEmpty ? "doc" : query
    print("\n🔎 top results for \"\(q)\":")
    for tab in FuzzyMatcher.rank(tabs, query: q).prefix(10) {
        let fav = favicons?.favicon(forURL: tab.url) != nil ? "🖼" : "·"
        print("  \(fav) [\(tab.spaceTitle)] \(tab.title)")
        print("      \(tab.url)")
    }

    // Duplicate clusters.
    let clusters = DuplicateFinder.clusters(from: tabs)
    let redundant = clusters.reduce(0) { $0 + $1.duplicates.count }
    print("\n♻️  duplicate clusters: \(clusters.count), redundant tabs that dedup would close: \(redundant)")
    for cluster in clusters.prefix(10) {
        print("  ×\(cluster.count)  \(cluster.keeper.title.prefix(46))")
        print("       keep [\(cluster.keeper.spaceTitle)] · close: \(cluster.duplicates.map(\.spaceTitle).joined(separator: ", "))")
    }
    // Vault index (read-only): does the store see what's already on disk?
    let vaultPath = ProcessInfo.processInfo.environment["NODIA_VAULT"]
        ?? UserDefaults.standard.string(forKey: "nodia.vault.path")
        ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Vesper").path
    print("\n📚 vault: \(vaultPath)")
    if let store = try? VaultStore(vaultRoot: URL(fileURLWithPath: vaultPath)) {
        let entries = store.allEntries()
        let byKind = Dictionary(grouping: entries, by: \.kind)
        print("   indexed \(entries.count) saved links")
        for kind in LinkKind.allCases {
            print("     \(kind.rawValue): \(byKind[kind]?.count ?? 0)")
        }
        let withSummary = entries.filter { !($0.summary ?? "").isEmpty }.count
        print("     有摘要: \(withSummary)/\(entries.count)")
        for entry in entries.prefix(3) {
            print("   · [\(entry.kind.rawValue)] \(entry.title.prefix(44))")
            if let s = entry.summary { print("       summary: \(s.prefix(50))") }
        }
    } else {
        print("   (vault 不可读，跳过)")
    }
    // Jump templates ranked alongside tabs — reproduces what ⌘⇧K shows, so a
    // "why didn't my template come up" question is answerable without the GUI.
    let jumps = JumpStore.load(vaultRoot: URL(fileURLWithPath: vaultPath))
    print("\n🔀 jump templates: \(jumps.count)")
    let jumpRows = jumps.map { t in
        TabEntry(
            id: "jump:\(t.name)", title: t.name, url: t.urlTemplate,
            spaceTitle: "跳转 · " + t.parameters.joined(separator: " · "),
            lastActiveAt: 0, origin: .jumpTemplate,
            note: (t.keywords + [t.note ?? ""]).joined(separator: " ")
        )
    }

    let probeQuery = ProcessInfo.processInfo.environment["NODIA_QUERY"] ?? "metrics"
    let vaultRows: [TabEntry] = (try? VaultStore(vaultRoot: URL(fileURLWithPath: vaultPath)))
        .map { store in
            let open = Set(tabs.map { VaultStore.normalize($0.url) })
            return store.allEntries().compactMap { e in
                open.contains(VaultStore.normalize(e.url)) ? nil : TabEntry(
                    id: "vault:\(e.url)", title: e.title, url: e.url,
                    spaceTitle: "档案", lastActiveAt: 0, origin: .vault,
                    note: e.keywords.joined(separator: " ")
                )
            }
        } ?? []

    let all = tabs + jumpRows + vaultRows
    print("\n🔎 搜索 \"\(probeQuery)\" 的排序（共 \(all.count) 条候选）:")
    for (i, row) in FuzzyMatcher.rank(all, query: probeQuery).prefix(12).enumerated() {
        let mark: String
        switch row.origin {
        case .jumpTemplate: mark = "🔀 模板"
        case .vault:        mark = "📚 档案"
        case .arcTab:       mark = "·  标签"
        }
        let score = FuzzyMatcher.score(row, query: probeQuery.lowercased(),
                                       needle: Array(probeQuery.lowercased())) ?? -1
        print(String(format: "  %2d. [%4d] %@  %@", i + 1, score, mark, String(row.title.prefix(46))))
    }
} catch {
    print("❌ \(error)")
    exit(1)
}
