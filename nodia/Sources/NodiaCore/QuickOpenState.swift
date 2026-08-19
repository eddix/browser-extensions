import Foundation

/// What using quick open leaves behind: which templates you actually reach for,
/// and what you last put in each parameter.
///
/// This deliberately does *not* live in the vault. The JSON file beside it is
/// configuration you write by hand; this is a byproduct of using the thing, it
/// changes on every single open, and rewriting a hand-formatted config that
/// often is exactly the round-trip risk that picking JSON was meant to avoid.
public final class QuickOpenState {

    /// How fast a template's score fades — applied to *every* score on each
    /// open, so decay is measured in openings rather than wall-clock time.
    ///
    /// That distinction is the whole reason this isn't ordinary frecency: come
    /// back from two weeks off and nothing was opened in the meantime, so the
    /// list is exactly as you left it. Time-based decay would have faded
    /// everything uniformly toward zero, and the first morning back would greet
    /// you with an order that carries no information at all.
    ///
    /// 0.98 halves a score every ~34 openings (`ln 0.5 / ln 0.98`). At a dozen
    /// or so opens a day that's a memory two or three days deep: long enough
    /// for the top few to hold still and be worth learning by position, short
    /// enough that a platform you've stopped using sinks within a fortnight.
    static let decay = 0.98

    /// Below this a score says nothing a missing entry doesn't, and keeping it
    /// only grows the dictionary forever with templates that were renamed or
    /// deleted. Reached ~230 openings after a template's last use.
    static let scoreFloor = 0.01

    /// Free-input history depth. Long enough to cover "the two or three things
    /// I'm working on", short enough to stay a glance rather than a list.
    static let recentLimit = 5

    private enum Key {
        static let scores = "nodia.quickopen.scores"
        static let lastValues = "nodia.quickopen.lastValues"
        static let recentInputs = "nodia.quickopen.recentInputs"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Ranking

    /// Usage score for a template, keyed by name. A renamed template starts
    /// over — which is the honest answer, since nothing connects the two.
    public func score(named name: String) -> Double {
        (defaults.dictionary(forKey: Key.scores) as? [String: Double])?[name] ?? 0
    }

    public func scores() -> [String: Double] {
        (defaults.dictionary(forKey: Key.scores) as? [String: Double]) ?? [:]
    }

    // MARK: - Prefill

    /// The value to start a parameter at.
    ///
    /// Kept per parameter *name*, across templates, because that's where the
    /// value is: having just looked at a namespace's config, its change history
    /// is the next thing you want, and it's the same namespace. The risk is two
    /// templates sharing a name but not a meaning — `region` means one set of
    /// values on one platform and a different set on another — so a remembered
    /// value that isn't among *this* template's candidates is discarded rather
    /// than forced into a URL that can't work.
    public func prefill(
        for template: QuickOpenTemplate, parameter: String, given values: [String: String] = [:]
    ) -> String {
        let remembered = lastValue(for: parameter)
        switch template.kind(of: parameter) {
        case .choices(let list):
            if let remembered, list.contains(where: { $0.value == remembered }) { return remembered }
            return list.first?.value ?? ""
        case .input:
            return remembered ?? ""
        case .varying:
            let list = template.choices(for: parameter, given: values)
            guard let remembered else { return list.first?.value ?? "" }
            if list.contains(where: { $0.value == remembered }) { return remembered }
            // What was remembered is last session's value, which belonged to
            // whichever case was selected then. If the case has changed since,
            // the useful thing to restore is the same row's value now — you
            // were looking at a service, not at a number.
            if let row = template.varyingRow(of: parameter, holding: remembered),
               let hit = list.first(where: { $0.label == row }) {
                return hit.value
            }
            return list.first?.value ?? ""
        }
    }

    /// Every parameter's starting value, ready to open with.
    public func prefill(for template: QuickOpenTemplate) -> [String: String] {
        var values: [String: String] = [:]
        // Independent fields first: a varying one has no candidates at all
        // until the field it depends on has an answer, and URL order — which is
        // what `parameters` follows — does not promise to put them in that
        // order. Only one level of dependency is allowed, so two passes is all
        // it can ever take.
        for parameter in template.parameters {
            guard case .varying = template.kind(of: parameter) else {
                values[parameter] = prefill(for: template, parameter: parameter, given: values)
                continue
            }
        }
        for parameter in template.parameters {
            guard case .varying = template.kind(of: parameter) else { continue }
            values[parameter] = prefill(for: template, parameter: parameter, given: values)
        }
        return values
    }

    public func lastValue(for parameter: String) -> String? {
        (defaults.dictionary(forKey: Key.lastValues) as? [String: String])?[parameter]
    }

    /// Recent free-input values for a parameter, most recent first. These are
    /// the candidate list for a parameter that has no candidate list.
    public func recentInputs(for parameter: String) -> [String] {
        ((defaults.dictionary(forKey: Key.recentInputs) as? [String: [String]])?[parameter]) ?? []
    }

    // MARK: - Recording

    /// One opening: bumps the template, fades everything else, and remembers
    /// what went into each parameter.
    ///
    /// Called when a URL is actually opened — including when that meant
    /// switching to a tab already showing it, which is a use of the template by
    /// any measure — and not when the form is merely opened and abandoned.
    public func recordOpen(template: QuickOpenTemplate, values: [String: String]) {
        var scores = self.scores()
        for (name, value) in scores {
            let faded = value * Self.decay
            if faded < Self.scoreFloor { scores.removeValue(forKey: name) } else { scores[name] = faded }
        }
        scores[template.name, default: 0] += 1
        defaults.set(scores, forKey: Key.scores)

        var last = (defaults.dictionary(forKey: Key.lastValues) as? [String: String]) ?? [:]
        var recent = (defaults.dictionary(forKey: Key.recentInputs) as? [String: [String]]) ?? [:]
        for parameter in template.parameters {
            guard let value = values[parameter], !value.isEmpty else { continue }
            last[parameter] = value
            // Only free input gets a history: for a parameter with candidates
            // the config already *is* the list, and shadowing it with a
            // second, shorter list of the same strings buys nothing.
            guard case .input = template.kind(of: parameter) else { continue }
            var history = recent[parameter] ?? []
            history.removeAll { $0 == value }
            history.insert(value, at: 0)
            recent[parameter] = Array(history.prefix(Self.recentLimit))
        }
        defaults.set(last, forKey: Key.lastValues)
        defaults.set(recent, forKey: Key.recentInputs)
    }
}
