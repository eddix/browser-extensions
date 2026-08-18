import SwiftUI

/// Preset color schemes. Add more here — each one shows up in Settings.
///
/// `secondary` carries a constraint that isn't obvious from looking at it.
/// These palettes come from editor themes, where the de-emphasized color is a
/// *comment* color chosen against one solid background. Here it lands on two:
/// the frosted background, and the selection wash painted over that background
/// for the current row. The wash *lightens*, so a comment color that reads fine
/// on the glass can vanish on a selected row — measured, Dracula's original
/// `#6272A4` came out at 1.8:1 there, and every one of the nine failed.
///
/// So each `secondary` here is brightened until it clears 4.5:1 against **both**
/// backgrounds — and against the *worst* of them, since the frosted background
/// samples whatever is behind the window and therefore moves. Measured across
/// that range, values tuned to the middle fell to ~3.4:1 whenever the panel
/// happened to sit over something pale.
///
/// `selection` is deliberately fainter than a selection wash usually is, for
/// the same reason: it lightens, and every point of alpha it gains is taken
/// out of the text on top of it. Tuning both together instead of only the text
/// kept the secondary from having to brighten so far that it stopped reading
/// as secondary at all — Gruvbox's would have ended up within 10% of the body
/// color. Visibility of the selected row is carried by an accent stroke, which
/// costs the text nothing.
///
/// `tools/contrast.py` recomputes all of it; run it when adding a palette.
enum Palettes {
    static let system = Palette(
        id: "system", name: "跟随系统", isDark: nil, tint: nil, tintOpacity: 0,
        foreground: .primary, secondary: .secondary, accent: .accentColor,
        selection: Color.primary.opacity(0.10), highlight: .accentColor
    )
    static let light = Palette(
        id: "light", name: "浅色", isDark: false,
        tint: Color(hex: 0xFFFFFF), tintOpacity: 0.50,
        foreground: Color(hex: 0x1D1D1F), secondary: Color(hex: 0x5C5C60),
        accent: Color(hex: 0x0072EE), selection: Color(hex: 0x007AFF).opacity(0.16),
        highlight: Color(hex: 0x0072EE)
    )
    static let nord = Palette(
        id: "nord", name: "Nord", isDark: true,
        tint: Color(hex: 0x2E3440), tintOpacity: 0.55,
        foreground: Color(hex: 0xECEFF4), secondary: Color(hex: 0xB7C8DB),
        accent: Color(hex: 0x88C0D0), selection: Color(hex: 0x88C0D0).opacity(0.10),
        highlight: Color(hex: 0xEBCB8B)
    )
    static let dracula = Palette(
        id: "dracula", name: "Dracula", isDark: true,
        tint: Color(hex: 0x282A36), tintOpacity: 0.55,
        foreground: Color(hex: 0xF8F8F2), secondary: Color(hex: 0xC3C9D7),
        accent: Color(hex: 0xBD93F9), selection: Color(hex: 0xBD93F9).opacity(0.18),
        highlight: Color(hex: 0xF1FA8C)
    )
    /// Moved up one step through Solarized's own ramp, because the original
    /// assignment had no room to work here. Body text was base1 (`#93A1A1`),
    /// which manages only 5.7:1 on this background — leaving nowhere to put a
    /// *dimmer* secondary above 4.5:1. Secondary was base01, which Solarized
    /// itself defines as a comment color and measures 2.8:1. Now base2 for body
    /// and base1 for secondary, both still straight from the palette, and the
    /// selection wash is lighter than the others' because `#268BD2` is a bright
    /// blue that lifts the background more than any other accent here.
    static let solarized = Palette(
        id: "solarizedDark", name: "Solarized Dark", isDark: true,
        tint: Color(hex: 0x002B36), tintOpacity: 0.55,
        foreground: Color(hex: 0xEEE8D5), secondary: Color(hex: 0xB4BCB5),
        accent: Color(hex: 0x4DA0DA), selection: Color(hex: 0x268BD2).opacity(0.16),
        highlight: Color(hex: 0xBC9316)
    )
    static let rosePine = Palette(
        id: "rosePine", name: "Rosé Pine", isDark: true,
        tint: Color(hex: 0x191724), tintOpacity: 0.55,
        foreground: Color(hex: 0xE0DEF4), secondary: Color(hex: 0xB6B3CC),
        accent: Color(hex: 0xC4A7E7), selection: Color(hex: 0xC4A7E7).opacity(0.12),
        highlight: Color(hex: 0xF6C177)
    )
    static let gruvbox = Palette(
        id: "gruvbox", name: "Gruvbox", isDark: true,
        tint: Color(hex: 0x282828), tintOpacity: 0.55,
        foreground: Color(hex: 0xEBDBB2), secondary: Color(hex: 0xC7B89D),
        accent: Color(hex: 0x83A598), selection: Color(hex: 0x83A598).opacity(0.10),
        highlight: Color(hex: 0xFABD2F)
    )

    // Deep navy with a butter-yellow focus.
    static let midnightButter = Palette(
        id: "midnightButter", name: "午夜黄油", isDark: true,
        tint: Color(hex: 0x0D1520), tintOpacity: 0.62,
        foreground: Color(hex: 0xF5F7FA), secondary: Color(hex: 0xC0C9D2),
        accent: Color(hex: 0xF4E4C1), selection: Color(hex: 0xF4E4C1).opacity(0.19),
        highlight: Color(hex: 0xF4E4C1)
    )
    // Charcoal with a retro-red accent.
    static let charcoalRed = Palette(
        id: "charcoalRed", name: "炭黑复古红", isDark: true,
        tint: Color(hex: 0x121214), tintOpacity: 0.62,
        foreground: Color(hex: 0xFFFFFF), secondary: Color(hex: 0xACACAF),
        accent: Color(hex: 0xFF4949), selection: Color(hex: 0xFF4545).opacity(0.22),
        highlight: Color(hex: 0xFF4949)
    )
    // Ink-green with sand-gold highlights.
    static let inkGreen = Palette(
        id: "inkGreen", name: "墨绿沙金", isDark: true,
        tint: Color(hex: 0x111613), tintOpacity: 0.62,
        foreground: Color(hex: 0xECF0ED), secondary: Color(hex: 0xBDC5C0),
        accent: Color(hex: 0xD4B996), selection: Color(hex: 0xD4B996).opacity(0.22),
        highlight: Color(hex: 0xD4B996)
    )

    static let all: [Palette] = [
        system, light, nord, dracula, solarized, rosePine, gruvbox,
        midnightButter, charcoalRed, inkGreen,
    ]
    static let byID: [String: Palette] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
}
