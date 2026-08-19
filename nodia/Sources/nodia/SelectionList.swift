import SwiftUI

/// The scrolling list every mode is built out of: rows the keyboard walks from
/// somewhere else.
///
/// Selection lives in the model because the panel controller's key monitor owns
/// ↑↓, not the list — so all this has to do is follow it. That is five lines of
/// SwiftUI, which is exactly why there were five copies of it, and copies drift:
/// one had lost the `contentShape` that makes the empty right-hand half of a row
/// clickable, so in that mode clicking a row's blank space did nothing at all.
/// Whatever is easy to leave out belongs in here.
struct SelectionList<Content: View>: View {
    /// The scroll key of each selectable position, in the order the keyboard
    /// steps through them — which is not the order of what's drawn. By-domain
    /// puts a header above each group, and the keyboard never lands on one.
    let targets: [String]

    /// Optional because "nothing selected" is a real state in the parameter
    /// form: it's what typing leaves behind, and it must not scroll — yanking
    /// the list back to the top mid-keystroke is motion nobody asked for.
    let selected: Int?

    /// The form's candidate list is the one that differs: it already sits under
    /// a caption with a gap of its own, so a top inset here would double it.
    var insets = EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)

    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    content()
                }
                .padding(insets)
            }
            .onChange(of: selected) { _, index in
                guard let index, targets.indices.contains(index) else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(targets[index], anchor: .center)
                }
            }
        }
    }
}

extension View {
    /// A row the scroller can find and the mouse can hit.
    ///
    /// `id` is spelled out at every call site rather than left to `ForEach`,
    /// because the two are not always the same key: by-domain walks headers and
    /// tabs together under prefixed ids while `targets` holds bare tab ids, and
    /// `scrollTo` reports a key it can't find by doing nothing. The identity is
    /// never the row's position — filtering a six-row list down to one once left
    /// the old first row on screen, because SwiftUI had been told "row 0" was
    /// the same view either way.
    func selectableRow(id: String, onTap: @escaping () -> Void) -> some View {
        self
            .id(id)
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
    }
}

/// What a list shows when it has nothing to show.
struct EmptyState: View {
    let icon: String
    let message: String
    /// A second line, for when the reason the list is empty comes with
    /// something you could do about it.
    var hint: String?
    /// Smaller inside the parameter form, where the fields above are the
    /// subject and a full-size glyph would outweigh them.
    var iconSize: CGFloat = 28
    let theme: ResolvedTheme

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: iconSize))
                .foregroundStyle(theme.palette.secondary)
            Text(message)
                .font(theme.subtitleFont)
                .foregroundStyle(theme.palette.secondary)
            if let hint {
                Text(hint)
                    .font(theme.captionFont)
                    .foregroundStyle(theme.palette.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
