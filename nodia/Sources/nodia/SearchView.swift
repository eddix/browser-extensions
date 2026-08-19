import SwiftUI
import NodiaCore

/// The centered panel UI. Four lists — fuzzy search, quick-open templates,
/// duplicate clusters, and tabs by domain — plus the parameter form, which is
/// not a fifth mode but a state laid over whichever one you came from: it takes
/// the whole body and the keyboard while it's up, and esc puts you back.
///
/// The lists themselves are `SelectionList`; the rows they hold are in
/// `SearchRows`. What's left here is the assembly: which list, what goes in it,
/// and what the header and footer say about it.
///
/// Colors/fonts come from the active theme; keyboard handling lives in the
/// panel controller.
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
                case .quickOpen:  quickOpenList(r)
                case .search:     searchList(r)
                }
            }
            Divider().overlay(r.palette.foreground.opacity(0.12))
            footer(r, mode: mode)
        }
        .frame(width: PanelMetrics.size.width, height: PanelMetrics.size.height)
        // Clipped even though the glass is already round, because the glass
        // does *not* clip what you hand it — its header only promises the
        // content will be placed inside the effect. Anything in here that
        // paints edge to edge (an NSScrollView draws a control background of
        // its own) then shows its square corners poking out past the rounded
        // glass, four of them, which reads as a rectangular frame drawn around
        // the panel.
        .clipShape(RoundedRectangle(cornerRadius: PanelMetrics.cornerRadius, style: .continuous))
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

    // MARK: - parameter form

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
            .padding(.vertical, 12)

            // The fields and the list under them are two different things —
            // what you're filling in, and what you can fill it with. Running
            // them together on nothing but whitespace made the section caption
            // read as a third form row.
            Divider()
                .overlay(r.palette.foreground.opacity(0.10))
                .padding(.horizontal, 16)

            candidateList(r).padding(.top, 8)
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
                EmptyState(
                    icon: known ? "magnifyingglass" : "keyboard",
                    message: known ? "无匹配的候选值" : "自由输入，⏎ 打开",
                    iconSize: 22, theme: r
                )
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    Text(known ? "候选" : "最近用过")
                        .font(r.captionFont)
                        .foregroundStyle(r.palette.secondary)
                        .padding(.horizontal, 18)
                        .padding(.bottom, 4)
                    SelectionList(
                        targets: candidates.map(\.value),
                        selected: model.fillingHighlight,
                        // No top inset: the caption above already provides the
                        // gap, and a second one reads as a hole.
                        insets: EdgeInsets(top: 0, leading: 8, bottom: 6, trailing: 8)
                    ) {
                        ForEach(Array(candidates.enumerated()), id: \.element) { i, c in
                            candidateRow(c, highlighted: i == model.fillingHighlight, known: known, r)
                                .selectableRow(id: c.value) { onTakeCandidate(c) }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func candidateRow(
        _ c: Choice, highlighted: Bool, known: Bool, _ r: ResolvedTheme
    ) -> some View {
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
        .background(highlighted ? r.palette.selection : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(highlighted ? r.palette.accent.opacity(0.55) : .clear)
        )
    }

    // MARK: - quick open

    /// Every quick-open template. Plain search surfaces these too, but only once
    /// you know one exists — this is the browsable answer.
    private func quickOpenList(_ r: ResolvedTheme) -> some View {
        let rows = model.quickOpenResults
        let problems = model.quickOpenProblems
        return VStack(spacing: 0) {
            // Above the list rather than only in place of it, because parsing
            // keeps every template it *could* read: the ordinary shape of a
            // broken config is nine templates that work and a tenth that
            // silently isn't there. Showing the reason only when the list came
            // back completely empty would explain the one case you'd have
            // guessed on your own.
            if !problems.isEmpty { configProblems(problems, r) }

            if rows.isEmpty {
                EmptyState(
                    icon: "bolt",
                    // "还没有" would be a wrong answer when the file is full of
                    // templates the parser rejected — the banner above is
                    // already saying they exist.
                    message: model.query.isEmpty
                        ? (problems.isEmpty ? "还没有快速打开模板" : "没有一条模板能用")
                        : "无匹配",
                    hint: model.query.isEmpty && problems.isEmpty
                        ? "在收藏库的 \(QuickOpenStore.fileName) 里添加" : nil,
                    theme: r
                )
            } else {
                SelectionList(targets: rows.map(\.id), selected: model.selectedIndex) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        // No tag: in this list every row is a template, so
                        // printing "快速打开" on each of them says nothing and
                        // costs a column.
                        TabRow(tab: row, icon: nil, selected: index == model.selectedIndex,
                               query: model.query, theme: r, showsTag: false)
                            .selectableRow(id: row.id) { onActivate(row) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// What the config file says that the app couldn't use. Each line names the
    /// template it came from — "缺少 url" on its own only tells you to go read
    /// the whole file.
    private func configProblems(_ problems: [String], _ r: ResolvedTheme) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                Text("\(QuickOpenStore.fileName) 有 \(problems.count) 处问题")
                    .font(r.captionFont.weight(.semibold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(r.palette.highlight)

            // Capped, because this sits on top of the list it's warning about
            // and a config with thirty complaints would push every template off
            // the panel — turning a hint into the thing standing in your way.
            ForEach(Array(problems.prefix(3).enumerated()), id: \.offset) { _, problem in
                Text(problem)
                    .font(r.captionFont)
                    .foregroundStyle(r.palette.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if problems.count > 3 {
                Text("还有 \(problems.count - 3) 处…")
                    .font(r.captionFont)
                    .foregroundStyle(r.palette.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(r.palette.highlight.opacity(0.10))
    }

    // MARK: - search

    private func searchList(_ r: ResolvedTheme) -> some View {
        let results = model.results
        return Group {
            if results.isEmpty {
                EmptyState(
                    icon: "magnifyingglass",
                    message: model.query.isEmpty ? "没有标签" : "无匹配",
                    theme: r
                )
            } else {
                SelectionList(targets: results.map(\.id), selected: model.selectedIndex) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, tab in
                        TabRow(tab: tab, icon: model.icon(for: tab),
                               selected: index == model.selectedIndex,
                               query: model.query, theme: r)
                            .selectableRow(id: tab.id) { onActivate(tab) }
                    }
                }
            }
        }
    }

    // MARK: - duplicates

    private func duplicateList(_ r: ResolvedTheme) -> some View {
        let clusters = model.clusters
        return Group {
            if clusters.isEmpty {
                EmptyState(
                    icon: "checkmark.circle",
                    message: model.query.isEmpty ? "没有重复的标签 🎉" : "无匹配",
                    theme: r
                )
            } else {
                SelectionList(targets: clusters.map(\.id), selected: model.selectedIndex) {
                    ForEach(Array(clusters.enumerated()), id: \.element.id) { index, cluster in
                        ClusterRow(cluster: cluster, icon: model.icon(for: cluster.keeper),
                                   selected: index == model.selectedIndex, theme: r)
                            .selectableRow(id: cluster.id) { onDedupeCluster(cluster) }
                    }
                }
            }
        }
    }

    // MARK: - by domain

    private enum DomainRow: Identifiable {
        case header(domain: String, count: Int)
        case tab(TabEntry, index: Int)

        /// Prefixed so a domain and a tab can never collide, and distinct from
        /// the id the rows themselves carry — the keyboard walks tabs only, so
        /// `SelectionList`'s targets are the bare tab ids while `ForEach`
        /// identifies headers and tabs alike from here.
        var id: String {
            switch self {
            case let .header(domain, _): return "h:\(domain)"
            case let .tab(tab, _):       return "t:\(tab.id)"
            }
        }
    }

    private func domainList(_ r: ResolvedTheme) -> some View {
        let groups = model.domainGroups
        // Flattened for display; only the tab rows are numbered, so the running
        // index lines up with model.selectedIndex and model.flatDomainTabs.
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
                EmptyState(
                    icon: "magnifyingglass",
                    message: model.query.isEmpty ? "没有标签" : "无匹配",
                    theme: r
                )
            } else {
                SelectionList(
                    targets: model.flatDomainTabs.map(\.id), selected: model.selectedIndex
                ) {
                    ForEach(rows) { row in
                        switch row {
                        case let .header(domain, count):
                            domainHeader(domain, count: count, r)
                        case let .tab(tab, index):
                            // The bare tab id, not this row's prefixed one:
                            // it's what the scroller is given to look for, and
                            // a key it can't find is a scroll that silently
                            // doesn't happen.
                            TabRow(tab: tab, icon: model.icon(for: tab),
                                   selected: index == model.selectedIndex,
                                   query: model.query, theme: r)
                                .selectableRow(id: tab.id) { onActivate(tab) }
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

    // MARK: - footer

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
