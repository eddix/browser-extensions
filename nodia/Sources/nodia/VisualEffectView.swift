import SwiftUI
import AppKit
import NodiaCore

/// SwiftUI wrapper over `NSVisualEffectView` for the frosted-glass background.
/// `behindWindow` blending blurs whatever is behind the floating panel.
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

/// The macOS 26 glass, when it's there.
///
/// A different model from `NSVisualEffectView`, not a newer material for it.
/// That one is a *backdrop*: a rectangle behind your content that blurs and
/// tints whatever is behind the window. This one is a *container* — you hand it
/// a `contentView` and it embeds that content in a shaped piece of glass, which
/// is why the corner radius belongs to the view itself and why a container of
/// them merges neighbours that drift close together.
///
/// Kept behind an availability check rather than raising the deployment target:
/// the app still runs on macOS 14, and there it gets the frosted material as
/// before.
enum SystemGlass {
    static var isAvailable: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    /// Wraps `content` in glass, or returns it unchanged on older systems.
    static func wrap(_ content: NSView, cornerRadius: CGFloat) -> NSView {
        guard #available(macOS 26.0, *) else { return content }
        let glass = NSGlassEffectView()
        glass.cornerRadius = cornerRadius
        glass.contentView = content
        return glass
    }

    /// How far a palette is allowed to pull the glass toward its own color.
    ///
    /// Not `tintOpacity`. That number describes a *layer painted over* the old
    /// material, and it is 0.55–0.62 because that's what it took to color an
    /// effect that had no opinion about color. Glass takes the tint into the
    /// material itself, so the same number arrives as a flood: handing it the
    /// palette color at full alpha produced a flat slate panel with the
    /// refraction and the edge highlights buried under it — visually the old
    /// frosted look, reached the long way around.
    /// 0.3 is where Apple's own samples sit — `withAlphaComponent(0.3)` for a
    /// static tint, 0.2 for hover — under the guidance that "subtle tints work
    /// best for maintaining the glass aesthetic". The value used to be 0.35,
    /// picked by eye.
    static let tintStrength: CGFloat = 0.30

    /// The palette's tint, handed to the glass instead of painted over it.
    static func tint(_ view: NSView, _ color: NSColor?) {
        guard #available(macOS 26.0, *), let glass = view as? NSGlassEffectView else { return }
        glass.tintColor = color?.withAlphaComponent(tintStrength)
    }

}
