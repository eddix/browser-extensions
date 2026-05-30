import Foundation

/// Locates which characters of the query matched, for highlighting in the UI.
///
/// Mirrors the fuzzy (subsequence) ranking: the query is consumed greedily,
/// left to right, across the given fields in order (e.g. title → host → space).
/// Returns, per field, the character offsets that matched — offsets index the
/// ORIGINAL field string (by `Character`), so callers can highlight them
/// directly.
public enum MatchHighlight {
    public static func matches(query: String, fields: [String]) -> [[Int]] {
        let needle = Array(query.lowercased())
        var result = [[Int]](repeating: [], count: fields.count)
        guard !needle.isEmpty else { return result }

        var qi = 0
        for (fieldIndex, field) in fields.enumerated() {
            for (charIndex, character) in field.enumerated() {
                if qi >= needle.count { return result }
                if String(character).lowercased().first == needle[qi] {
                    result[fieldIndex].append(charIndex)
                    qi += 1
                }
            }
        }
        return result
    }
}
