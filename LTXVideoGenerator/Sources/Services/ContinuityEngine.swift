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

    struct ResolvedCharacterState: Equatable {
        var id: UUID
        var name: String
        var appearance: CharacterAppearance
        var currentCostume: String
        var accessories: String
        var continuityNotes: String
        var lockedTraits: Set<CharacterTraitLock>
    }

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
    static func validate(
        previous: ContinuitySnapshot,
        next: ContinuitySnapshot,
        explicitChanges: [String],
        bible: CharacterBible? = nil
    ) -> [Violation] {
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
               !hasCharacterDirective("outfit", key: character, text: changesText, bible: bible) {
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
            if !hasCharacterDirective("injury", key: character, text: changesText, bible: bible) {
                violations.append(Violation(severity: .warning,
                    message: "\(character)'s injury ('\(injury)') vanished without an explicit change."))
            }
        }
        for (character, wet) in previous.wetness where next.wetness[character] == nil {
            if !hasCharacterDirective("wet", key: character, text: changesText, bible: bible) {
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
        violations.append(contentsOf: repeatedActionWarnings(shots: shots))
        return violations
    }

    /// Flags consecutive shots that describe the same action.
    ///
    /// A movie whose shots all say "walks toward the building" renders the same
    /// moment repeatedly, which is the failure mode that made Auto Movie feel
    /// static. This is deliberately a small deterministic check rather than a
    /// language model: it compares normalized summaries and their leading verb,
    /// and only warns.
    static func repeatedActionWarnings(shots: [Shot]) -> [Violation] {
        guard shots.count > 1 else { return [] }
        var violations: [Violation] = []
        for index in 1..<shots.count {
            let previous = normalizedAction(shots[index - 1].summary)
            let current = normalizedAction(shots[index].summary)
            guard !previous.isEmpty, !current.isEmpty else { continue }
            if previous == current {
                violations.append(Violation(
                    severity: .warning,
                    message: "Shots \(index) and \(index + 1) describe the same action; each shot should advance to a new visible state."
                ))
            } else if let a = actionVerb(previous), let b = actionVerb(current), a == b {
                violations.append(Violation(
                    severity: .warning,
                    message: "Shots \(index) and \(index + 1) both lead with '\(a)'; consider advancing the beat."
                ))
            }
        }
        return violations
    }

    /// Lowercased, punctuation-light form used only for comparison. A trailing
    /// "beat N of M"-style counter is stripped so a numbered restatement of the
    /// same sentence is still recognised as a repeat.
    static func normalizedAction(_ summary: String) -> String {
        var text = summary.lowercased()
        if let separator = text.range(of: " — ") {
            let tail = text[separator.upperBound...]
            if tail.contains("beat") || tail.contains("shot ") {
                text = String(text[..<separator.lowerBound])
            }
        }
        let allowed = text.map { $0.isLetter || $0.isNumber || $0.isWhitespace ? $0 : " " }
        return String(allowed)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// First verb-ish token, skipping common leading articles and subjects, so
    /// "a woman walks…" and "the same woman walks…" compare as "walks".
    static func actionVerb(_ normalized: String) -> String? {
        let skip: Set<String> = [
            "a", "an", "the", "same", "she", "he", "they", "it", "this", "that",
            "woman", "man", "person", "girl", "boy", "character", "subject",
            "young", "old", "camera",
        ]
        return normalized.split(separator: " ").first { !skip.contains(String($0)) }
            .map(String.init)
    }

    /// Continuity context sentences for the prompt compiler (keeps prompts
    /// consistent across shots without re-describing everything).
    static func promptContext(for snapshot: ContinuitySnapshot, bible: CharacterBible? = nil) -> String {
        var parts: [String] = []
        if !snapshot.location.isEmpty { parts.append("Location: \(snapshot.location)") }
        if !snapshot.timeOfDay.isEmpty { parts.append("time: \(snapshot.timeOfDay)") }
        if !snapshot.weather.isEmpty { parts.append("weather: \(snapshot.weather)") }
        if !snapshot.lighting.isEmpty { parts.append("lighting: \(snapshot.lighting)") }
        for (character, outfit) in snapshot.characterOutfit.sorted(by: { $0.key < $1.key }) {
            if let bible, let id = UUID(uuidString: character), bible.character(id: id) != nil {
                // Assigned Bible characters are compiled separately so an
                // unassigned character never leaks into this Shot prompt.
                continue
            }
            parts.append("\(character) wears \(outfit)")
        }
        return parts.isEmpty ? "" : parts.joined(separator: ", ") + "."
    }

    /// Converts legacy/name-based continuity keys to stable Character IDs.
    /// Unknown/ad-hoc names remain untouched instead of being guessed.
    static func normalizedCharacterReferences(
        in snapshot: ContinuitySnapshot,
        bible: CharacterBible
    ) -> ContinuitySnapshot {
        var normalized = snapshot
        normalized.characterOutfit = normalize(snapshot.characterOutfit, bible: bible)
        normalized.characterPosition = normalize(snapshot.characterPosition, bible: bible)
        normalized.characterCondition = normalize(snapshot.characterCondition, bible: bible)
        normalized.wetness = normalize(snapshot.wetness, bible: bible)
        normalized.injuries = normalize(snapshot.injuries, bible: bible)
        normalized.propOwner = snapshot.propOwner.mapValues { stableKey(for: $0, bible: bible) }
        return normalized
    }

    /// Resolves only the characters assigned to this shot. Explicit/current
    /// continuity values win over CharacterBible defaults.
    static func resolveCharacters(
        ids: [UUID],
        bible: CharacterBible,
        snapshot: ContinuitySnapshot?
    ) -> [ResolvedCharacterState] {
        let state = snapshot.map { normalizedCharacterReferences(in: $0, bible: bible) }
        return ids.compactMap { id in
            guard let character = bible.character(id: id) else { return nil }
            let key = id.uuidString
            return ResolvedCharacterState(
                id: id,
                name: character.name,
                appearance: character.appearance,
                currentCostume: state?.characterOutfit[key] ?? character.defaultCostume,
                accessories: character.accessories,
                continuityNotes: character.continuityNotes,
                lockedTraits: character.lockedTraits
            )
        }
    }

    private static func normalize(_ values: [String: String], bible: CharacterBible) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in values {
            result[stableKey(for: key, bible: bible)] = value
        }
        return result
    }

    private static func stableKey(for value: String, bible: CharacterBible) -> String {
        if let id = UUID(uuidString: value), bible.character(id: id) != nil { return id.uuidString }
        return bible.character(named: value)?.id.uuidString ?? value
    }

    private static func hasCharacterDirective(
        _ kind: String,
        key: String,
        text: String,
        bible: CharacterBible?
    ) -> Bool {
        if text.contains("\(kind):\(key)=") { return true }
        guard let bible, let id = UUID(uuidString: key), let character = bible.character(id: id) else {
            return false
        }
        return character.matchingNames.contains { text.contains("\(kind):\($0)=") }
    }
}
