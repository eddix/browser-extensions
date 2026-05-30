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
} catch {
    print("❌ \(error)")
    exit(1)
}
