import SwiftUI

/// Preset color schemes. Add more here — each one shows up in Settings.
enum Palettes {
    static let system = Palette(
        id: "system", name: "跟随系统", isDark: nil, tint: nil, tintOpacity: 0,
        foreground: .primary, secondary: .secondary, accent: .accentColor,
        selection: Color.primary.opacity(0.10), highlight: .accentColor
    )
    static let light = Palette(
        id: "light", name: "浅色", isDark: false,
        tint: Color(hex: 0xFFFFFF), tintOpacity: 0.50,
        foreground: Color(hex: 0x1D1D1F), secondary: Color(hex: 0x6E6E73),
        accent: Color(hex: 0x007AFF), selection: Color(hex: 0x007AFF).opacity(0.16),
        highlight: Color(hex: 0x007AFF)
    )
    static let nord = Palette(
        id: "nord", name: "Nord", isDark: true,
        tint: Color(hex: 0x2E3440), tintOpacity: 0.55,
        foreground: Color(hex: 0xECEFF4), secondary: Color(hex: 0x81A1C1),
        accent: Color(hex: 0x88C0D0), selection: Color(hex: 0x88C0D0).opacity(0.25),
        highlight: Color(hex: 0xEBCB8B)
    )
    static let dracula = Palette(
        id: "dracula", name: "Dracula", isDark: true,
        tint: Color(hex: 0x282A36), tintOpacity: 0.55,
        foreground: Color(hex: 0xF8F8F2), secondary: Color(hex: 0x6272A4),
        accent: Color(hex: 0xBD93F9), selection: Color(hex: 0xBD93F9).opacity(0.30),
        highlight: Color(hex: 0xF1FA8C)
    )
    static let solarized = Palette(
        id: "solarizedDark", name: "Solarized Dark", isDark: true,
        tint: Color(hex: 0x002B36), tintOpacity: 0.55,
        foreground: Color(hex: 0x93A1A1), secondary: Color(hex: 0x586E75),
        accent: Color(hex: 0x268BD2), selection: Color(hex: 0x268BD2).opacity(0.30),
        highlight: Color(hex: 0xB58900)
    )
    static let rosePine = Palette(
        id: "rosePine", name: "Rosé Pine", isDark: true,
        tint: Color(hex: 0x191724), tintOpacity: 0.55,
        foreground: Color(hex: 0xE0DEF4), secondary: Color(hex: 0x908CAA),
        accent: Color(hex: 0xC4A7E7), selection: Color(hex: 0xC4A7E7).opacity(0.25),
        highlight: Color(hex: 0xF6C177)
    )
    static let gruvbox = Palette(
        id: "gruvbox", name: "Gruvbox", isDark: true,
        tint: Color(hex: 0x282828), tintOpacity: 0.55,
        foreground: Color(hex: 0xEBDBB2), secondary: Color(hex: 0xA89984),
        accent: Color(hex: 0x83A598), selection: Color(hex: 0x83A598).opacity(0.30),
        highlight: Color(hex: 0xFABD2F)
    )

    // Deep navy with a butter-yellow focus.
    static let midnightButter = Palette(
        id: "midnightButter", name: "午夜黄油", isDark: true,
        tint: Color(hex: 0x0D1520), tintOpacity: 0.62,
        foreground: Color(hex: 0xF5F7FA), secondary: Color(hex: 0x7A8C9E),
        accent: Color(hex: 0xF4E4C1), selection: Color(hex: 0xF4E4C1).opacity(0.20),
        highlight: Color(hex: 0xF4E4C1)
    )
    // Charcoal with a retro-red accent.
    static let charcoalRed = Palette(
        id: "charcoalRed", name: "炭黑复古红", isDark: true,
        tint: Color(hex: 0x121214), tintOpacity: 0.62,
        foreground: Color(hex: 0xFFFFFF), secondary: Color(hex: 0x62626A),
        accent: Color(hex: 0xFF4545), selection: Color(hex: 0xFF4545).opacity(0.22),
        highlight: Color(hex: 0xFF4545)
    )
    // Ink-green with sand-gold highlights.
    static let inkGreen = Palette(
        id: "inkGreen", name: "墨绿沙金", isDark: true,
        tint: Color(hex: 0x111613), tintOpacity: 0.62,
        foreground: Color(hex: 0xECF0ED), secondary: Color(hex: 0x5E7066),
        accent: Color(hex: 0xD4B996), selection: Color(hex: 0xD4B996).opacity(0.22),
        highlight: Color(hex: 0xD4B996)
    )

    static let all: [Palette] = [
        system, light, nord, dracula, solarized, rosePine, gruvbox,
        midnightButter, charcoalRed, inkGreen,
    ]
    static let byID: [String: Palette] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
}
