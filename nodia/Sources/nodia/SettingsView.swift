import SwiftUI
import NodiaCore

struct SettingsView: View {
    @ObservedObject var themeStore: ThemeStore

    var body: some View {
        let r = themeStore.resolved
        Form {
            Section("配色") {
                Picker("主题", selection: $themeStore.theme.paletteID) {
                    ForEach(Palettes.all) { Text($0.name).tag($0.id) }
                }
                .pickerStyle(.menu)
            }

            Section("字体") {
                Picker("字体", selection: $themeStore.theme.fontID) {
                    ForEach(FontChoice.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                VStack(alignment: .leading, spacing: 4) {
                    Text("字号 \(Int(themeStore.theme.baseSize)) pt")
                    Slider(value: $themeStore.theme.baseSize, in: 11...16, step: 1)
                }
            }

            Section("预览") {
                ThemePreview(resolved: r)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 480)
    }
}

private struct ThemePreview: View {
    let resolved: ResolvedTheme

    // Generic, non-identifying sample content (public sites only).
    var body: some View {
        ZStack {
            VisualEffectView(material: resolved.material)
            if let tint = resolved.palette.tint {
                tint.opacity(resolved.palette.tintOpacity)
            }
            VStack(alignment: .leading, spacing: 4) {
                row(title: "GitHub · Pull requests", sub: "github.com · Work",
                    query: "git", selected: true)
                row(title: "Wikipedia — the free encyclopedia", sub: "wikipedia.org · Reading",
                    query: "wiki", selected: false)
            }
            .padding(10)
        }
        .frame(height: 104)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(resolved.palette.foreground.opacity(0.10))
        )
    }

    private func row(title: String, sub: String, query: String, selected: Bool) -> some View {
        let matched = Set(MatchHighlight.matches(query: query, fields: [title])[0])
        return HStack(spacing: 8) {
            Image(systemName: "globe").foregroundStyle(resolved.palette.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(highlighted(title, matched))
                    .font(resolved.titleFont).foregroundStyle(resolved.palette.foreground)
                Text(sub).font(resolved.subtitleFont).foregroundStyle(resolved.palette.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(selected ? resolved.palette.selection : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func highlighted(_ text: String, _ matched: Set<Int>) -> AttributedString {
        var result = AttributedString()
        for (index, character) in text.enumerated() {
            var piece = AttributedString(String(character))
            if matched.contains(index) {
                piece.foregroundColor = resolved.palette.highlight
                piece.inlinePresentationIntent = .stronglyEmphasized
            }
            result += piece
        }
        return result
    }
}
