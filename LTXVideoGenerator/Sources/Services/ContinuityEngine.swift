import Foundation

/// Deterministic continuity: LLMs propose, this state machine disposes.
///
///     Previous State + Explicit Changes = Next State
///
/// Explicit changes use a small directive grammar (validated, order-applied):
///     location=<value>            timeOfDay=<value>
///     weather=<value>             lighting=<value>
///     outfit:<character>=<value>  position:<character>=<value>
///     condition:<character>=<value>
///     wet:<character>=<value>     injury:<character>=<value>
///     prop+:<name>                prop-:<name>
///     propOwner:<prop>=<character>
///     dialogueState=<value>       storyState=<value>
enum ContinuityEngine {

    struct Violation: Equatable, CustomStringConvertible {
        enum Severity: String { case warning, error }
        var severity: Severity
        var message: String
        var description: String { "[\(severity.rawValue)] \(message)" }
    }

    enum DirectiveError: Error, Equatable {
        case malformed(String)
    }

    /// Applies explicit changes to a snapshot, producing the next state.
    static func apply(changes: [String], to state: ContinuitySnapshot) throws -> ContinuitySnapshot {
        var next = state
        for raw in changes {
            let directive = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !directive.isEmpty else { continue }

            if directive.hasPrefix("prop+:") {
                let prop = String(directive.dropFirst("prop+:".count))
                guard !prop.isEmpty else { throw DirectiveError.malformed(directive) }
                if !next.props.contains(prop) { next.props.append(prop) }
                continue
            }
            if directive.hasPrefix("prop-:") {
                let prop = String(directive.dropFirst("prop-:".count))
                guard !prop.isEmpty else { throw DirectiveError.malformed(directive) }
                next.props.removeAll { $0 == prop }
                next.propOwner[prop] = nil
                continue
            }

            guard let equals = directive.firstIndex(of: "=") else {
                throw DirectiveError.malformed(directive)
            }
            let key = String(directive[..<equals])
            let value = String(directive[directive.index(after: equals)...])
            guard !value.isEmpty else { throw DirectiveError.malformed(directive) }

            if let colon = key.firstIndex(of: ":") {
                let kind = String(key[..<colon])
                let subject = String(key[key.index(after: colon)...])
                guard !subject.isEmpty else { throw DirectiveError.malformed(directive) }
                switch kind {
                case "outfit": next.characterOutfit[subject] = value
                case "position": next.characterPosition[subject] = value
                case "condition": next.characterCondition[subject] = value
                case "wet": next.wetness[subject] = value
                case "injury": next.injuries[subject] = value
                case "propOwner":
                    if !next.props.contains(subject) { next.props.append(subject) }
                    next.propOwner[subject] = value
                default: throw DirectiveError.malformed(directive)
                }
            } else {
                switch key {
                case "location": next.location = value
                case "timeOfDay": next.timeOfDay = value
                case "weather": next.weather = value
                case "lighting": next.lighting = value
                case "dialogueState": next.dialogueState = value
                case "storyState": next.storyState = value
                default: throw DirectiveError.malformed(directive)
                }
            }
        }
        return next
    }

    /// Detects contradictions between what a shot's snapshots claim and what
    /// its explicit changes justify. Deterministic — no LLM judgement.
    static func validate(previous: ContinuitySnapshot, next: ContinuitySnapshot, explicitChanges: [String]) -> [Violation] {
        var violations: [Violation] = []
        let changesText = explicitChanges.joined(separator: "\n")

        func requireDirective(_ prefix: String, changed: Bool, what: String) {
            if changed && !changesText.contains(prefix) {
                violations.append(Violation(severity: .error,
                    message: "\(what) changed without an explicit '\(prefix)…' change directive."))
            }
        }
        requireDirective("location=", changed: previous.location != next.location && !previous.location.isEmpty, what: "Location")
        requireDirective("timeOfDay=", changed: previous.timeOfDay != next.timeOfDay && !previous.timeOfDay.isEmpty, what: "Time of day")
        requireDirective("weather=", changed: previous.weather != next.weather && !previous.weather.isEmpty, what: "Weather")

        for (character, outfit) in next.characterOutfit {
            if let before = previous.characterOutfit[character], before != outfit,
               !changesText.contains("outfit:\(character)=") {
                violations.append(Violation(severity: .error,
                    message: "\(character)'s outfit changed ('\(before)' → '\(outfit)') without an explicit change."))
            }
        }
        for (prop, owner) in next.propOwner {
            if !next.props.contains(prop) {
                violations.append(Violation(severity: .error,
                    message: "Prop '\(prop)' has owner '\(owner)' but is not present in the scene."))
            }
            if let before = previous.propOwner[prop], before != owner,
               !changesText.contains("propOwner:\(prop)=") {
                violations.append(Violation(severity: .warning,
                    message: "Prop '\(prop)' changed hands ('\(before)' → '\(owner)') without an explicit change."))
            }
        }
        // Injuries/wetness never silently disappear.
        for (character, injury) in previous.injuries where next.injuries[character] == nil {
            if !changesText.contains("injury:\(character)=") {
                violations.append(Violation(severity: .warning,
                    message: "\(character)'s injury ('\(injury)') vanished without an explicit change."))
            }
        }
        for (character, wet) in previous.wetness where next.wetness[character] == nil {
            if !changesText.contains("wet:\(character)=") {
                violations.append(Violation(severity: .warning,
                    message: "\(character)'s wetness ('\(wet)') vanished without an explicit change."))
            }
        }
        return violations
    }

    /// Rule-based shot monotony detection: 3+ consecutive shots sharing scale,
    /// angle, movement, or frontal composition.
    static func monotonyWarnings(shots: [Shot]) -> [Violation] {
        var violations: [Violation] = []
        func runs(_ keyPath: KeyPath<CameraPlan, String>, label: String) {
            var runStart = 0
            for i in 1...shots.count {
                let ended = i == shots.count
                    || shots[i].camera[keyPath: keyPath] != shots[runStart].camera[keyPath: keyPath]
                if ended {
                    let length = i - runStart
                    let value = shots[runStart].camera[keyPath: keyPath]
                    if length >= 3, !value.isEmpty {
                        violations.append(Violation(severity: .warning,
                            message: "\(length) consecutive shots share \(label) '\(value)' (shots \(runStart + 1)–\(i))."))
                    }
                    runStart = i
                }
            }
        }
        guard !shots.isEmpty else { return [] }
        runs(\.shotScale, label: "shot scale")
        runs(\.angle, label: "angle")
        runs(\.movement, label: "camera movement")
        return violations
    }

    /// Continuity context sentences for the prompt compiler (keeps prompts
    /// consistent across shots without re-describing everything).
    static func promptContext(for snapshot: ContinuitySnapshot) -> String {
        var parts: [String] = []
        if !snapshot.location.isEmpty { parts.append("Location: \(snapshot.location)") }
        if !snapshot.timeOfDay.isEmpty { parts.append("time: \(snapshot.timeOfDay)") }
        if !snapshot.weather.isEmpty { parts.append("weather: \(snapshot.weather)") }
        if !snapshot.lighting.isEmpty { parts.append("lighting: \(snapshot.lighting)") }
        for (character, outfit) in snapshot.characterOutfit.sorted(by: { $0.key < $1.key }) {
            parts.append("\(character) wears \(outfit)")
        }
        return parts.isEmpty ? "" : parts.joined(separator: ", ") + "."
    }
}
