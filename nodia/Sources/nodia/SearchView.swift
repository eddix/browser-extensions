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
    var onTakeCandidate: (Choice) -> Void
    var onOpenSettings: () -> Void
    @FocusState private var searchFocused: Bool
    @FocusState private var focusedParameter: String?

    var body: some View {
        let r = themeStore.resolved
        let mode = model.mode

        // No background of its own: the glass shell this is embedded in is the
        // background, and any wash painted in here would only cover it up.
        VStack(spacing: 0) {
            header(r, mode: mode)
            Divider().overlay(r.palette.foreground.opacity(0.12))
            if let filling = model.filling {
                fillingForm(filling, r)
            } else {
                switch mode {
                case .duplicates: duplicateList(r)
                case .byDomain:   domainList(r)
                case .quickOpen:      quickOpenList(r)
                case .search:     searchList(r)
                }
            }
            Divider().overlay(r.palette.foreground.opacity(0.12))
            footer(r, mode: mode)
        }
        .frame(width: 640, height: 460)
        // Clipped even though the glass is already round, because the glass
        // does *not* clip what you hand it — its header only promises the
        // content will be placed inside the effect. Anything in here that
        // paints edge to edge (an NSScrollView draws a control background of
        // its own) then shows its square corners poking out past the rounded
        // glass, four of them, which reads as a rectangular frame drawn around
        // the panel.
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onAppear { focusSoon() }
        .onChange(of: model.focusRequest) { _, _ in focusSoon() }
    }

    // MARK: header

    // Raycast-style header: no leading icon in plain search (the placeholder is
    // enough); duplicates/byDomain show a tinted context chip instead, so the
    // active mode is visible at a glance.
    private func header(_ r: ResolvedTheme, mode: TabListModel.Mode) -> some View {
        HStack(spacing: 10) {
            // The form owns the keyboard while it's up: one search field plus
            // several parameter fields would be two things competing for focus,
            // and the search field has nothing to search at that point.
            if let filling = model.filling {
                modeChip(filling.template.name, icon: "bolt", r)
                if let note = filling.template.note {
                    Text(note)
                        .lineLimit(1).truncationMode(.tail)
                        .font(r.subtitleFont)
                        .foregroundStyle(r.palette.secondary)
                }
                Spacer(minLength: 8)
            } else {
                switch mode {
                case .duplicates: modeChip("重复标签", icon: "rectangle.on.rectangle", r)
                case .byDomain:   modeChip("按域名", icon: "square.grid.2x2", r)
                case .quickOpen:  modeChip("快速打开", icon: "bolt", r)
                case .search:     EmptyView()
                }
                TextField(Self.placeholder(for: mode), text: $model.query)
                    .textFieldStyle(.plain)
                    .font(r.searchFont)
                    .foregroundStyle(r.palette.foreground)
                    .tint(r.palette.accent)
                    .focused($searchFocused)
            }
            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
                    .foregroundStyle(r.palette.secondary.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help("设置")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private static func placeholder(for mode: TabListModel.Mode) -> String {
        switch mode {
        case .search:     return "搜索标签页…"
        case .duplicates: return "筛选重复…"
        case .byDomain:   return "按域名筛选…"
        case .quickOpen:  return "筛选快速打开…"
        }
    }

    private func modeChip(_ label: String, icon: String, _ r: ResolvedTheme) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold))
            Text(label).font(r.captionFont.weight(.semibold))
        }
        .foregroundStyle(r.palette.accent)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(r.palette.accent.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    // MARK: search mode

    /// Every parameter at once, with the candidates for whichever one has the
    /// keyboard underneath.
    ///
    /// One field at a time meant you couldn't see what you'd already chosen,
    /// couldn't go back to change it, and paid a keystroke per parameter even
    /// when every answer was the one you gave last time.
    private func fillingForm(_ filling: QuickOpenForm, _ r: ResolvedTheme) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(filling.parameters.enumerated()), id: \.element) { index, parameter in
                    fillingField(parameter, index: index, filling: filling, r)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 12)

            // The fields and the list under them are two different things —
            // what you're filling in, and what you can fill it with. Running
            // them together on nothing but whitespace made the section caption
            // read as a third form row.
            Divider()
                .overlay(r.palette.foreground.opacity(0.10))
                .padding(.horizontal, 16)

            candidateList(r)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Focus follows the model, and the model follows clicks — kept one-way
        // in each direction so the two can't ping-pong.
        .onAppear { focusedParameter = filling.parameter }
        .onChange(of: model.filling?.parameter) { _, p in
            if focusedParameter != p { focusedParameter = p }
        }
        .onChange(of: focusedParameter) { _, p in
            guard let p, p != model.filling?.parameter,
                  let i = model.filling?.parameters.firstIndex(of: p) else { return }
            model.focusField(i)
        }
    }

    private func fillingField(
        _ parameter: String, index: Int, filling: QuickOpenForm, _ r: ResolvedTheme
    ) -> some View {
        let focused = parameter == filling.parameter
        let value = filling.values[parameter] ?? ""
        let shown = model.fieldText(parameter)
        return HStack(spacing: 10) {
            Text(parameter)
                .font(r.subtitleFont)
                .foregroundStyle(focused ? r.palette.accent : r.palette.secondary)
                .lineLimit(1)
                .frame(width: 92, alignment: .trailing)

            HStack(spacing: 8) {
                TextField("输入…", text: Binding(
                    get: { shown },
                    // Only the focused field is an input; the others are just
                    // showing what they hold.
                    set: { if focused { model.setDraft($0) } }
                ))
                .textFieldStyle(.plain)
                .font(r.titleFont)
                .foregroundStyle(r.palette.foreground)
                // Selection and caret would otherwise come out in the system
                // blue, which fights every palette here.
                .tint(r.palette.accent)
                .focused($focusedParameter, equals: parameter)

                Spacer(minLength: 8)

                // A value that reads nothing like what you see deserves to say
                // so on the same line: "SG" gives no hint the URL says `sg`.
                // Given its own chip rather than loose dim text, because loose
                // dim text at the end of a lit row is where legibility goes to
                // die — which is exactly what happened the first time.
                if !value.isEmpty && value != shown {
                    Text(value)
                        .font(r.captionFont)
                        .foregroundStyle(r.palette.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(r.palette.foreground.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            // Every field gets a filled shape, focused or not. Without one an
            // empty field renders as nothing at all — a label with blank space
            // beside it, which reads as a missing row rather than a box you
            // can type in.
            .background(focused ? r.palette.selection : r.palette.foreground.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(focused ? r.palette.accent.opacity(0.45) : .clear)
            )
            .frame(maxWidth: 400, alignment: .leading)

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { model.focusField(index) }
    }

    private func candidateList(_ r: ResolvedTheme) -> some View {
        let candidates = model.fillingCandidates
        let known = model.fillingHasCandidateList
        return Group {
            if candidates.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: known ? "magnifyingglass" : "keyboard")
                        .font(.system(size: 22)).foregroundStyle(r.palette.secondary)
                    Text(known ? "无匹配的候选值" : "自由输入，⏎ 打开")
                        .font(r.subtitleFont).foregroundStyle(r.palette.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    Text(known ? "候选" : "最近用过")
                        .font(r.captionFont)
                        .foregroundStyle(r.palette.secondary)
                        .padding(.horizontal, 18)
                        .padding(.bottom, 4)
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                ForEach(Array(candidates.enumerated()), id: \.element) { i, c in
                                    HStack(spacing: 8) {
                                        Image(systemName: known ? "circle.fill" : "clock")
                                            .font(.system(size: known ? 6 : 10))
                                            .foregroundStyle(r.palette.secondary)
                                            .frame(width: 14)
                                        Text(c.label)
                                            .font(r.titleFont)
                                            .foregroundStyle(r.palette.foreground)
                                        if c.label != c.value {
                                            Text(c.value)
                                                .font(r.subtitleFont)
                                                .foregroundStyle(r.palette.secondary)
                                        }
                                        Spacer()
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(i == model.fillingHighlight ? r.palette.selection : .clear)
                                    .clipShape(RoundedRectangle(cornerRadius: 7))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 7)
                                            .strokeBorder(i == model.fillingHighlight
                                                          ? r.palette.accent.opacity(0.55) : .clear)
                                    )
                                    .contentShape(Rectangle())
                                    // Identity is the candidate, never its
                                    // position — the same rule every other list
                                    // here follows, and for the same reason.
                                    .id(c.value)
                                    .onTapGesture { onTakeCandidate(c) }
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.bottom, 6)
                        }
                        .onChange(of: model.fillingHighlight) { _, i in
                            guard candidates.indices.contains(i) else { return }
                            withAnimation(.easeOut(duration: 0.12)) {
                                proxy.scrollTo(candidates[i].value, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Every quick-open template. Plain search surfaces these too, but only once
    /// you know one exists — this is the browsable answer.
    private func quickOpenList(_ r: ResolvedTheme) -> some View {
        let rows = model.quickOpenResults
        return Group {
            if rows.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "bolt")
                        .font(.system(size: 28)).foregroundStyle(r.palette.secondary)
                    Text(model.query.isEmpty ? "还没有快速打开模板" : "无匹配")
                        .font(r.subtitleFont).foregroundStyle(r.palette.secondary)
                    if model.query.isEmpty {
                        Text("在收藏库的 \(QuickOpenStore.fileName) 里添加")
                            .font(r.captionFont).foregroundStyle(r.palette.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                                // Identity has to be the row's own id — the same
                                // one ForEach uses. Overriding it with the
                                // position made SwiftUI treat "row 0 of six" and
                                // "row 0 of one" as the same view and keep the
                                // old contents, so filtering down to a single
                                // template still displayed whichever one
                                // happened to be first before you typed.
                                // No tag: in this list every row is a
                                // template, so printing "快速打开" on each of
                                // them says nothing and costs a column.
                                TabRow(tab: row, icon: nil, selected: index == model.selectedIndex,
                                       query: model.query, theme: r, showsTag: false)
                                    .id(row.id)
                                    .onTapGesture { onActivate(row) }
                            }
                        }
                        .padding(.horizontal, 8).padding(.vertical, 6)
                    }
                    .onChange(of: model.selectedIndex) { _, i in
                        guard rows.indices.contains(i) else { return }
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(rows[i].id, anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func searchList(_ r: ResolvedTheme) -> some View {
        let results = model.results
        return Group {
            if results.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 28)).foregroundStyle(r.palette.secondary)
                    Text(model.query.isEmpty ? "没有标签" : "无匹配")
                        .font(r.subtitleFont).foregroundStyle(r.palette.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
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

    // MARK: by-domain mode

    private enum DomainRow: Identifiable {
        case header(domain: String, count: Int)
        case tab(TabEntry, index: Int)

        var id: String {
            switch self {
            case let .header(domain, _): return "h:\(domain)"
            case let .tab(tab, _):       return "t:\(tab.id)"
            }
        }
    }

    private func domainList(_ r: ResolvedTheme) -> some View {
        let groups = model.domainGroups
        // Flatten to display rows; number only the tab rows so the running index
        // lines up with model.selectedIndex / model.flatDomainTabs.
        var rows: [DomainRow] = []
        var flat = 0
        for group in groups {
            rows.append(.header(domain: group.domain, count: group.count))
            for tab in group.tabs {
                rows.append(.tab(tab, index: flat))
                flat += 1
            }
        }

        return Group {
            if groups.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 28)).foregroundStyle(r.palette.secondary)
                    Text(model.query.isEmpty ? "没有标签" : "无匹配")
                        .font(r.subtitleFont).foregroundStyle(r.palette.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(rows) { row in
                                switch row {
                                case let .header(domain, count):
                                    domainHeader(domain, count: count, r)
                                case let .tab(tab, index):
                                    TabRow(tab: tab, icon: model.icon(for: tab),
                                           selected: index == model.selectedIndex,
                                           query: model.query, theme: r)
                                        .id(tab.id)
                                        .contentShape(Rectangle())
                                        .onTapGesture { onActivate(tab) }
                                }
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                    }
                    .onChange(of: model.selectedIndex) { _, index in
                        let tabs = model.flatDomainTabs
                        guard tabs.indices.contains(index) else { return }
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(tabs[index].id, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    private func domainHeader(_ domain: String, count: Int, _ r: ResolvedTheme) -> some View {
        HStack(spacing: 6) {
            Text(domain)
                .font(r.captionFont.weight(.semibold))
                .foregroundStyle(r.palette.secondary)
            Text("· \(count)")
                .font(r.captionFont)
                .foregroundStyle(r.palette.secondary.opacity(0.7))
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }

    // MARK: footer

    // Raycast-style footer: count on the left, keycap hint chips on the right
    // (2-3 max — arrows/esc are muscle memory, not worth the clutter).
    private func footer(_ r: ResolvedTheme, mode: TabListModel.Mode) -> some View {
        HStack(spacing: 14) {
            if model.filling != nil {
                // The URL as it stands, and it is literally what ⏎ opens —
                // built from the same values, not assembled a second time.
                Text(model.fillingURL?.absoluteString ?? "还缺一个值")
                    .lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(
                        model.fillingURL == nil ? r.palette.secondary : r.palette.foreground
                    )
                Spacer(minLength: 8)
                KeyHint(label: "打开", keys: ["⏎"], theme: r)
                KeyHint(label: "下一个", keys: ["⇥"], theme: r)
            } else {
            switch mode {
            case .duplicates:
                Text("\(model.clusters.count) 组重复 · 可清理 \(model.redundantCount) 个")
                Spacer()
                KeyHint(label: "关这组", keys: ["⏎"], theme: r)
                KeyHint(label: "全部", keys: ["⌘", "⏎"], theme: r)
                KeyHint(label: "返回", keys: ["⌘", "D"], theme: r)
            case .byDomain:
                Text("\(model.domainGroups.count) 域名 · \(model.flatDomainTabs.count) 标签")
                Spacer()
                KeyHint(label: "打开", keys: ["⏎"], theme: r)
                KeyHint(label: "返回", keys: ["⌘", "G"], theme: r)
            case .quickOpen:
                Text("\(model.quickOpenResults.count) 个快速打开模板")
                Spacer()
                KeyHint(label: "填参数", keys: ["⏎"], theme: r)
                KeyHint(label: "返回", keys: ["⌘", "T"], theme: r)
            case .search:
                Text("\(model.results.count) 个标签")
                Spacer()
                KeyHint(label: "打开", keys: ["⏎"], theme: r)
                KeyHint(label: "快速打开", keys: ["⌘", "T"], theme: r)
                KeyHint(label: "域名", keys: ["⌘", "G"], theme: r)
                KeyHint(label: "去重", keys: ["⌘", "D"], theme: r)
            }
            }
        }
        .font(r.captionFont)
        .foregroundStyle(r.palette.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    private func focusSoon() {
        // Not while the form is up — it has its own fields, and stealing focus
        // back to a search box that isn't even rendered loses the keystroke.
        DispatchQueue.main.async { if model.filling == nil { searchFocused = true } }
    }
}

// MARK: - rows

private struct TabRow: View {
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
                    .lineLimit(1).font(theme.subtitleFont)
                    .foregroundStyle(theme.palette.secondary)
            }
            Spacer(minLength: 8)
        }
        .rowChrome(selected: selected, theme: theme)
    }
}

/// One "label + keycaps" footer hint, e.g. 打开 [⏎] or 分组 [⌘][G].
private struct KeyHint: View {
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
private func favicon(_ icon: NSImage?, theme: ResolvedTheme) -> some View {
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

private extension View {
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
