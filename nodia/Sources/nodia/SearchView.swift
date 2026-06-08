import SwiftUI
import NodiaCore

/// The centered panel UI. Two modes: fuzzy tab search, and a duplicates view
/// (clusters of identical tabs with a one-keystroke dedupe). Colors/fonts come
/// from the active theme; keyboard handling lives in the panel controller.
struct SearchView: View {
    @ObservedObject var model: TabListModel
    @ObservedObject var themeStore: ThemeStore
    var onActivate: (TabEntry) -> Void
    var onDedupeCluster: (TabCluster) -> Void
    var onOpenSettings: () -> Void
    @FocusState private var searchFocused: Bool

    var body: some View {
        let r = themeStore.resolved
        let duplicates = model.mode == .duplicates

        ZStack {
            VisualEffectView(material: r.material).ignoresSafeArea()
            if let tint = r.palette.tint {
                tint.opacity(r.palette.tintOpacity).ignoresSafeArea()
            }

            VStack(spacing: 0) {
                header(r, duplicates: duplicates)
                Divider().overlay(r.palette.foreground.opacity(0.12))
                if duplicates { duplicateList(r) } else { searchList(r) }
                Divider().overlay(r.palette.foreground.opacity(0.12))
                footer(r, duplicates: duplicates)
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

    // MARK: header

    private func header(_ r: ResolvedTheme, duplicates: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: duplicates ? "rectangle.on.rectangle" : "magnifyingglass")
                .foregroundStyle(r.palette.secondary)
            TextField(duplicates ? "筛选重复…" : "搜索标签页…", text: $model.query)
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

    // MARK: search mode

    private func searchList(_ r: ResolvedTheme) -> some View {
        let results = model.results
        return ScrollViewReader { proxy in
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

    // MARK: duplicates mode

    private func duplicateList(_ r: ResolvedTheme) -> some View {
        let clusters = model.clusters
        return Group {
            if clusters.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "checkmark.circle").font(.system(size: 28)).foregroundStyle(r.palette.secondary)
                    Text(model.query.isEmpty ? "没有重复的标签 🎉" : "无匹配")
                        .font(r.subtitleFont).foregroundStyle(r.palette.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(clusters.enumerated()), id: \.element.id) { index, cluster in
                                ClusterRow(cluster: cluster, icon: model.icon(for: cluster.keeper),
                                           selected: index == model.selectedIndex, theme: r)
                                    .contentShape(Rectangle())
                                    .onTapGesture { onDedupeCluster(cluster) }
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                    }
                    .onChange(of: model.selectedIndex) { _, index in
                        guard clusters.indices.contains(index) else { return }
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(clusters[index].id, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    // MARK: footer

    private func footer(_ r: ResolvedTheme, duplicates: Bool) -> some View {
        HStack {
            if duplicates {
                Text("\(model.clusters.count) 组重复 · 可清理 \(model.redundantCount) 个")
                Spacer()
                Text("⏎ 关这组 · ⌘⏎ 全部 · ⌘D 返回")
            } else {
                Text("\(model.results.count) 个标签")
                Spacer()
                Text("↑↓ 选择 · ⏎ 打开 · ⌘D 去重 · esc 关闭")
            }
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

// MARK: - rows

private struct TabRow: View {
    let tab: TabEntry
    let icon: NSImage?
    let selected: Bool
    let query: String
    let theme: ResolvedTheme

    var body: some View {
        let m = MatchHighlight.matches(query: query, fields: [tab.title, tab.host, tab.spaceTitle])
        HStack(spacing: 10) {
            favicon(icon, theme: theme)
            VStack(alignment: .leading, spacing: 1) {
                Text(highlighted(tab.title, Set(m[0]), theme: theme))
                    .lineLimit(1).font(theme.titleFont).foregroundStyle(theme.palette.foreground)
                (
                    Text(highlighted(tab.host, Set(m[1]), theme: theme))
                    + Text("  ·  ")
                    + Text(highlighted(tab.spaceTitle, Set(m[2]), theme: theme))
                )
                .lineLimit(1).font(theme.subtitleFont).foregroundStyle(theme.palette.secondary)
            }
            Spacer(minLength: 8)
        }
        .rowChrome(selected: selected, theme: theme)
    }
}

private struct ClusterRow: View {
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
                    .lineLimit(1).font(theme.subtitleFont).foregroundStyle(theme.palette.secondary)
            }
            Spacer(minLength: 8)
        }
        .rowChrome(selected: selected, theme: theme)
    }
}

@ViewBuilder
private func favicon(_ icon: NSImage?, theme: ResolvedTheme) -> some View {
    Group {
        if let icon {
            Image(nsImage: icon).resizable()
        } else {
            Image(systemName: "globe").resizable().foregroundStyle(theme.palette.secondary)
        }
    }
    .frame(width: 16, height: 16)
}

private extension View {
    func rowChrome(selected: Bool, theme: ResolvedTheme) -> some View {
        self
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(selected ? theme.palette.selection : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private func highlighted(_ text: String, _ matched: Set<Int>, theme: ResolvedTheme) -> AttributedString {
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
