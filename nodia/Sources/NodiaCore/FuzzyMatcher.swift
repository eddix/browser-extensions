import Foundation

/// Lightweight subsequence fuzzy matching/ranking over tabs.
///
/// A query matches if its characters appear in order within the haystack
/// (`title + url + space`). Score rewards consecutive runs and matches at word
/// boundaries, so the tightest match floats to the top. Empty query → most
/// recently active first.
public enum FuzzyMatcher {

    public static func rank(_ tabs: [TabEntry], query: String) -> [TabEntry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else {
            return tabs.sorted { $0.lastActiveAt > $1.lastActiveAt }
        }
        let needle = Array(q)
        let scored: [(TabEntry, Int)] = tabs.compactMap { tab in
            let hay = "\(tab.title) \(tab.url) \(tab.spaceTitle)".lowercased()
            guard let s = score(needle: needle, haystack: Array(hay)) else { return nil }
            return (tab, s)
        }
        return scored
            .sorted {
                $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.lastActiveAt > $1.0.lastActiveAt
            }
            .map(\.0)
    }

    /// Returns a score if `needle` is a subsequence of `haystack`, else nil.
    static func score(needle: [Character], haystack: [Character]) -> Int? {
        var ni = 0
        var total = 0
        var streak = 0
        var prevMatch = -2
        for (hi, hc) in haystack.enumerated() {
            guard ni < needle.count else { break }
            if hc == needle[ni] {
                var bonus = 1
                if hi == prevMatch + 1 { streak += 1; bonus += streak * 3 } else { streak = 0 }
                if hi == 0 || haystack[hi - 1] == " " || haystack[hi - 1] == "/" || haystack[hi - 1] == "." {
                    bonus += 5   // word-boundary match
                }
                total += bonus
                prevMatch = hi
                ni += 1
            }
        }
        return ni == needle.count ? total : nil
    }
}
