import Foundation

/// Locates which characters of the query matched, for highlighting in the UI.
///
/// Each field is matched INDEPENDENTLY: a field highlights only if the whole
/// query is a subsequence of it (so the field that actually matched lights up,
/// and an unrelated field stays plain). Offsets index the original field string
/// by `Character`.
public enum MatchHighlight {
    public static func matches(query: String, fields: [String]) -> [[Int]] {
        let needle = Array(query.lowercased())
        guard !needle.isEmpty else { return fields.map { _ in [] } }

        return fields.map { field in
            var positions: [Int] = []
            var qi = 0
            for (charIndex, character) in field.enumerated() {
                if qi < needle.count, String(character).lowercased().first == needle[qi] {
                    positions.append(charIndex)
                    qi += 1
                }
            }
            return qi == needle.count ? positions : []
        }
    }
}
