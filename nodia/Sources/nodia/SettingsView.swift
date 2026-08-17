import SwiftUI
import NodiaCore

struct SettingsView: View {
    @ObservedObject var themeStore: ThemeStore
    @ObservedObject var vaultSettings: VaultSettings
    let onVaultSettingsChanged: () -> Void

    @State private var tokenCopied = false
    @State private var keyDrafts: [String: String] = [:]

    var body: some View {
        TabView {
            appearance.tabItem { Text("外观") }
            vault.tabItem { Text("收藏库") }
            summary.tabItem { Text("摘要") }
        }
        .frame(width: 460, height: 560)
    }

    // MARK: - Summary

    private var summary: some View {
        Form {
            Section {
                Toggle("保存时生成摘要", isOn: $vaultSettings.summarizer.enabled)
                Text("摘要让「存下来能搜到」成立——标题往往只是文档名。正文仅在你点击保存时抓取一次，用完即弃，不写进收藏库。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("内网页面") {
                endpointFields(endpoint: $vaultSettings.summarizer.intranet)
                Text("匹配内网域名的页面只发往这里。**没配就不发**，宁可没有摘要——泄露无法撤回。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("公网页面") {
                endpointFields(endpoint: $vaultSettings.summarizer.publicNet)
            }

            Section("内网域名") {
                TextEditor(text: Binding(
                    get: { vaultSettings.summarizer.intranetSuffixes.joined(separator: "\n") },
                    set: { text in
                        vaultSettings.summarizer.intranetSuffixes = text
                            .components(separatedBy: .newlines)
                            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                            .filter { !$0.isEmpty }
                    }
                ))
                .font(.system(.caption, design: .monospaced))
                .frame(height: 90)
                Text("每行一个域名后缀，含子域。命中即视为内网。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func endpointFields(endpoint: Binding<Summarizer.Endpoint>) -> some View {
        Picker("协议", selection: endpoint.wire) {
            ForEach(WireProtocol.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        TextField(
            "接口地址",
            text: endpoint.url,
            prompt: Text(endpoint.wrappedValue.wire == .anthropic
                         ? "https://…/v1/messages"
                         : "https://…/v1/chat/completions")
        )
        .textFieldStyle(.roundedBorder)
        TextField("模型", text: endpoint.model, prompt: Text("model name"))
            .textFieldStyle(.roundedBorder)
        HStack {
            SecureField("API Key", text: keyBinding(for: endpoint.wrappedValue.keyAccount),
                        prompt: Text(SecretStore.has(endpoint.wrappedValue.keyAccount)
                                     ? "已保存在钥匙串" : "sk-…"))
                .textFieldStyle(.roundedBorder)
            if SecretStore.has(endpoint.wrappedValue.keyAccount) {
                Button("清除") {
                    SecretStore.set("", for: endpoint.wrappedValue.keyAccount)
                    keyDrafts[endpoint.wrappedValue.keyAccount] = ""
                }
            }
        }
        Text("Key 存进 macOS 钥匙串，不落配置文件、不进仓库。")
            .font(.caption).foregroundStyle(.secondary)
    }

    /// Keys are write-only from the UI: typed here, pushed to the Keychain,
    /// never read back into the field.
    private func keyBinding(for account: String) -> Binding<String> {
        Binding(
            get: { keyDrafts[account] ?? "" },
            set: { value in
                keyDrafts[account] = value
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { SecretStore.set(trimmed, for: account) }
            }
        )
    }

    // MARK: - Vault

    private var vault: some View {
        Form {
            Section("Obsidian vault") {
                HStack {
                    TextField("路径", text: $vaultSettings.vaultPath)
                        .textFieldStyle(.roundedBorder)
                    Button("选择…") { chooseVault() }
                }
                Text("浏览器扩展保存的链接会写进这里的 Bookmark/ 目录。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("本地接口") {
                HStack {
                    Text("端口")
                    TextField("端口", value: $vaultSettings.port, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                    Spacer()
                    Button("重启服务", action: onVaultSettingsChanged)
                }
                LabeledContent("状态") {
                    Text(vaultSettings.status)
                        .foregroundStyle(vaultSettings.status.hasPrefix("监听") ? .green : .secondary)
                }
                if !vaultSettings.status.hasPrefix("监听") {
                    Text("卡在「正在打开收藏库」通常是缺少访问权限：系统设置 → 隐私与安全性 → 文件和文件夹 → nodia，勾选「文稿」文件夹。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("配对令牌") {
                HStack {
                    Text(vaultSettings.token)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button(tokenCopied ? "已复制" : "复制") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(vaultSettings.token, forType: .string)
                        tokenCopied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { tokenCopied = false }
                    }
                    Button("重新生成") {
                        vaultSettings.regenerateToken()
                        onVaultSettingsChanged()
                    }
                }
                Text("粘贴到浏览器扩展的设置页。没有它，本机任何网页都能读写你的收藏库——这正是旧后端的漏洞。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func chooseVault() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = vaultSettings.vaultURL
        if panel.runModal() == .OK, let url = panel.url {
            vaultSettings.vaultPath = url.path
            onVaultSettingsChanged()
        }
    }

    // MARK: - Appearance

    private var appearance: some View {
        let r = themeStore.resolved
        return Form {
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

            Section("透明度") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("面板不透明度 \(Int(themeStore.theme.opacity * 100))%")
                    Slider(value: $themeStore.theme.opacity, in: 0.6...1.0, step: 0.05)
                    Text("下次打开面板时生效。略微透光会让它更像浮层，而不是一扇盖住屏幕的窗。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("预览") {
                ThemePreview(resolved: r)
            }
        }
        .formStyle(.grouped)
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
