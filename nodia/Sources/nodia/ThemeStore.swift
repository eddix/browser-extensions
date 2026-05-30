import SwiftUI

/// Holds the active theme and persists it to UserDefaults. Shared across the
/// search panel and the settings window, so edits apply everywhere.
final class ThemeStore: ObservableObject {
    @Published var theme: Theme { didSet { save() } }

    init() { theme = ThemeStore.load() }

    var resolved: ResolvedTheme { ThemeResolver.resolve(theme) }

    private static let key = "nodia.theme"

    private func save() {
        if let data = try? JSONEncoder().encode(theme) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    private static func load() -> Theme {
        if let data = UserDefaults.standard.data(forKey: key),
           let theme = try? JSONDecoder().decode(Theme.self, from: data) {
            return theme
        }
        return .default
    }
}
