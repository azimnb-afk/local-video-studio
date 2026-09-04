import Foundation

struct LTXModel: Identifiable, Codable, Hashable {
    let id: String
    let repo: String
    let displayName: String
    let downloadSize: String
    let supportsBuiltInAudio: Bool
    let qualityWarning: String?
    let recommendedStepsLower: Int?
    let recommendedStepsUpper: Int?
    let tips: String?

    var recommendedSteps: ClosedRange<Int>? {
        guard let lo = recommendedStepsLower, let hi = recommendedStepsUpper else { return nil }
        return lo...hi
    }
}

struct LTXTextEncoder: Identifiable, Codable, Hashable {
    let id: String
    let repo: String
    let displayName: String
    let downloadSize: String
    let qualityWarning: String?
    let tips: String?
}

enum LTXModelCatalog {
    static let selectedModelIDKey = "selectedModelID"
    // Prefer the smaller LTX-2.3 Q4 model for new installs; existing user preferences still win.
    static let defaultModelID = "ltx23_distilled_q4"

    static let all: [LTXModel] = [
        LTXModel(
            id: "ltx2_unified",
            repo: "notapalindrome/ltx2-mlx-av",
            displayName: "LTX-2 Unified",
            downloadSize: "~42GB",
            supportsBuiltInAudio: true,
            qualityWarning: nil,
            recommendedStepsLower: 20,
            recommendedStepsUpper: 40,
            tips: nil
        ),
        LTXModel(
            id: "ltx23_unified",
            repo: "notapalindrome/ltx23-mlx-av",
            displayName: "LTX-2.3 Unified (Beta)",
            downloadSize: "~48GB",
            supportsBuiltInAudio: true,
            qualityWarning: nil,
            recommendedStepsLower: 15,
            recommendedStepsUpper: 30,
            tips: "Distilled model — 15-30 steps is optimal. More steps won't improve quality."
        ),
        LTXModel(
            id: "ltx23_distilled_q4",
            repo: "notapalindrome/ltx23-mlx-av-q4",
            displayName: "LTX-2.3 Distilled Q4 (Beta)",
            downloadSize: "~22GB",
            supportsBuiltInAudio: true,
            qualityWarning: "Quantized: lower memory footprint with some quality tradeoffs versus bf16.",
            recommendedStepsLower: 15,
            recommendedStepsUpper: 30,
            tips: "Distilled model — 15-30 steps is optimal. Uses ~30GB RAM vs ~50GB for bf16."
        ),
    ]

    static var defaultModel: LTXModel {
        all.first { $0.id == defaultModelID } ?? all[0]
    }

    static func model(id: String) -> LTXModel? {
        all.first { $0.id == id }
    }

    static func model(repo: String) -> LTXModel? {
        all.first { $0.repo == repo }
    }

    static func resolvedModel(id: String?) -> LTXModel {
        guard let id, let model = model(id: id) else { return defaultModel }
        return model
    }

    static func selectedModel(userDefaults: UserDefaults = .standard) -> LTXModel {
        let id = userDefaults.string(forKey: selectedModelIDKey) ?? defaultModelID
        return resolvedModel(id: id)
    }
}

enum LTX25ModelCatalog {
    public static let ltx25ExperimentalID = "ltx25_experimental"

    public static let ltx25Experimental = LTXModel(
        id: ltx25ExperimentalID,
        repo: "Lightricks/LTX-2.5",
        displayName: "LTX-2.5 (Experimental)",
        downloadSize: "~25GB",
        supportsBuiltInAudio: false,
        qualityWarning: "Experimental: LTX-2.5 model running on Apple Silicon / MLX runtime.",
        recommendedStepsLower: 15,
        recommendedStepsUpper: 30,
        tips: "Requires MLX-compatible LTX-2.5 weights and LTX Gemma 4 text encoder."
    )

    static let all: [LTXModel] = [
        ltx25Experimental
    ]

    static func model(id: String) -> LTXModel? {
        all.first { $0.id == id }
    }
}

enum LTXTextEncoderCatalog {
    static let selectedTextEncoderIDKey = "selectedTextEncoderID"
    /// When the "Custom" preset is selected, this repo id is passed as `--text-encoder-repo`.
    static let customTextEncoderRepoKey = "customTextEncoderRepo"
    // Match upstream mlx-video-with-audio default unless the user explicitly opts into Q4.
    static let defaultTextEncoderID = "gemma3_12b_bf16"

    static let all: [LTXTextEncoder] = [
        LTXTextEncoder(
            id: "gemma3_12b_bf16",
            repo: "mlx-community/gemma-3-12b-it-bf16",
            displayName: "Gemma 12B bf16 (max quality, ~24 GB RAM)",
            downloadSize: "~24GB",
            qualityWarning: nil,
            tips: "Quality-first upstream default. Uses substantially more memory during text encoding."
        ),
        LTXTextEncoder(
            id: "gemma3_4b_bf16",
            repo: "mlx-community/gemma-3-4b-it-bf16",
            displayName: "Gemma 4B bf16 (balanced, ~10 GB RAM)",
            downloadSize: "~10GB",
            qualityWarning: nil,
            tips: "Lower memory than 12B bf16; good balance for unified LTX models on 32 GB Macs."
        ),
        LTXTextEncoder(
            id: "gemma3_12b_4bit",
            repo: "mlx-community/gemma-3-12b-it-4bit",
            displayName: "Gemma 12B 4-bit (lowest RAM among presets, ~7 GB)",
            downloadSize: "~7GB",
            qualityWarning: "Quantized: much lower memory use with possible prompt-conditioning quality tradeoffs.",
            tips: "Recommended for 16 GB Macs or when the 12B bf16 text encoder is killed by the system (SIGKILL)."
        ),
        LTXTextEncoder(
            id: "custom",
            repo: "",
            displayName: "Custom Hugging Face repo…",
            downloadSize: "varies",
            qualityWarning: nil,
            tips: "Enter any compatible Gemma MLX repo id below. Nothing is downloaded until you run a generation."
        ),
    ]

    static var defaultTextEncoder: LTXTextEncoder {
        all.first { $0.id == defaultTextEncoderID } ?? all[0]
    }

    static func textEncoder(id: String) -> LTXTextEncoder? {
        all.first { $0.id == id }
    }

    static func textEncoder(repo: String) -> LTXTextEncoder? {
        all.first { $0.repo == repo }
    }

    static func resolvedTextEncoder(id: String?) -> LTXTextEncoder {
        guard let id else { return defaultTextEncoder }
        if id == "custom" {
            let raw = UserDefaults.standard.string(forKey: customTextEncoderRepoKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return LTXTextEncoder(
                id: "custom",
                repo: raw,
                displayName: raw.isEmpty ? "Custom (not set)" : "Custom (\(raw))",
                downloadSize: "varies",
                qualityWarning: raw.isEmpty
                    ? "Set a repository id in Preferences → General (Custom text encoder field)."
                    : nil,
                tips: nil
            )
        }
        guard let textEncoder = textEncoder(id: id) else { return defaultTextEncoder }
        return textEncoder
    }

    static func selectedTextEncoder(userDefaults: UserDefaults = .standard) -> LTXTextEncoder {
        let id = userDefaults.string(forKey: selectedTextEncoderIDKey) ?? defaultTextEncoderID
        return resolvedTextEncoder(id: id)
    }
}

struct GenerationRequest: Identifiable, Codable, Equatable {
    let id: UUID
    let prompt: String
    let negativePrompt: String
    let voiceoverText: String  // Optional voiceover narration text
    let voiceoverSource: String  // "elevenlabs" or "mlx-audio"
    let voiceoverVoice: String   // Voice ID for TTS
    let sourceImagePath: String?  // For image-to-video mode
    /// Visual orientation used only to orient a preset-derived resolution.
    /// `nil` means an un-resolved request; queue preflight freezes a concrete
    /// value (including `.none`) so a waiting job cannot change later.
    let presetResolutionOrientation: SourceImageOrientation?
    let musicEnabled: Bool       // Whether to generate background music
    let musicGenre: String?      // Music genre raw value
    let disableAudio: Bool       // Skip audio in unified AV model
    let gemmaRepetitionPenalty: Double  // Gemma prompt enhancement repetition penalty
    let gemmaTopP: Double              // Gemma prompt enhancement top-p sampling
    let modelId: String                // Selected model ID from catalog
    let textEncoderId: String          // Selected Gemma text encoder ID from catalog
    var parameters: GenerationParameters
    let createdAt: Date
    var status: GenerationStatus
    // Director-extension metadata (all optional for backward compatibility)
    var modelRevision: String?         // Pinned model revision used for this request
    var quantization: String?          // Quantization of the selected model ("q4", "q8", "bf16")
    var qualityMode: String?           // "auto" / "high" / "compact" / "advanced"
    var preset: String?                // user-facing GenerationPreset snapshot
    /// Duration intent that must survive profile resolution. For Custom the
    /// caller-owned frame count remains authoritative.
    var targetDurationSeconds: Double?
    /// Origin of the request (generate/oneShot/storyboard/hybrid/apiV1).
    var generationSource: String?
    var customModelsEnabled: Bool
    var customModelLocalPath: String?  // Frozen local model / snapshot path at request creation time
    var customModelSourceMode: String? // Frozen source mode ("huggingFace" or "local") at request creation time
    var customModelProfileID: UUID?    // Bound custom model profile UUID if generated with a profile
    var customModelDisplayNameSnapshot: String? // Snapshot of profile display name at creation time
    /// Frozen MiniMax H3 renderer configuration. Queue execution must not
    /// re-read mutable Preferences and accidentally run a different server.
    var minimaxH3ModelDirectory: String?
    var minimaxH3RuntimeExecutablePath: String?
    var minimaxH3Endpoint: String?
    /// Effective H3 timing selected at queue preflight.
    var minimaxH3ChainWindows: Int?
    var minimaxH3ExpectedFrames: Int?
    var minimaxH3RequestedDurationSeconds: Double?
    var minimaxH3Fast: Bool?
    var brief: String?                 // Original user brief before prompt compilation
    var filmProjectID: UUID?
    var shotID: UUID?
    var takeID: UUID?
    
    /// True if this is an image-to-video request
    var isImageToVideo: Bool {
        sourceImagePath != nil && !sourceImagePath!.isEmpty
    }

    /// True if this request represents a continuation from a previous shot/take
    var isContinuation: Bool {
        isImageToVideo && (generationSource == "hybrid" || generationSource == "storyboard" || generationSource == "autoMovie" || takeID != nil)
    }
    
    /// True if voiceover text is provided
    var hasVoiceover: Bool {
        !voiceoverText.isEmpty
    }
    
    /// True if music generation is enabled
    var hasMusic: Bool {
        musicEnabled && musicGenre != nil
    }
    
    init(
        id: UUID = UUID(),
        prompt: String,
        brief: String? = nil,
        negativePrompt: String = "",
        voiceoverText: String = "",
        voiceoverSource: String = "mlx-audio",
        voiceoverVoice: String = "af_heart",
        sourceImagePath: String? = nil,
        presetResolutionOrientation: SourceImageOrientation? = nil,
        musicEnabled: Bool = false,
        musicGenre: String? = nil,
        disableAudio: Bool = false,
        gemmaRepetitionPenalty: Double = 1.2,
        gemmaTopP: Double = 0.9,
        modelId: String = LTXModelCatalog.defaultModelID,
        textEncoderId: String = LTXTextEncoderCatalog.defaultTextEncoderID,
        parameters: GenerationParameters = .default,
        createdAt: Date = Date(),
        status: GenerationStatus = .pending,
        modelRevision: String? = nil,
        quantization: String? = nil,
        qualityMode: String? = nil,
        preset: String? = nil,
        targetDurationSeconds: Double? = nil,
        generationSource: String? = nil,
        customModelsEnabled: Bool? = nil,
        customModelLocalPath: String? = nil,
        customModelSourceMode: String? = nil,
        customModelProfileID: UUID? = nil,
        customModelDisplayNameSnapshot: String? = nil,
        minimaxH3ModelDirectory: String? = nil,
        minimaxH3RuntimeExecutablePath: String? = nil,
        minimaxH3Endpoint: String? = nil,
        minimaxH3ChainWindows: Int? = nil,
        minimaxH3ExpectedFrames: Int? = nil,
        minimaxH3RequestedDurationSeconds: Double? = nil,
        minimaxH3Fast: Bool? = nil,
        filmProjectID: UUID? = nil,
        shotID: UUID? = nil,
        takeID: UUID? = nil,
        userDefaults: UserDefaults = .standard
    ) {
        self.id = id
        self.prompt = prompt
        self.brief = brief
        self.negativePrompt = negativePrompt
        self.voiceoverText = voiceoverText
        self.voiceoverSource = voiceoverSource
        self.voiceoverVoice = voiceoverVoice
        self.sourceImagePath = sourceImagePath
        self.presetResolutionOrientation = presetResolutionOrientation
        self.musicEnabled = musicEnabled
        self.musicGenre = musicGenre
        self.disableAudio = disableAudio
        self.gemmaRepetitionPenalty = gemmaRepetitionPenalty
        self.gemmaTopP = gemmaTopP
        self.modelId = modelId
        self.textEncoderId = textEncoderId
        self.parameters = parameters
        self.createdAt = createdAt
        self.status = status
        self.modelRevision = modelRevision
        self.quantization = quantization
        self.qualityMode = qualityMode
        self.preset = preset
        self.targetDurationSeconds = targetDurationSeconds
        self.generationSource = generationSource
        self.customModelsEnabled = customModelsEnabled ?? FeatureFlags.isEnabled(.customModelsV1, userDefaults: userDefaults)
        self.filmProjectID = filmProjectID
        self.shotID = shotID
        self.takeID = takeID
        self.minimaxH3ChainWindows = minimaxH3ChainWindows
        self.minimaxH3ExpectedFrames = minimaxH3ExpectedFrames
        self.minimaxH3RequestedDurationSeconds = minimaxH3RequestedDurationSeconds
        self.minimaxH3Fast = minimaxH3Fast

        if MiniMaxH3Configuration.isMiniMaxH3(modelID: modelId) {
            let snapshot = MiniMaxH3Configuration.Snapshot.current(forModelID: modelId, userDefaults: userDefaults)
            self.minimaxH3ModelDirectory = minimaxH3ModelDirectory ?? snapshot.modelDirectory
            self.minimaxH3RuntimeExecutablePath = minimaxH3RuntimeExecutablePath ?? snapshot.runtimeExecutablePath
            self.minimaxH3Endpoint = minimaxH3Endpoint ?? snapshot.endpoint
        } else {
            self.minimaxH3ModelDirectory = minimaxH3ModelDirectory
            self.minimaxH3RuntimeExecutablePath = minimaxH3RuntimeExecutablePath
            self.minimaxH3Endpoint = minimaxH3Endpoint
        }

        if let profile = CustomModelProfileStore.profile(forModelID: modelId, userDefaults: userDefaults) {
            self.customModelProfileID = profile.id
            self.customModelDisplayNameSnapshot = profile.displayName
            self.customModelSourceMode = CustomModelSourceMode.local.rawValue
            if let explicitPath = customModelLocalPath, !explicitPath.isEmpty {
                self.customModelLocalPath = LTX2MLXRuntime.localModelDirectory(at: explicitPath) ?? explicitPath
            } else {
                self.customModelLocalPath = LTX2MLXRuntime.localModelDirectory(at: profile.modelPath) ?? profile.modelPath
            }
        } else if modelId == ModelRegistry.customModelID {
            self.customModelProfileID = customModelProfileID
            self.customModelDisplayNameSnapshot = customModelDisplayNameSnapshot
            let effectiveMode = customModelSourceMode
                ?? userDefaults.string(forKey: ModelRegistry.customSourceModeUserDefaultsKey)
                ?? CustomModelSourceMode.huggingFace.rawValue
            self.customModelSourceMode = effectiveMode

            if effectiveMode == CustomModelSourceMode.local.rawValue {
                if let explicitPath = customModelLocalPath, !explicitPath.isEmpty {
                    self.customModelLocalPath = LTX2MLXRuntime.localModelDirectory(at: explicitPath) ?? explicitPath
                } else if let storedPath = userDefaults.string(forKey: ModelRegistry.customLocalPathUserDefaultsKey)?.trimmingCharacters(in: .whitespacesAndNewlines), !storedPath.isEmpty {
                    self.customModelLocalPath = LTX2MLXRuntime.localModelDirectory(at: storedPath) ?? storedPath
                } else {
                    self.customModelLocalPath = nil
                }
            } else {
                self.customModelLocalPath = customModelLocalPath
            }
        } else {
            self.customModelProfileID = customModelProfileID
            self.customModelDisplayNameSnapshot = customModelDisplayNameSnapshot
            self.customModelLocalPath = customModelLocalPath
            self.customModelSourceMode = customModelSourceMode
        }
    }

    enum CodingKeys: String, CodingKey {
        case id
        case prompt
        case brief
        case negativePrompt
        case voiceoverText
        case voiceoverSource
        case voiceoverVoice
        case sourceImagePath
        case presetResolutionOrientation
        case musicEnabled
        case musicGenre
        case disableAudio
        case gemmaRepetitionPenalty
        case gemmaTopP
        case modelId
        case textEncoderId
        case parameters
        case createdAt
        case status
        case modelRevision
        case quantization
        case qualityMode
        case preset
        case targetDurationSeconds
        case generationSource
        case customModelsEnabled
        case customModelLocalPath
        case customModelSourceMode
        case customModelProfileID
        case customModelDisplayNameSnapshot
        case minimaxH3ModelDirectory
        case minimaxH3RuntimeExecutablePath
        case minimaxH3Endpoint
        case minimaxH3ChainWindows
        case minimaxH3ExpectedFrames
        case minimaxH3RequestedDurationSeconds
        case filmProjectID
        case shotID
        case takeID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        prompt = try container.decode(String.self, forKey: .prompt)
        brief = try container.decodeIfPresent(String.self, forKey: .brief)
        negativePrompt = try container.decode(String.self, forKey: .negativePrompt)
        voiceoverText = try container.decode(String.self, forKey: .voiceoverText)
        voiceoverSource = try container.decode(String.self, forKey: .voiceoverSource)
        voiceoverVoice = try container.decode(String.self, forKey: .voiceoverVoice)
        sourceImagePath = try container.decodeIfPresent(String.self, forKey: .sourceImagePath)
        presetResolutionOrientation = try container.decodeIfPresent(
            SourceImageOrientation.self, forKey: .presetResolutionOrientation)
        musicEnabled = try container.decode(Bool.self, forKey: .musicEnabled)
        musicGenre = try container.decodeIfPresent(String.self, forKey: .musicGenre)
        disableAudio = try container.decode(Bool.self, forKey: .disableAudio)
        gemmaRepetitionPenalty = try container.decode(Double.self, forKey: .gemmaRepetitionPenalty)
        gemmaTopP = try container.decode(Double.self, forKey: .gemmaTopP)
        modelId = try container.decodeIfPresent(String.self, forKey: .modelId) ?? LTXModelCatalog.defaultModelID
        textEncoderId = try container.decodeIfPresent(String.self, forKey: .textEncoderId) ?? LTXTextEncoderCatalog.defaultTextEncoderID
        parameters = try container.decode(GenerationParameters.self, forKey: .parameters)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        status = try container.decode(GenerationStatus.self, forKey: .status)
        modelRevision = try container.decodeIfPresent(String.self, forKey: .modelRevision)
        quantization = try container.decodeIfPresent(String.self, forKey: .quantization)
        qualityMode = try container.decodeIfPresent(String.self, forKey: .qualityMode)
        preset = try container.decodeIfPresent(String.self, forKey: .preset)
        targetDurationSeconds = try container.decodeIfPresent(Double.self, forKey: .targetDurationSeconds)
        generationSource = try container.decodeIfPresent(String.self, forKey: .generationSource)
        customModelsEnabled = try container.decodeIfPresent(Bool.self, forKey: .customModelsEnabled) ?? false
        customModelLocalPath = try container.decodeIfPresent(String.self, forKey: .customModelLocalPath)
        customModelSourceMode = try container.decodeIfPresent(String.self, forKey: .customModelSourceMode)
        customModelProfileID = try container.decodeIfPresent(UUID.self, forKey: .customModelProfileID)
        customModelDisplayNameSnapshot = try container.decodeIfPresent(String.self, forKey: .customModelDisplayNameSnapshot)
        minimaxH3ModelDirectory = try container.decodeIfPresent(String.self, forKey: .minimaxH3ModelDirectory)
        minimaxH3RuntimeExecutablePath = try container.decodeIfPresent(
            String.self, forKey: .minimaxH3RuntimeExecutablePath)
        minimaxH3Endpoint = try container.decodeIfPresent(String.self, forKey: .minimaxH3Endpoint)
        minimaxH3ChainWindows = try container.decodeIfPresent(Int.self, forKey: .minimaxH3ChainWindows)
        minimaxH3ExpectedFrames = try container.decodeIfPresent(Int.self, forKey: .minimaxH3ExpectedFrames)
        minimaxH3RequestedDurationSeconds = try container.decodeIfPresent(
            Double.self, forKey: .minimaxH3RequestedDurationSeconds)
        filmProjectID = try container.decodeIfPresent(UUID.self, forKey: .filmProjectID)
        shotID = try container.decodeIfPresent(UUID.self, forKey: .shotID)
        takeID = try container.decodeIfPresent(UUID.self, forKey: .takeID)
    }

    var requestedDurationSeconds: Double {
        Double(parameters.numFrames) / Double(max(1, parameters.fps))
    }
}

enum GenerationStatus: String, Codable, Equatable {
    case pending
    case processing
    case completed
    case failed
    case cancelled
}

struct GenerationParameters: Codable, Equatable, Hashable {
    var numInferenceSteps: Int
    var guidanceScale: Double
    var width: Int
    var height: Int
    var numFrames: Int
    var fps: Int
    var seed: Int?
    var vaeTilingMode: String
    var imageStrength: Double
    
    // Default for LTX-2 on Apple Silicon
    static let `default` = GenerationParameters(
        numInferenceSteps: 30,
        guidanceScale: 3.0,
        width: 768,
        height: 512,
        numFrames: 121,
        fps: 24,
        seed: nil,
        vaeTilingMode: "auto",
        imageStrength: 1.0
    )
    
    // Quick preview - fewer frames and steps
    static let preview = GenerationParameters(
        numInferenceSteps: 15,
        guidanceScale: 3.0,
        width: 512,
        height: 320,
        numFrames: 49,
        fps: 24,
        seed: nil,
        vaeTilingMode: "auto",
        imageStrength: 1.0
    )
    
    // High quality - more steps
    static let highQuality = GenerationParameters(
        numInferenceSteps: 40,
        guidanceScale: 3.0,
        width: 768,
        height: 512,
        numFrames: 121,
        fps: 24,
        seed: nil,
        vaeTilingMode: "auto",
        imageStrength: 1.0
    )
    
    var estimatedDuration: String {
        // Rough estimate based on parameters
        let baseTime = Double(numInferenceSteps) * 0.5
        let sizeMultiplier = Double(width * height) / (768.0 * 512.0)
        let frameMultiplier = Double(numFrames) / 97.0
        let totalSeconds = baseTime * sizeMultiplier * frameMultiplier
        
        if totalSeconds < 60 {
            return "\(Int(totalSeconds))s"
        } else {
            let minutes = Int(totalSeconds) / 60
            let seconds = Int(totalSeconds) % 60
            return "\(minutes)m \(seconds)s"
        }
    }
    
    var videoLength: String {
        let totalSeconds = Double(numFrames) / Double(fps)
        if totalSeconds < 60 {
            return String(format: "%.1fs", totalSeconds)
        } else {
            let minutes = Int(totalSeconds) / 60
            let seconds = totalSeconds.truncatingRemainder(dividingBy: 60)
            return String(format: "%dm %.1fs", minutes, seconds)
        }
    }
    
    var estimatedVRAM: Int {
        // LTX-2 is a 19B model - requires significant unified memory
        // Base ~20GB for model, plus ~200MB per frame at 768x512
        let baseVRAM = 20.0 + Double(numFrames) * 0.2
        let resolutionScale = Double(width * height) / (768.0 * 512.0)
        return Int(baseVRAM * resolutionScale)
    }
}
