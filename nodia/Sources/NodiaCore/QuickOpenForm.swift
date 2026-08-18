import Foundation

/// The parameter form's state machine: every value at once, one field with the
/// keyboard, and a candidate list under it.
///
/// Pure state — no view, no AppKit — because the rules here have more edges
/// than they look like they do. What you typed and what's displayed have to be
/// tracked separately, the displayed text and the value that goes in the URL
/// are different strings, and moving the highlight has to change the value
/// without changing what the list contains.
public struct QuickOpenForm {

    public let template: QuickOpenTemplate
    private let state: QuickOpenState

    /// Resolved values — complete from the first frame, which is what lets ⏎
    /// mean "open" rather than "next field".
    public private(set) var values: [String: String]
    /// Index of the field with the keyboard.
    public private(set) var focus: Int
    /// Text in the focused field, shown as-is.
    public private(set) var draft: String
    /// What you *typed*, as opposed to what arrowing put there.
    ///
    /// The candidate list narrows on this rather than on `draft`, or it
    /// collapses under its own cursor: arrow onto "VA", the list refilters to
    /// the one row matching "VA", and the next ↓ has nowhere left to go.
    private var filter: String
    /// Highlighted row in the candidate list.
    public private(set) var highlighted: Int = 0

    public init(template: QuickOpenTemplate, state: QuickOpenState) {
        self.template = template
        self.state = state
        self.values = state.prefill(for: template)
        // Land on the first field you'd actually have to type in: everything
        // before it already has an answer, and stopping to admire those is not
        // a step worth making anyone take.
        let blank = Self.firstBlank(template, self.values)
        self.focus = blank ?? 0
        let parameter = template.parameters.indices.contains(self.focus)
            ? template.parameters[self.focus] : ""
        self.draft = Self.display(self.values[parameter] ?? "", of: parameter, in: template)
        self.filter = ""
    }

    // MARK: - Reading

    public var parameters: [String] { template.parameters }
    public var parameter: String {
        parameters.indices.contains(focus) ? parameters[focus] : ""
    }

    /// Text shown in a field: the focused one shows what you're editing, the
    /// rest show the label of what they hold.
    public func text(of parameter: String) -> String {
        parameter == self.parameter
            ? draft
            : Self.display(values[parameter] ?? "", of: parameter, in: template)
    }

    /// The URL as it stands — exactly what opening would use, so a preview of
    /// this can't drift from what actually happens.
    public var url: URL? { template.expand(values) }

    /// First parameter holding nothing. Only free input can be blank; one with
    /// candidates always falls back to its first.
    public var firstBlank: Int? { Self.firstBlank(template, values) }

    public var hasCandidateList: Bool {
        if case .choices = template.kind(of: parameter) { return true }
        return false
    }

    /// Candidates under the focused field. A parameter with a list shows that
    /// list; one without shows what you've recently typed into a parameter of
    /// the same name, which is the closest to a list it can have.
    public var candidates: [Choice] {
        let all: [Choice]
        switch template.kind(of: parameter) {
        case .choices(let list): all = list
        case .input: all = state.recentInputs(for: parameter).map { Choice(label: $0, value: $0) }
        }
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        // Match label *and* value: you might remember either "VA" or the `us`
        // it turns into.
        return all.filter {
            $0.label.lowercased().contains(q) || $0.value.lowercased().contains(q)
        }
    }

    // MARK: - Editing

    /// Typing. The value follows the text immediately, so the URL preview is
    /// never a step behind the field.
    public mutating func type(_ text: String) {
        draft = text
        filter = text
        values[parameter] = Self.resolve(text, of: parameter, in: template)
        highlighted = 0
    }

    /// Takes a candidate into the focused field — the visible text as well as
    /// the value. A list that changes something you can't see is a list you
    /// stop trusting.
    public mutating func take(_ choice: Choice) {
        draft = choice.label
        values[parameter] = choice.value
    }

    /// ↑↓. Moving the highlight *is* choosing: the field and the URL update as
    /// you go, so there's never a question about what ⏎ would open.
    public mutating func moveHighlight(_ delta: Int) {
        let list = candidates
        guard !list.isEmpty else { return }
        highlighted = max(0, min(list.count - 1, highlighted + delta))
        take(list[highlighted])
    }

    /// ⇥ — next field, wrapping. Keeps whatever the highlight was sitting on,
    /// so arrowing to a candidate and tabbing away doesn't discard it.
    public mutating func focusNext() {
        let list = candidates
        if list.indices.contains(highlighted) { take(list[highlighted]) }
        focusField((focus + 1) % max(parameters.count, 1))
    }

    public mutating func focusField(_ index: Int) {
        guard parameters.indices.contains(index) else { return }
        focus = index
        draft = Self.display(values[parameter] ?? "", of: parameter, in: template)
        // A fresh field starts by showing its whole list, not the leftovers of
        // what you typed into the previous one.
        filter = ""
        highlighted = 0
    }

    // MARK: - Value ↔ text

    /// The label a value is shown as. Different strings often enough that
    /// showing the raw value would be its own bug report: a region picker reads
    /// "VA" and expands to `us`.
    static func display(
        _ value: String, of parameter: String, in template: QuickOpenTemplate
    ) -> String {
        template.choices(for: parameter).first { $0.value == value }?.label ?? value
    }

    /// Text → value. A string naming a candidate becomes that candidate's
    /// value; anything else is taken literally, so a namespace or task id that
    /// appears in no list still works.
    static func resolve(
        _ text: String, of parameter: String, in template: QuickOpenTemplate
    ) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let list = template.choices(for: parameter)
        let lowered = trimmed.lowercased()
        if let hit = list.first(where: { $0.label.lowercased() == lowered })
            ?? list.first(where: { $0.value.lowercased() == lowered }) {
            return hit.value
        }
        return trimmed
    }

    private static func firstBlank(
        _ template: QuickOpenTemplate, _ values: [String: String]
    ) -> Int? {
        template.parameters.firstIndex { (values[$0] ?? "").isEmpty }
    }
}
