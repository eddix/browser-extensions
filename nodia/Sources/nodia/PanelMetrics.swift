import CoreGraphics

/// The numbers the panel's two halves have to agree on.
///
/// The shell is AppKit — an `NSPanel` whose content is wrapped in glass — and
/// what goes inside it is SwiftUI, which sizes and rounds itself. Nothing checks
/// that the two agree, and when they don't there is no error: the content just
/// sits wrong inside the glass, or the corners get clipped to one radius and
/// drawn at another, and you're left guessing which of the two numbers is the
/// one you meant to change.
enum PanelMetrics {
    static let size = CGSize(width: 640, height: 460)
    static let cornerRadius: CGFloat = 16
}
