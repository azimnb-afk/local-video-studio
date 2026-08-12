import Foundation

/// Deterministic Text Protocol → `StoryboardDraft` parser.
///
/// No second model is involved: the text is converted by fixed rules and then
/// handed to exactly the same semantic repair and validator the Structured
/// JSON path uses, so a Text Protocol plan is held to the same standard.
///
/// The parser anchors strictly on the protocol's markers and ignores anything
/// outside them. That is not free-form prose interpretation: models that need
/// this protocol were observed emitting reasoning and even an echo of the
/// blank template before the real answer, so anchoring is what makes the
/// result deterministic. A block whose values are still the `<...>`
/// placeholders is rejected rather than turned into a plan.
enum TextProtocolPlanParser {

    private static let placeholderPrefix = "<"
    private static let placeholderSuffix = ">"

    static func parse(_ response: String, brief: String) -> StoryboardDirector.ParseResult {
        let text = normalize(response)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .init(draft: nil, failureStage: .jsonExtractionFailed,
                         message: "empty response", deterministicRepairAttempted: false)
        }

        let lines = text.components(separatedBy: "\n")
        var anchors = lines.indices.filter { isKeyLine(lines[$0], key: "LOGLINE") }
        if anchors.isEmpty {
            // A reply that omits the logline but still lays out shots is a
            // usable plan: the brief stands in for the logline exactly as the
            // Structured path's semantic repair already does. Prose cannot
            // reach this point, because a shot is only accepted with an
            // ACTION line.
            anchors = lines.indices.filter { isShotMarker(lines[$0]) }.prefix(1).map { $0 }
        }
        guard !anchors.isEmpty else {
            return .init(draft: nil, failureStage: .jsonExtractionFailed,
                         message: "no LOGLINE or SHOT markers found in response",
                         deterministicRepairAttempted: false)
        }

        // Try each anchor in order and accept the first that yields a usable
        // plan. A template echo fails naturally because its values are
        // placeholders, so no special case is needed for it.
        var lastMessage = "no usable shots after LOGLINE"
        for anchor in anchors {
            switch parseBlock(lines: Array(lines[anchor...]), brief: brief) {
            case .success(let draft):
                return .init(draft: draft, failureStage: nil, message: "",
                             deterministicRepairAttempted: false)
            case .failure(let message):
                lastMessage = message
            }
        }
        return .init(draft: nil, failureStage: .schemaValidationFailed,
                     message: lastMessage, deterministicRepairAttempted: false)
    }

    private enum BlockResult {
        case success(StoryboardDirector.StoryboardDraft)
        case failure(String)
    }

    private static func parseBlock(lines: [String], brief: String) -> BlockResult {
        var logline = ""
        var shots: [StoryboardDirector.ShotPlanDraft] = []

        var currentTitle: String?
        var currentAction: String?
        var currentCamera: String?
        var currentContinuity: String?
        var sawShotMarker = false

        func flushShot() {
            defer {
                currentTitle = nil; currentAction = nil
                currentCamera = nil; currentContinuity = nil
            }
            guard let action = currentAction, isMeaningful(action) else { return }
            let camera = currentCamera.flatMap { isMeaningful($0) ? $0 : nil }
            var shot = StoryboardDirector.ShotPlanDraft(
                title: currentTitle.flatMap { isMeaningful($0) ? $0 : nil } ?? "Shot \(shots.count + 1)",
                summary: action
            )
            if let camera {
                shot.movement = camera
                shot.shotScale = detectedShotScale(in: camera)
            }
            shot.continuity = normalizedContinuity(currentContinuity)
            shots.append(shot)
        }

        for line in lines {
            if let value = keyValue(line, key: "LOGLINE") {
                // A second LOGLINE ends this block rather than silently
                // merging two different plans together.
                if !logline.isEmpty { break }
                logline = value
            } else if isShotMarker(line) {
                flushShot()
                sawShotMarker = true
            } else if let value = keyValue(line, key: "TITLE") {
                currentTitle = value
            } else if let value = keyValue(line, key: "ACTION") {
                currentAction = value
            } else if let value = keyValue(line, key: "CAMERA") {
                currentCamera = value
            } else if let value = keyValue(line, key: "CONTINUITY") {
                currentContinuity = value
            }
        }
        flushShot()

        guard sawShotMarker else { return .failure("no SHOT markers found") }
        guard !shots.isEmpty else { return .failure("no shot contained a usable ACTION line") }

        if !isMeaningful(logline) {
            // The brief is a truthful stand-in; semantic repair does the same
            // for the Structured path rather than inventing a logline.
            logline = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !logline.isEmpty else { return .failure("logline missing and no brief to fall back on") }

        return .success(StoryboardDirector.StoryboardDraft(logline: logline, shots: shots))
    }

    // MARK: - Line helpers

    /// Normalizes line endings and removes reasoning blocks some models emit
    /// inline before their answer.
    static func normalize(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        while let start = text.range(of: "<think>"),
              let end = text.range(of: "</think>", range: start.upperBound..<text.endIndex) {
            text.removeSubrange(start.lowerBound..<end.upperBound)
        }
        return text
    }

    /// `KEY: value`, case-insensitive, tolerating leading whitespace and
    /// common list/emphasis decoration such as `- ` or `**KEY:**`.
    static func keyValue(_ line: String, key: String) -> String? {
        let stripped = strippingDecoration(line)
        guard stripped.count > key.count else { return nil }
        let prefix = stripped.prefix(key.count)
        guard prefix.lowercased() == key.lowercased() else { return nil }
        let rest = stripped.dropFirst(key.count).drop(while: { $0 == "*" || $0 == " " })
        guard rest.first == ":" else { return nil }
        return rest.dropFirst().trimmingCharacters(in: .whitespaces)
    }

    private static func isKeyLine(_ line: String, key: String) -> Bool {
        keyValue(line, key: key) != nil
    }

    /// `SHOT 1` / `shot 2` / `**SHOT 3**`, with nothing else on the line.
    static func isShotMarker(_ line: String) -> Bool {
        let stripped = strippingDecoration(line)
            .trimmingCharacters(in: CharacterSet(charactersIn: "*: "))
        let parts = stripped.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0].lowercased() == "shot" else { return false }
        return Int(parts[1]) != nil
    }

    private static func strippingDecoration(_ line: String) -> String {
        var value = line.trimmingCharacters(in: .whitespaces)
        while value.hasPrefix("-") || value.hasPrefix("*") || value.hasPrefix("#") {
            value = String(value.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        return value
    }

    /// Rejects empty values and unfilled `<...>` template placeholders.
    static func isMeaningful(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasPrefix(placeholderPrefix) && trimmed.hasSuffix(placeholderSuffix) { return false }
        return true
    }

    /// CUT/CONTINUE in any casing; anything else becomes nil so the existing
    /// conservative "unknown resolves to a cut" rule applies unchanged.
    static func normalizedContinuity(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: CharacterSet(charactersIn: " .*_")).lowercased()
        if value.hasPrefix("continue") { return "continue" }
        if value.hasPrefix("cut") { return "cut" }
        return nil
    }

    private static let shotScaleKeywords: [(needle: String, scale: String)] = [
        ("extreme close", "extreme-close-up"),
        ("extreme wide", "extreme-wide"),
        ("close-up", "close-up"),
        ("close up", "close-up"),
        ("medium wide", "medium-wide"),
        ("medium close", "medium-close-up"),
        ("medium", "medium"),
        ("wide", "wide"),
        ("long shot", "wide"),
    ]

    /// Fixed keyword lookup, not inference: used only to fill the optional
    /// `shotScale` when the camera line names a standard scale.
    static func detectedShotScale(in camera: String) -> String? {
        let value = camera.lowercased()
        return shotScaleKeywords.first { value.contains($0.needle) }?.scale
    }
}
