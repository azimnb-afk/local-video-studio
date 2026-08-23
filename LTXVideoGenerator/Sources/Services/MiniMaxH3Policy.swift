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

enum MiniMaxH3Preset: String, Codable, CaseIterable, Identifiable {
    case quick = "quick"
    case standard = "standard"
    case high = "high"
    case custom = "custom"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .quick: return "Quick"
        case .standard: return "Standard"
        case .high: return "High"
        case .custom: return "Custom"
        }
    }

    var summary: String {
        switch self {
        case .quick: return "3 sec · 8 steps · fast preview"
        case .standard: return "Recommended · 4 sec · 10 steps · proven balance"
        case .high: return "4 sec · 12 steps · 384×640 high resolution"
        case .custom: return "Custom duration (1–6s), steps (6–20), and resolution tiers"
        }
    }

    var perShotSafeMaxDurationSeconds: Double {
        switch self {
        case .quick: return 3.0
        case .standard: return 4.0
        case .high: return 4.0
        case .custom: return 4.0
        }
    }

    func effectiveSummary(
        orientation: SourceImageOrientation?,
        isAutoMovie: Bool = false,
        customTier: MiniMaxH3ResolutionTier = .tier1,
        customDurationSeconds: Double = 4.0,
        customSteps: Int = 10
    ) -> String {
        switch self {
        case .quick:
            let dims = MiniMaxH3ResolutionTier.tier1.dimensions(for: orientation)
            let dur = isAutoMovie ? "up to 3 sec/shot" : "3 sec"
            return "\(displayName) · \(dims.width)×\(dims.height) · \(dur) · 8 steps"
        case .standard:
            let dims = MiniMaxH3ResolutionTier.tier1.dimensions(for: orientation)
            let dur = isAutoMovie ? "up to 4 sec/shot" : "4 sec"
            return "\(displayName) · \(dims.width)×\(dims.height) · \(dur) · 10 steps"
        case .high:
            let dims = MiniMaxH3ResolutionTier.tier2.dimensions(for: orientation)
            let dur = isAutoMovie ? "up to 4 sec/shot" : "4 sec"
            return "\(displayName) · \(dims.width)×\(dims.height) · \(dur) · 12 steps"
        case .custom:
            let dims = customTier.dimensions(for: orientation)
            let frames = MiniMaxH3FrameGrid.legalFrames(forRequestedDurationSeconds: customDurationSeconds)
            let durText = isAutoMovie
                ? "up to \(MiniMaxH3FrameGrid.displayDurationText(forFrames: frames))/shot"
                : MiniMaxH3FrameGrid.displayDurationText(forFrames: frames)
            return "\(displayName) · \(dims.width)×\(dims.height) · \(durText) · \(customSteps) steps"
        }
    }
}

enum MiniMaxH3ResolutionTier: String, Codable, CaseIterable, Identifiable {
    case tier1 = "tier1" // 512x288 / 288x512
    case tier2 = "tier2" // 640x384 / 384x640

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .tier1: return "Tier 1 (512×288 / 288×512)"
        case .tier2: return "Tier 2 (640×384 / 384×640)"
        }
    }

    func dimensions(for orientation: SourceImageOrientation?) -> (width: Int, height: Int) {
        if orientation == .portrait {
            switch self {
            case .tier1: return (288, 512)
            case .tier2: return (384, 640)
            }
        } else {
            switch self {
            case .tier1: return (512, 288)
            case .tier2: return (640, 384)
            }
        }
    }
}

enum MiniMaxH3FrameGrid {
    static let fps = 24

    /// Snaps a requested duration in seconds (1.0s to 15.0s) to the nearest legal H3 frame count on the 17k+5 ladder.
    static func legalFrames(forRequestedDurationSeconds seconds: Double) -> Int {
        let clamped = max(0.5, min(15.0, seconds))
        let targetFrames = clamped * Double(fps)
        let k = max(1, Int(round((targetFrames - 5.0) / 17.0)))
        return 17 * k + 5
    }

    static func displayDurationText(forFrames frames: Int) -> String {
        let sec = Double(frames) / Double(fps)
        if frames == 73 { return "3 sec" }
        if frames == 90 { return "4 sec" }
        if frames == 141 { return "6 sec" }
        return String(format: "%.1f sec", sec)
    }

    static func shouldShowLongDurationWarning(durationSeconds: Double) -> Bool {
        durationSeconds >= 5.0
    }

    static func isLegalFrameCount(_ frames: Int) -> Bool {
        guard frames >= 22 else { return false }
        return (frames - 5) % 17 == 0
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

    /// Resolves canonical H3 execution settings driven by the chosen preset (Quick, Standard, High, Custom)
    /// across all workflows (Generate, One Shot, Auto Movie, Storyboard), defaulting to Standard.
    static func applying(to request: GenerationRequest) throws -> GenerationRequest {
        var resolved = request
        let orientation = request.presetResolutionOrientation
            ?? SourceImageOrientationResolver.resolve(path: request.sourceImagePath)

        let effectivePreset: MiniMaxH3Preset = {
            if let presetRaw = request.preset, let preset = MiniMaxH3Preset(rawValue: presetRaw) {
                return preset
            }
            return .standard
        }()

        switch effectivePreset {
        case .quick:
            let dims = MiniMaxH3ResolutionTier.tier1.dimensions(for: orientation)
            resolved.parameters.width = dims.width
            resolved.parameters.height = dims.height
            resolved.parameters.fps = fps
            resolved.parameters.numInferenceSteps = 8
            resolved.parameters.numFrames = 73 // 3.0s display
            resolved.minimaxH3ChainWindows = 1
            resolved.minimaxH3ExpectedFrames = 73
            resolved.minimaxH3RequestedDurationSeconds = 3.0

        case .standard:
            let dims = MiniMaxH3ResolutionTier.tier1.dimensions(for: orientation)
            resolved.parameters.width = dims.width
            resolved.parameters.height = dims.height
            resolved.parameters.fps = fps
            resolved.parameters.numInferenceSteps = 10
            resolved.parameters.numFrames = 90 // 4.0s display (3.75s encoded)
            resolved.minimaxH3ChainWindows = 1
            resolved.minimaxH3ExpectedFrames = 90
            resolved.minimaxH3RequestedDurationSeconds = 4.0

        case .high:
            let dims = MiniMaxH3ResolutionTier.tier2.dimensions(for: orientation)
            resolved.parameters.width = dims.width
            resolved.parameters.height = dims.height
            resolved.parameters.fps = fps
            resolved.parameters.numInferenceSteps = 12
            resolved.parameters.numFrames = 90 // 4.0s display (3.75s encoded)
            resolved.minimaxH3ChainWindows = 1
            resolved.minimaxH3ExpectedFrames = 90
            resolved.minimaxH3RequestedDurationSeconds = 4.0

        case .custom:
            let requestedDuration = request.minimaxH3RequestedDurationSeconds
                ?? request.targetDurationSeconds
                ?? (Double(request.parameters.numFrames) / Double(fps))

            let legalFrames = MiniMaxH3FrameGrid.legalFrames(forRequestedDurationSeconds: requestedDuration)

            let isTier2 = request.parameters.width >= 640 || request.parameters.height >= 640
            let tier: MiniMaxH3ResolutionTier = isTier2 ? .tier2 : .tier1
            let dims = tier.dimensions(for: orientation)

            resolved.parameters.width = dims.width
            resolved.parameters.height = dims.height
            resolved.parameters.fps = fps
            resolved.parameters.numInferenceSteps = max(6, min(20, request.parameters.numInferenceSteps))
            resolved.parameters.numFrames = legalFrames
            resolved.minimaxH3ChainWindows = 1
            resolved.minimaxH3ExpectedFrames = legalFrames
            resolved.minimaxH3RequestedDurationSeconds = requestedDuration
        }

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

// MARK: - MiniMax H3 Duration Solver (Deterministic Optimization)

struct MiniMaxH3DurationSolver {
    static let maximumShots = 12
    static let fps = 24
    static let legalLadder = [22, 39, 56, 73, 90, 107, 124, 141]

    /// Solves for the optimal per-shot legal frame counts on the 17k+5 grid
    /// that minimize abs(sum(frames) - targetDurationSeconds * 24), bounded by
    /// the preset safe maximum and maximum 12 shots.
    static func solve(
        targetDurationSeconds: Double,
        preset: MiniMaxH3Preset,
        customDurationSeconds: Double? = nil
    ) -> [Int]? {
        let targetFrames = Int((targetDurationSeconds * Double(fps)).rounded())
        guard targetFrames > 0 else { return nil }

        let safeMaxSeconds: Double
        if preset == .custom {
            safeMaxSeconds = min(6.0, max(1.0, customDurationSeconds ?? 4.0))
        } else {
            safeMaxSeconds = preset.perShotSafeMaxDurationSeconds
        }
        let safeMaxFrames = MiniMaxH3FrameGrid.legalFrames(forRequestedDurationSeconds: safeMaxSeconds)
        let ladder = legalLadder.filter { $0 <= safeMaxFrames }
        guard !ladder.isEmpty else { return nil }

        let minShots = max(1, Int(ceil(Double(targetFrames) / Double(safeMaxFrames))))
        if minShots > maximumShots {
            // Capacity exceeded: 12 shots cannot represent requested duration within preset cap (fail closed)
            return nil
        }

        let maxShots = min(maximumShots, minShots + 1)

        var bestCombination: [Int]? = nil
        var bestError = Int.max
        var bestCount = Int.max
        var bestSpread = Int.max

        for k in minShots...maxShots {
            var currentComb = [Int](repeating: ladder[0], count: k)

            func search(index: Int, startLadderIdx: Int, currentSum: Int) {
                if index == k {
                    let err = abs(currentSum - targetFrames)
                    let spread = currentComb.last! - currentComb.first!

                    var isBetter = false
                    if err < bestError {
                        isBetter = true
                    } else if err == bestError {
                        if k < bestCount {
                            isBetter = true
                        } else if k == bestCount {
                            if spread < bestSpread {
                                isBetter = true
                            }
                        }
                    }

                    if isBetter {
                        bestError = err
                        bestCount = k
                        bestSpread = spread
                        bestCombination = currentComb
                    }
                    return
                }

                let remaining = k - index
                let minPossible = currentSum + remaining * ladder[startLadderIdx]
                if minPossible - targetFrames > bestError {
                    return
                }

                for lIdx in startLadderIdx..<ladder.count {
                    currentComb[index] = ladder[lIdx]
                    search(index: index + 1, startLadderIdx: lIdx, currentSum: currentSum + ladder[lIdx])
                }
            }

            search(index: 0, startLadderIdx: 0, currentSum: 0)
        }

        // Return descending for intuitive front-weighting if weights are equal
        return bestCombination?.sorted(by: >)
    }
}

// MARK: - Continuity Chain Guidance Policy

enum ContinuityChainPolicy {
    /// Threshold at which consecutive CONTINUE shots trigger a quality guidance warning
    /// (0-indexed: index 0 is first shot/Cut, 1 is 2nd shot, 2 is 3rd shot, 3 is 4th shot).
    static let warningThresholdChainIndex = 3
    static let safeChainLength = "2–3 shots"

    /// Updates `continueChainIndex` on each shot deterministically.
    static func updateContinueChainIndices(shots: inout [Shot]) {
        var currentChain = 0
        for i in shots.indices {
            if i == 0 || shots[i].continuityMode == .cut {
                currentChain = 0
            } else if shots[i].continuityMode == .continueFromPrevious || shots[i].continuityMode == .auto {
                currentChain += 1
            } else {
                currentChain = 0
            }
            shots[i].continueChainIndex = currentChain
        }
    }

    /// True if any shot in the movie reaches the 4+ consecutive CONTINUE chain warning threshold under MiniMax H3.
    static func hasLongContinueChainWarning(shots: [Shot], modelID: String) -> Bool {
        guard modelID == MiniMaxH3Configuration.modelID else { return false }
        return shots.contains { ($0.continueChainIndex ?? 0) >= warningThresholdChainIndex }
    }

    static let longContinueChainWarningJapanese =
        "H3で長いCONTINUE連鎖を使用すると、ショットを重ねるごとに細部や人物の鮮明さが徐々に低下する場合があります。最高品質には2〜3ショットごとのシーン切替を推奨します。"

    static let longContinueChainWarningEnglish =
        "Long H3 CONTINUE chains may gradually lose fine detail or identity sharpness across generations. For best quality, consider a scene break after 2–3 consecutive shots."
}
