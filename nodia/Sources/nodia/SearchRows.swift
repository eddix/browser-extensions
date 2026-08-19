import SwiftUI
import NodiaCore

/// One row of any tab-shaped list: search results, quick-open templates, and
/// the tabs under a domain heading all use this one.
struct TabRow: View {
    let tab: TabEntry
    let icon: NSImage?
    let selected: Bool
    let query: String
    let theme: ResolvedTheme
    var showsTag: Bool = true

    var body: some View {
        // Highlight fields: title, the detail line (URL, or a saved link's
        // summary), and the right-hand tag. A tab's tag is its Space name,
        // which no longer participates in matching — highlighting it would
        // claim a match that didn't happen.
        let taggable = tab.origin == .arcTab ? "" : tab.spaceTitle
        let m = MatchHighlight.matches(query: query, fields: [tab.title, tab.detailLine, taggable])
        HStack(spacing: 10) {
            favicon(icon, theme: theme)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 8) {
                    Text(highlighted(tab.title, Set(m[0]), theme: theme))
                        .lineLimit(1).font(theme.titleFont).foregroundStyle(theme.palette.foreground)
                    Spacer(minLength: 8)
                    if showsTag && !tab.spaceTitle.isEmpty {
                        // Capped and truncating: this tag shares a line with the
                        // title, so an unexpectedly long value must shrink
                        // rather than push the row past the panel's edge.
                        Text(highlighted(tab.spaceTitle, Set(m[2]), theme: theme))
                            .lineLimit(1).truncationMode(.tail)
                            .font(theme.captionFont)
                            .foregroundStyle(theme.palette.secondary)
                            .layoutPriority(-1)
                            .frame(maxWidth: 180, alignment: .trailing)
                    }
                }
                Text(highlighted(tab.detailLine, Set(m[1]), theme: theme))
                    .lineLimit(1).truncationMode(.tail)
                    .font(theme.subtitleFont).foregroundStyle(theme.palette.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .rowChrome(selected: selected, theme: theme)
        .help(tab.url)
    }
}

/// One group of tabs pointing at the same page, in the duplicates view.
struct ClusterRow: View {
    let cluster: TabCluster
    let icon: NSImage?
    let selected: Bool
    let theme: ResolvedTheme

    var body: some View {
        HStack(spacing: 10) {
            favicon(icon, theme: theme)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(cluster.keeper.title)
                        .lineLimit(1).font(theme.titleFont).foregroundStyle(theme.palette.foreground)
                    Text("×\(cluster.count)")
                        .font(theme.captionFont.weight(.semibold))
                        .foregroundStyle(theme.palette.highlight)
                }
                Text("保留 \(cluster.keeper.spaceTitle) · 关 \(cluster.duplicates.map(\.spaceTitle).joined(separator: ", "))")
                    .lineLimit(1).font(theme.subtitleFont)
                    .foregroundStyle(theme.palette.secondary)
            }
            Spacer(minLength: 8)
        }
        .rowChrome(selected: selected, theme: theme)
    }
}

/// One "label + keycaps" footer hint, e.g. 打开 [⏎] or 分组 [⌘][G].
struct KeyHint: View {
    let label: String
    let keys: [String]
    let theme: ResolvedTheme

    var body: some View {
        HStack(spacing: 5) {
            Text(label)
                .font(theme.captionFont)
                .foregroundStyle(theme.palette.secondary)
            HStack(spacing: 2) {
                ForEach(keys, id: \.self) { key in
                    Text(key)
                        .font(theme.captionFont.weight(.medium))
                        .foregroundStyle(theme.palette.secondary)
                        .frame(minWidth: 13)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(theme.palette.foreground.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
            }
        }
    }
}

@ViewBuilder
func favicon(_ icon: NSImage?, theme: ResolvedTheme) -> some View {
    Group {
        if let icon {
            Image(nsImage: icon).resizable()
        } else {
            Image(systemName: "globe").resizable().foregroundStyle(theme.palette.secondary)
        }
    }
    .frame(width: 18, height: 18)
    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
}

extension View {
    /// Selected-row treatment: a faint fill plus an accent stroke.
    ///
    /// The fill has to stay faint because it *lightens* the background, and
    /// every point of alpha it gains is taken out of the contrast of the text
    /// sitting on it — which is what made a selected row's URL unreadable in
    /// half the palettes. The stroke carries the visibility instead: it says
    /// "this row" just as clearly and changes nothing underneath the text.
    func rowChrome(selected: Bool, theme: ResolvedTheme) -> some View {
        self
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(selected ? theme.palette.selection : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? theme.palette.accent.opacity(0.55) : .clear)
            )
    }
}

func highlighted(_ text: String, _ matched: Set<Int>, theme: ResolvedTheme) -> AttributedString {
    // Building this a character at a time costs roughly 45× a plain init, and
    // it's paid three times per row. On an empty query — the list you stare at
    // most, before you've typed anything — every one of those characters comes
    // out unstyled, so the expensive version and the cheap one produce the same
    // string. Same for any field the query didn't match.
    guard !matched.isEmpty else { return AttributedString(text) }

    var result = AttributedString()
    for (index, character) in text.enumerated() {
        var piece = AttributedString(String(character))
        if matched.contains(index) {
            piece.foregroundColor = theme.palette.highlight
            piece.inlinePresentationIntent = .stronglyEmphasized
        }
        result += piece
    }
    return result
}
