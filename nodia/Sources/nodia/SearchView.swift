import SwiftUI
import NodiaCore

/// The centered search panel UI: a frosted search field over a flat, fuzzy
/// ranked list. Colors/fonts come from the active theme; keyboard navigation is
/// handled by the panel controller's local event monitor.
struct SearchView: View {
    @ObservedObject var model: TabListModel
    @ObservedObject var themeStore: ThemeStore
    var onActivate: (TabEntry) -> Void
    var onOpenSettings: () -> Void
    @FocusState private var searchFocused: Bool

    var body: some View {
        let r = themeStore.resolved
        let results = model.results

        ZStack {
            VisualEffectView(material: r.material).ignoresSafeArea()
            if let tint = r.palette.tint {
                tint.opacity(r.palette.tintOpacity).ignoresSafeArea()
            }

            VStack(spacing: 0) {
                header(r)
                Divider().overlay(r.palette.foreground.opacity(0.12))
                list(r, results: results)
                Divider().overlay(r.palette.foreground.opacity(0.12))
                footer(r, count: results.count)
            }
        }
        .frame(width: 640, height: 420)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(r.palette.foreground.opacity(0.10))
        )
        .onAppear { focusSoon() }
        .onChange(of: model.focusRequest) { _, _ in focusSoon() }
    }

    private func header(_ r: ResolvedTheme) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(r.palette.secondary)
            TextField("搜索标签页…", text: $model.query)
                .textFieldStyle(.plain)
                .font(r.searchFont)
                .foregroundStyle(r.palette.foreground)
                .focused($searchFocused)
            Button(action: onOpenSettings) {
                Image(systemName: "gearshape").foregroundStyle(r.palette.secondary)
            }
            .buttonStyle(.plain)
            .help("设置")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func list(_ r: ResolvedTheme, results: [TabEntry]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, tab in
                        TabRow(tab: tab, icon: model.icon(for: tab),
                               selected: index == model.selectedIndex,
                               query: model.query, theme: r)
                            .contentShape(Rectangle())
                            .onTapGesture { onActivate(tab) }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .onChange(of: model.selectedIndex) { _, index in
                guard results.indices.contains(index) else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(results[index].id, anchor: .center)
                }
            }
        }
    }

    private func footer(_ r: ResolvedTheme, count: Int) -> some View {
        HStack {
            Text("\(count) 个标签")
            Spacer()
            Text("↑↓ 选择 · ⏎ 打开 · esc 关闭")
        }
        .font(r.captionFont)
        .foregroundStyle(r.palette.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func focusSoon() {
        DispatchQueue.main.async { searchFocused = true }
    }
}

private struct TabRow: View {
    let tab: TabEntry
    let icon: NSImage?
    let selected: Bool
    let query: String
    let theme: ResolvedTheme

    var body: some View {
        // Greedy match positions across title → host → space, for highlighting.
        let m = MatchHighlight.matches(query: query, fields: [tab.title, tab.host, tab.spaceTitle])

        HStack(spacing: 10) {
            Group {
                if let icon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "globe").resizable().foregroundStyle(theme.palette.secondary)
                }
            }
            .frame(width: 16, height: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(highlighted(tab.title, Set(m[0])))
                    .lineLimit(1).font(theme.titleFont).foregroundStyle(theme.palette.foreground)
                (
                    Text(highlighted(tab.host, Set(m[1])))
                    + Text("  ·  ")
                    + Text(highlighted(tab.spaceTitle, Set(m[2])))
                )
                .lineLimit(1).font(theme.subtitleFont).foregroundStyle(theme.palette.secondary)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(selected ? theme.palette.selection : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// Matched character offsets get the palette's highlight color + bold; the
    /// rest inherit the surrounding foreground style.
    private func highlighted(_ text: String, _ matched: Set<Int>) -> AttributedString {
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
}
