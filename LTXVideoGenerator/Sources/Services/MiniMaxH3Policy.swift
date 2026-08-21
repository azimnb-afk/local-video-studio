import Foundation

/// Capabilities proven for the exact H3 FL2VA mlx-serve pack. Keeping these
/// distinct from generic model flags prevents unsupported REF2VA or motion
/// context controls from leaking into its request contract.
struct MiniMaxH3Capabilities: Equatable {
    var textToVideo = true
    var imageToVideo = true
    var nativeAudio = true
    var lastFrameContinuation = true
    var chainWindows = true
    var referenceVideos = false
    var motionContext = false
    var contextLoop = false
}

enum MiniMaxH3ImageGroundingContext: Equatable {
    case normalGenerate
    case oneShot
    case autoMovie
}

struct MiniMaxH3ImageGroundingRecommendation: Equatable {
    let title: String
    let english: String
    let japanese: String
}

/// User-facing policy derived from the frozen H3 acceptance evidence. This is
/// deliberately presentation-only: it neither mutates GenerationRequest nor
/// changes whether a text-only request can be submitted.
enum MiniMaxH3ProductPolicy {
    static let isExperimental = true
    static let modelDescription =
        "Experimental. Best results with a starting image. Text-only generation may be less consistent. Continued shots can use the previous final frame; longer sequences may gradually drift."
    static let modelDescriptionJapanese =
        "実験的機能です。開始画像を使うとより良い結果が期待できます。テキストだけの生成は一貫性が低くなる場合があり、長い連続シーンでは徐々に見た目が変化することがあります。"

    static func recommendation(
        modelID: String,
        context: MiniMaxH3ImageGroundingContext,
        hasImage: Bool
    ) -> MiniMaxH3ImageGroundingRecommendation? {
        guard modelID == MiniMaxH3Configuration.modelID, !hasImage else { return nil }
        switch context {
        case .normalGenerate, .oneShot:
            return MiniMaxH3ImageGroundingRecommendation(
                title: "Recommended for H3",
                english: "Add a Starting Image for better subject consistency. Text-only generation remains available.",
                japanese: "被写体の一貫性を高めるには開始画像の追加を推奨します。画像なしでも生成できます。")
        case .autoMovie:
            return MiniMaxH3ImageGroundingRecommendation(
                title: "Recommended for H3",
                english: "Add an Opening Reference for better character or subject consistency. Text-only generation remains available.",
                japanese: "人物や被写体の一貫性を高めるにはOpening Referenceの追加を推奨します。画像なしでも生成できます。")
        }
    }
}

struct MiniMaxH3FramePlan: Equatable, Codable {
    let requestedDurationSeconds: Double
    /// Frames requested per runtime window. Chained requests use the proven
    /// 39-frame base window; the response frame count remains authoritative.
    let windowFrames: Int
    let chainWindows: Int
    let expectedTotalFrames: Int
    let fps: Int

    var expectedDurationSeconds: Double {
        Double(expectedTotalFrames) / Double(fps)
    }

    var hasElevatedDriftRisk: Bool { chainWindows >= 5 }
}

enum MiniMaxH3DurationPolicy {
    static let fps = 24
    static let singleWindowFrames = [22, 39, 56, 73]
    static let chainedWindowFrames = 39
    static let maximumChainWindows = 6
    static let maximumExpectedFrames = 39 + (maximumChainWindows - 1) * 38
    static let maximumDurationSeconds = Double(maximumExpectedFrames) / Double(fps)

    static func plan(requestedDurationSeconds: Double) throws -> MiniMaxH3FramePlan {
        guard requestedDurationSeconds > 0,
              requestedDurationSeconds <= maximumDurationSeconds + 0.000_001 else {
            throw MiniMaxH3Error.unsupportedCapability(
                "shot durations above the proven \(String(format: "%.2f", maximumDurationSeconds))-second chain limit")
        }

        var candidates = singleWindowFrames.map { frames in
            MiniMaxH3FramePlan(
                requestedDurationSeconds: requestedDurationSeconds,
                windowFrames: frames,
                chainWindows: 1,
                expectedTotalFrames: frames,
                fps: fps)
        }
        candidates.append(contentsOf: (2...maximumChainWindows).map { chain in
            MiniMaxH3FramePlan(
                requestedDurationSeconds: requestedDurationSeconds,
                windowFrames: chainedWindowFrames,
                chainWindows: chain,
                expectedTotalFrames: chainedWindowFrames + (chain - 1) * 38,
                fps: fps)
        })
        return candidates.min { lhs, rhs in
            let leftDistance = abs(lhs.expectedDurationSeconds - requestedDurationSeconds)
            let rightDistance = abs(rhs.expectedDurationSeconds - requestedDurationSeconds)
            if leftDistance == rightDistance { return lhs.chainWindows < rhs.chainWindows }
            return leftDistance < rightDistance
        }!
    }

    /// H3 MVP has one directly proven canvas/sampler. This resolver records
    /// the user's duration intent separately while freezing exactly what the
    /// backend will execute.
    static func applying(to request: GenerationRequest) throws -> GenerationRequest {
        let requestedDuration = request.minimaxH3RequestedDurationSeconds
            ?? request.targetDurationSeconds
            ?? request.requestedDurationSeconds
        let framePlan = try plan(requestedDurationSeconds: requestedDuration)
        var resolved = request
        resolved.parameters.width = 512
        resolved.parameters.height = 288
        resolved.parameters.fps = fps
        resolved.parameters.numInferenceSteps = 8
        resolved.parameters.numFrames = framePlan.windowFrames
        resolved.minimaxH3ChainWindows = framePlan.chainWindows
        resolved.minimaxH3ExpectedFrames = framePlan.expectedTotalFrames
        resolved.minimaxH3RequestedDurationSeconds = requestedDuration
        return resolved
    }
}

/// Truthful UI policy for the long-running, single-response H3 HTTP request.
/// mlx-serve does not currently expose supported intermediate percentages to
/// the app, so the sampling phase must stay indeterminate rather than pinning a
/// determinate bar at the backend's initial 3% phase marker.
enum MiniMaxH3ProgressPresentation {
    static let requestTimeoutSeconds: TimeInterval = 3_600

    static func isIndeterminate(
        modelID: String,
        isCurrent: Bool,
        progress: Double
    ) -> Bool {
        modelID == MiniMaxH3Configuration.modelID
            && isCurrent
            && progress < 0.94
    }

    static func generatingMessage(for request: GenerationRequest) -> String {
        let chain = max(1, request.minimaxH3ChainWindows ?? 1)
        let frames = request.minimaxH3ExpectedFrames ?? request.parameters.numFrames
        let fps = max(1, request.parameters.fps)
        let seconds = Double(frames) / Double(fps)
        return "Generating with MiniMax H3… · \(request.parameters.width)×\(request.parameters.height) · chain \(chain) · \(durationText(seconds)) output · \(request.parameters.numInferenceSteps) steps · long local generation"
    }

    static func elapsedText(since startedAt: Date, now: Date = Date()) -> String {
        let totalSeconds = max(0, Int(now.timeIntervalSince(startedAt)))
        return String(format: "Elapsed %02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    private static func durationText(_ seconds: Double) -> String {
        String(format: seconds.rounded() == seconds ? "%.0f s" : "%.1f s", seconds)
    }
}

/// Renderer-specific wording over the existing neutral OneShotPlan. Planning,
/// continuity and CharacterBible resolution remain shared with LTX.
enum MiniMaxH3PromptCompiler {
    static func compile(
        plan: OneShotPlan,
        isImageToVideo: Bool,
        japaneseHandling: JapaneseDialogueHandling = .native,
        perShotAudioPolicy: PerShotAudioPolicy = .unspecified
    ) -> String {
        var sentences: [String] = []
        let action = perShotAudioPolicy.filteredAction(plan.action).h3Trimmed
        if !action.isEmpty { sentences.append(terminated(action)) }

        if let acting = plan.acting?.h3Trimmed, !acting.isEmpty {
            sentences.append(terminated(acting))
        }
        if let motion = plan.motion?.h3Trimmed, !motion.isEmpty {
            sentences.append(terminated("The movement is \(motion)"))
        }

        let camera = plan.camera.h3Trimmed
        if !camera.isEmpty {
            let lower = camera.lowercased()
            let sentence = lower.hasPrefix("camera") || lower.hasPrefix("the camera")
                ? camera
                : "The camera uses \(camera)"
            sentences.append(terminated(sentence))
        }
        if let endState = plan.endState?.h3Trimmed, !endState.isEmpty {
            sentences.append(terminated("By the end of the shot, \(endState)"))
        }
        if let lighting = plan.lighting?.h3Trimmed, !lighting.isEmpty {
            sentences.append(terminated("Lighting remains \(lighting)"))
        }
        if isImageToVideo {
            sentences.append("The subject's face, clothing, hairstyle, background, and lighting remain consistent throughout the shot.")
        }
        for line in DialogueNormalizer.normalize(plan.dialogue, handling: japaneseHandling) {
            sentences.append(terminated(DialogueNormalizer.render(line, handling: japaneseHandling)))
        }
        let cues = perShotAudioPolicy.filteredAudioCues(plan.audioCues)
        if !cues.isEmpty { sentences.append("Audio: \(cues.joined(separator: ", ")).") }
        return perShotAudioPolicy.applyingPromptGuard(to: sentences.joined(separator: " "))
    }

    /// Direct Generate has no structured plan. Preserve all user context and
    /// add only the missing structural contracts needed by this renderer.
    static func compile(rendererNeutralPrompt prompt: String, isImageToVideo: Bool) -> String {
        var result = prompt.h3Trimmed
        guard !result.isEmpty else { return result }
        result = terminated(result)
        let lower = result.lowercased()
        if !containsCameraDirection(lower) {
            result += " The camera movement remains smooth and consistent with the described shot."
        }
        if isImageToVideo && !containsAppearancePreservation(lower) {
            result += " The subject's face, clothing, hairstyle, background, and lighting remain consistent throughout the shot."
        }
        return result
    }

    private static func containsCameraDirection(_ lowercased: String) -> Bool {
        ["camera", "dolly", "pan ", "pans", "tilt", "zoom", "tracking shot", "static shot"]
            .contains { lowercased.contains($0) }
    }

    private static func containsAppearancePreservation(_ lowercased: String) -> Bool {
        ["remain consistent", "remains consistent", "appearance remains", "unchanged appearance"]
            .contains { lowercased.contains($0) }
    }

    private static func terminated(_ text: String) -> String {
        let clean = text.h3Trimmed
        guard let last = clean.last else { return clean }
        return ".!?。！？\"".contains(last) ? clean : clean + "."
    }
}

private extension String {
    var h3Trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
