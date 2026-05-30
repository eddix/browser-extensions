import SwiftUI
import AppKit

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
