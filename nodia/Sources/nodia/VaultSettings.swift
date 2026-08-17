import Foundation
import NodiaCore
import SwiftUI

/// Settings for the vault side of nodia: where the Obsidian vault lives, the
/// local port the extension talks to, and the shared token.
///
/// The token lives in UserDefaults rather than the Keychain on purpose — it
/// guards a loopback port, is regenerable with one click, and prompting for
/// Keychain access on every launch would be worse. LLM API keys are a
/// different matter and do go to the Keychain (see `SecretStore`).
final class VaultSettings: ObservableObject {
    @Published var vaultPath: String { didSet { save() } }
    @Published var port: Int { didSet { save() } }
    @Published private(set) var token: String { didSet { save() } }
    /// Server status, surfaced in Settings so a silent failure is visible.
    @Published var status: String = "未启动"
    /// LLM routing. Endpoints and models are stored here; the API keys live in
    /// the Keychain (`SecretStore`) and never touch UserDefaults or the repo.
    @Published var summarizer: Summarizer.Config { didSet { save() } }

    private enum Key {
        static let vaultPath = "nodia.vault.path"
        static let port = "nodia.vault.port"
        static let token = "nodia.vault.token"
        static let summarizer = "nodia.vault.summarizer"
    }

    init() {
        let d = UserDefaults.standard
        vaultPath = d.string(forKey: Key.vaultPath) ?? VaultSettings.defaultVaultPath()
        let storedPort = d.integer(forKey: Key.port)
        port = storedPort == 0 ? 8787 : storedPort
        if let existing = d.string(forKey: Key.token), !existing.isEmpty {
            token = existing
        } else {
            token = SharedToken.generate()
        }
        if let data = d.data(forKey: Key.summarizer),
           let decoded = try? JSONDecoder().decode(Summarizer.Config.self, from: data) {
            summarizer = decoded
        } else {
            summarizer = Summarizer.Config()
        }
        save()
    }

    var vaultURL: URL { URL(fileURLWithPath: (vaultPath as NSString).expandingTildeInPath) }

    func regenerateToken() {
        token = SharedToken.generate()
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(vaultPath, forKey: Key.vaultPath)
        d.set(port, forKey: Key.port)
        d.set(token, forKey: Key.token)
        if let data = try? JSONEncoder().encode(summarizer) {
            d.set(data, forKey: Key.summarizer)
        }
    }

    /// The vault the old Rust backend was configured against, if it is still
    /// there — makes the migration a no-op for an existing setup.
    private static func defaultVaultPath() -> String {
        let legacy = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".vesper/config.toml")
        if let text = try? String(contentsOf: legacy, encoding: .utf8) {
            for line in text.components(separatedBy: .newlines) where line.hasPrefix("path") {
                guard let q1 = line.firstIndex(of: "\""),
                      let q2 = line.lastIndex(of: "\""), q1 < q2 else { continue }
                let path = String(line[line.index(after: q1)..<q2])
                if FileManager.default.fileExists(atPath: path) { return path }
            }
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Vesper").path
    }
}
