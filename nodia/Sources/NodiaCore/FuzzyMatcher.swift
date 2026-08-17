import Foundation

/// Fuzzy (subsequence) ranking over tabs.
///
/// Each tab is scored against several fields independently — title, host, path,
/// space — and a low-weight whole-record fallback so cross-field queries still
/// recall. Each field uses an OPTIMAL alignment (a small DP, not greedy), so a
/// query that appears contiguously anywhere floats to the top. Field weights:
/// title > host > path > space. Empty query → most recently active first.
public enum FuzzyMatcher {

    // Per-field weights (title matters most, space least).
    private static let fields: [(KeyPath<TabEntry, String>, Double)] = [
        (\.title, 1.00),
        (\.host, 0.80),
        // Keywords are written to be searched, so they outrank the URL path —
        // a deliberate term beats an incidental substring in a slug.
        (\.note, 0.70),
        (\.path, 0.50),
        (\.spaceTitle, 0.40),
    ]

    public static func rank(_ tabs: [TabEntry], query: String) -> [TabEntry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else {
            return tabs.sorted { $0.lastActiveAt > $1.lastActiveAt }
        }
        let needle = Array(q)
        let scored: [(TabEntry, Int)] = tabs.compactMap { tab in
            guard let s = score(tab, query: q, needle: needle) else { return nil }
            return (tab, s)
        }
        return scored
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.lastActiveAt > $1.0.lastActiveAt }
            .map(\.0)
    }

    /// Best weighted field score, or nil if the query matches no field. A field
    /// that contains the query as a literal substring gets a big bonus, so real
    /// "doc"/"docx" matches dominate scattered subsequences (e.g. the "d…o…c" in
    /// "wiki.example.com").
    static func score(_ tab: TabEntry, query q: String, needle: [Character]) -> Int? {
        var best: Int?
        for (keyPath, weight) in fields {
            let field = tab[keyPath: keyPath].lowercased()
            if let s = optimalScore(needle: needle, haystack: Array(field)) {
                let bonus = field.contains(q) ? substringBonus : 0
                best = max(best ?? Int.min, Int((Double(s + bonus) * weight).rounded()))
            }
        }
        // Cross-field fallback (low weight) so multi-field queries still recall.
        let combined = "\(tab.title) \(tab.host) \(tab.path) \(tab.spaceTitle) \(tab.note)"
            .lowercased()
        if let s = optimalScore(needle: needle, haystack: Array(combined)) {
            best = max(best ?? Int.min, Int(Double(s) * 0.30))
        }
        return best
    }

    private static let consecutiveBonus = 6
    private static let boundaryBonus = 8
    private static let substringBonus = 50

    /// Highest-scoring subsequence alignment of `needle` in `haystack`, or nil if
    /// `needle` is not a subsequence. O(needle × haystack) via a prefix-max DP.
    static func optimalScore(needle: [Character], haystack: [Character]) -> Int? {
        let m = needle.count, n = haystack.count
        guard m > 0 else { return 0 }
        guard m <= n else { return nil }
        let NEG = Int.min / 4

        var prev = [Int](repeating: NEG, count: n)
        var cur = [Int](repeating: NEG, count: n)

        for i in 0..<m {
            var runningMax = NEG          // max of prev[0 ..< j] (i.e. k < j)
            for j in 0..<n {
                var value = NEG
                if haystack[j] == needle[i] {
                    let cb = charBonus(j, haystack)
                    if i == 0 {
                        value = cb
                    } else {
                        let nonConsec = runningMax == NEG ? NEG : runningMax + cb
                        let consec = (j > 0 && prev[j - 1] != NEG) ? prev[j - 1] + consecutiveBonus + cb : NEG
                        value = max(nonConsec, consec)
                    }
                }
                cur[j] = value
                if prev[j] != NEG { runningMax = max(runningMax, prev[j]) }
            }
            swap(&prev, &cur)
        }

        let best = prev.max() ?? NEG
        return best == NEG ? nil : best
    }

    /// +1 base, plus a boundary bonus when the char starts a word/segment.
    private static func charBonus(_ j: Int, _ hay: [Character]) -> Int {
        guard j > 0 else { return 1 + boundaryBonus }
        switch hay[j - 1] {
        case " ", "/", ".", "-", "_", ":", "?", "=", "&", "#": return 1 + boundaryBonus
        default: return 1
        }
    }
}
