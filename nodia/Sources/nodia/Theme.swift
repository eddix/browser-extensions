import SwiftUI
import AppKit

/// Persisted user theme: which palette, font family, base size, and how hard
/// the palette pulls on the glass.
struct Theme: Codable, Equatable {
    var paletteID: String
    var fontID: String
    var baseSize: Double
    /// How far the palette's color is allowed to pull the glass toward itself.
    ///
    /// A setting rather than a constant because there is no right answer, only
    /// a trade: thick tint makes the ten palettes easy to tell apart and buries
    /// the glass; thin tint leaves the refraction and the edge highlights doing
    /// the talking and makes half the palettes look like each other.
    var tintStrength: Double

    /// Apple's own samples sit at 0.2–0.3 — `withAlphaComponent(0.3)` for a
    /// static tint, 0.2 for hover — under the guidance that subtle tints keep
    /// the glass aesthetic. Past roughly 0.5 the material stops reading as
    /// glass at all, so that's the far end; the near end stops short of 0
    /// because a tint that faint is indistinguishable from having no palette.
    static let tintStrengthRange: ClosedRange<Double> = 0.15...0.50
    static let defaultTintStrength: Double = 0.30

    static let `default` = Theme(paletteID: "system", fontID: "system", baseSize: 13)

    init(paletteID: String, fontID: String, baseSize: Double,
         tintStrength: Double = Theme.defaultTintStrength) {
        self.paletteID = paletteID
        self.fontID = fontID
        self.baseSize = baseSize
        self.tintStrength = tintStrength
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        paletteID = try c.decodeIfPresent(String.self, forKey: .paletteID) ?? "system"
        fontID = try c.decodeIfPresent(String.self, forKey: .fontID) ?? "system"
        baseSize = try c.decodeIfPresent(Double.self, forKey: .baseSize) ?? 13
        // Deliberately not migrated from the key this replaced. That one held a
        // whole-window alpha, and it lived in 0.85–1.0; carried over as a tint
        // it would arrive as a flood. An archive from before the rename gets
        // the default instead.
        //
        // Clamped for the same reason it always was: a value saved under an
        // older range would otherwise sit outside its own slider, where the
        // knob pins to one end and stops agreeing with the number beside it.
        let saved = try c.decodeIfPresent(Double.self, forKey: .tintStrength)
            ?? Theme.defaultTintStrength
        tintStrength = min(max(saved, Theme.tintStrengthRange.lowerBound),
                           Theme.tintStrengthRange.upperBound)
    }
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
    let tint: Color?          // pulled into the glass; nil = untinted glass
    let foreground: Color
    let secondary: Color
    let accent: Color
    let selection: Color       // selected-row background
    let highlight: Color       // matched characters
}

/// Everything the views need, derived from a `Theme`.
struct ResolvedTheme {
    let palette: Palette
    let tintStrength: Double
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

        // The glass still needs to be told which way to lean: it picks its own
        // brightness from the appearance, and a dark palette's text on light
        // glass is unreadable however the tint is set.
        let appearance: NSAppearance?
        switch palette.isDark {
        case .some(true):  appearance = NSAppearance(named: .darkAqua)
        case .some(false): appearance = NSAppearance(named: .aqua)
        case .none:        appearance = nil
        }

        return ResolvedTheme(
            palette: palette,
            tintStrength: theme.tintStrength,
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
