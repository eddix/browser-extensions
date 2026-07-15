import Foundation

/// One domain's worth of tabs, for the "browse by domain" view. `tabs` are
/// sorted by title; groups themselves are sorted by `domain`. Mirrors the old
/// arc-tab-sorter popup: domain = host with a leading "www." dropped.
public struct DomainGroup: Identifiable {
    public let domain: String      // e.g. "google.com", or "其他" for URL-less tabs
    public let tabs: [TabEntry]    // sorted by title (zh, case/diacritic-insensitive)

    public var id: String { domain }
    public var count: Int { tabs.count }
}

public enum DomainFinder {
    /// zh collation, matching arc-tab-sorter's `localeCompare(_, 'zh')`.
    private static let zh = Locale(identifier: "zh_Hans_CN")

    /// The grouping key for a tab: its host with a leading "www." stripped.
    /// Empty host (blank/opaque URL) falls back to "其他", as arc-tab-sorter did.
    public static func domain(for tab: TabEntry) -> String {
        let host = tab.host
        guard !host.isEmpty else { return "其他" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Tabs bucketed by domain. Within a group, tabs are sorted by title; groups
    /// are returned sorted by domain — both using zh collation to match the old
    /// extension. An empty input yields an empty array.
    public static func groups(from tabs: [TabEntry]) -> [DomainGroup] {
        var buckets: [String: [TabEntry]] = [:]
        for tab in tabs { buckets[domain(for: tab), default: []].append(tab) }

        return buckets
            .map { domain, list in
                DomainGroup(domain: domain, tabs: list.sorted { a, b in
                    // sensitivity: 'base' ≈ ignore case + diacritics
                    a.title.compare(b.title,
                                    options: [.caseInsensitive, .diacriticInsensitive],
                                    range: nil, locale: zh) == .orderedAscending
                })
            }
            .sorted { $0.domain.compare($1.domain, options: [], range: nil, locale: zh) == .orderedAscending }
    }
}
