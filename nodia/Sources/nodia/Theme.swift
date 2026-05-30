import SwiftUI
import AppKit

/// Persisted user theme: which palette, font family, and base size.
struct Theme: Codable, Equatable {
    var paletteID: String
    var fontID: String
    var baseSize: Double

    static let `default` = Theme(paletteID: "system", fontID: "system", baseSize: 13)
}

enum FontChoice: String, CaseIterable, Identifiable {
    case system, rounded, mono, serif
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "系统"
        case .rounded: return "圆体"
        case .mono: return "等宽"
        case .serif: return "衬线"
        }
    }
    var design: Font.Design {
        switch self {
        case .system: return .default
        case .rounded: return .rounded
        case .mono: return .monospaced
        case .serif: return .serif
        }
    }
}

/// A color scheme. `isDark == nil` means "follow the system" (the System palette).
struct Palette: Identifiable, Equatable {
    let id: String
    let name: String
    let isDark: Bool?
    let tint: Color?          // colored overlay over the glass; nil = pure glass
    let tintOpacity: Double
    let foreground: Color
    let secondary: Color
    let accent: Color
    let selection: Color       // selected-row background
    let highlight: Color       // matched characters
}

/// Everything the views need, derived from a `Theme`.
struct ResolvedTheme {
    let palette: Palette
    let material: NSVisualEffectView.Material
    let nsAppearance: NSAppearance?
    let searchFont: Font
    let titleFont: Font
    let subtitleFont: Font
    let captionFont: Font
}

enum ThemeResolver {
    static func resolve(_ theme: Theme) -> ResolvedTheme {
        let palette = Palettes.byID[theme.paletteID] ?? Palettes.system
        let font = FontChoice(rawValue: theme.fontID) ?? .system
        let base = theme.baseSize

        let material: NSVisualEffectView.Material
        let appearance: NSAppearance?
        switch palette.isDark {
        case .some(true):  material = .hudWindow; appearance = NSAppearance(named: .darkAqua)
        case .some(false): material = .popover;   appearance = NSAppearance(named: .aqua)
        case .none:        material = .sidebar;    appearance = nil
        }

        return ResolvedTheme(
            palette: palette,
            material: material,
            nsAppearance: appearance,
            searchFont: .system(size: base + 5, design: font.design),
            titleFont: .system(size: base, design: font.design),
            subtitleFont: .system(size: max(9, base - 2), design: font.design),
            captionFont: .system(size: max(9, base - 2), design: font.design)
        )
    }
}

extension Color {
    init(hex: UInt) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}
