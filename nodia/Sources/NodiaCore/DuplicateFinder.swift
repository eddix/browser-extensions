import Foundation

/// A set of tabs that point at the same page (after normalization), spread
/// across one or more Spaces. `keeper` is the copy to keep (most recently
/// active); `duplicates` are the redundant copies to close.
public struct TabCluster: Identifiable {
    public let id: String          // normalized URL key
    public let keeper: TabEntry
    public let duplicates: [TabEntry]

    public var all: [TabEntry] { [keeper] + duplicates }
    public var count: Int { all.count }
    /// Spaces this page is open in (keeper first), e.g. ["Recas", "External"].
    public var spaces: [String] { all.map(\.spaceTitle) }
}

public enum DuplicateFinder {
    /// Canonical key for "the same page": lowercased host, no trailing slash,
    /// no `#fragment`; query string IS kept (different params = different page).
    public static func normalizedKey(_ url: String) -> String {
        guard var comps = URLComponents(string: url) else {
            // Fallback: strip fragment + a single trailing slash textually.
            var s = url
            if let hash = s.firstIndex(of: "#") { s = String(s[..<hash]) }
            if s.count > 1 && s.hasSuffix("/") { s.removeLast() }
            return s
        }
        comps.fragment = nil
        comps.host = comps.host?.lowercased()
        if comps.path.count > 1 && comps.path.hasSuffix("/") {
            comps.path = String(comps.path.dropLast())
        }
        return comps.string ?? url
    }

    /// Clusters of duplicate tabs (size ≥ 2), most-duplicated first. Within a
    /// cluster the most-recently-active tab is the keeper.
    public static func clusters(from tabs: [TabEntry]) -> [TabCluster] {
        var groups: [String: [TabEntry]] = [:]
        for tab in tabs { groups[normalizedKey(tab.url), default: []].append(tab) }

        let clusters = groups.compactMap { key, group -> TabCluster? in
            guard group.count > 1 else { return nil }
            let sorted = group.sorted { $0.lastActiveAt > $1.lastActiveAt }
            return TabCluster(id: key, keeper: sorted[0], duplicates: Array(sorted.dropFirst()))
        }
        return clusters.sorted {
            $0.duplicates.count != $1.duplicates.count
                ? $0.duplicates.count > $1.duplicates.count
                : $0.keeper.title < $1.keeper.title
        }
    }

    /// Total number of redundant tabs that dedup would close.
    public static func redundantCount(from tabs: [TabEntry]) -> Int {
        clusters(from: tabs).reduce(0) { $0 + $1.duplicates.count }
    }
}
