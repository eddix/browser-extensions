import AppKit

/// The macOS 26 glass.
///
/// A different model from `NSVisualEffectView`, not a newer material for it.
/// That one is a *backdrop*: a rectangle behind your content that blurs and
/// tints whatever is behind the window. This one is a *container* — you hand it
/// a `contentView` and it embeds that content in a shaped piece of glass, which
/// is why the corner radius belongs to the view itself and why a container of
/// them merges neighbours that drift close together.
enum SystemGlass {
    /// Wraps `content` in glass.
    static func wrap(_ content: NSView, cornerRadius: CGFloat) -> NSView {
        let glass = NSGlassEffectView()
        glass.cornerRadius = cornerRadius
        glass.contentView = content
        return glass
    }

    /// The palette's tint, handed to the glass instead of painted over it.
    ///
    /// `strength` has to arrive as the color's alpha, and it has to be well
    /// under 1: glass takes the tint into the material itself, so an opaque
    /// color floods it — measured, the palette color at full alpha produced a
    /// flat slate panel with the refraction and the edge highlights buried
    /// under it, which is the old frosted look reached the long way around.
    static func tint(_ view: NSView, _ color: NSColor?, strength: CGFloat) {
        guard let glass = view as? NSGlassEffectView else { return }
        glass.tintColor = color?.withAlphaComponent(strength)
    }
}
