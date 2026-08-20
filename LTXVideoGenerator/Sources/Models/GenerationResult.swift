import Foundation

struct GenerationResult: Identifiable, Codable {
    let id: UUID
    let requestId: UUID
    let prompt: String
    let enhancedPrompt: String?  // AI-enhanced prompt (if Gemma enhancement was used)
    let negativePrompt: String
    let voiceoverText: String  // Voiceover narration text (for audio generation)
    let voiceoverSource: String  // "elevenlabs" or "mlx-audio"
    let voiceoverVoice: String   // Voice ID for TTS
    let modelId: String
    let parameters: GenerationParameters
    let videoPath: String
    let thumbnailPath: String?
    let audioPath: String?       // Path to voiceover audio
    let musicPath: String?       // Path to background music
    let musicGenre: String?      // Music genre used
    let sourceImagePath: String?  // Source image used for I2V
    let createdAt: Date
    let completedAt: Date
    let duration: TimeInterval
    let seed: Int
    // Director-extension metadata (all optional for backward compatibility).
    // requested* comes from parameters; effective* is after the 64-px floor;
    // actual* is read from the real MP4 via ffprobe (source of truth).
    var modelRevision: String?
    var quantization: String?
    var qualityMode: String?
    var preset: String?
    var effectiveProfileID: String?
    var effectiveProfileName: String?
    var effectiveProfileReason: String?
    var requestedWidth: Int?
    var requestedHeight: Int?
    var requestedDurationSeconds: Double?
    var targetDurationSeconds: Double?
    var audioEnabled: Bool?
    var generationSource: String?
    var effectiveWidth: Int?
    var effectiveHeight: Int?
    var actualWidth: Int?
    var actualHeight: Int?
    var actualFPS: Double?
    var actualDuration: Double?
    var actualFrameCount: Int?
    var backendKind: String?
    var effectiveFrameCount: Int?
    var effectiveChainWindows: Int?
    var peakMemoryBytes: Int64?
    var swapPeakBytes: Int64?
    var filmProjectID: UUID?
    var shotID: UUID?
    var takeID: UUID?
    var brief: String?

    var videoURL: URL {
        URL(fileURLWithPath: videoPath)
    }
    
    var thumbnailURL: URL? {
        thumbnailPath.map { URL(fileURLWithPath: $0) }
    }
    
    var audioURL: URL? {
        audioPath.map { URL(fileURLWithPath: $0) }
    }
    
    var musicURL: URL? {
        musicPath.map { URL(fileURLWithPath: $0) }
    }
    
    var hasAudio: Bool {
        audioPath != nil
    }
    
    var hasMusic: Bool {
        musicPath != nil
    }
    
    
    var formattedDuration: String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        }
        return "\(seconds)s"
    }
    
    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: completedAt)
    }

    var model: LTXModel {
        if modelId == MiniMaxH3Configuration.modelID,
           let descriptor = ModelRegistry.shared.descriptor(id: modelId) {
            return LTXModel(
                id: descriptor.id,
                repo: descriptor.repository,
                displayName: descriptor.displayName,
                downloadSize: descriptor.estimatedModelSizeGB.map { "~\(Int($0))GB" } ?? "local",
                supportsBuiltInAudio: descriptor.capabilities.synchronizedAudio,
                qualityWarning: "Experimental specialized renderer.",
                recommendedStepsLower: 8,
                recommendedStepsUpper: 8,
                tips: descriptor.runtime.verificationNotes)
        }
        if modelId == LTX25ModelCatalog.ltx25ExperimentalID {
            return LTX25ModelCatalog.ltx25Experimental
        }
        return LTXModelCatalog.resolvedModel(id: modelId)
    }

    var modelDisplayName: String {
        if modelId == LTX25ModelCatalog.ltx25ExperimentalID {
            return LTX25ModelCatalog.ltx25Experimental.displayName
        }
        if let descriptor = ModelRegistry.shared.descriptor(id: modelId) {
            return descriptor.displayName
        }
        if let model = LTXModelCatalog.model(id: modelId) {
            return model.displayName
        }
        if let effectiveProfileName, !effectiveProfileName.isEmpty {
            return effectiveProfileName
        }
        if !modelId.isEmpty {
            return modelId
        }
        return LTXModelCatalog.defaultModel.displayName
    }

    init(
        id: UUID,
        requestId: UUID,
        prompt: String,
        brief: String? = nil,
        enhancedPrompt: String?,
        negativePrompt: String,
        voiceoverText: String,
        voiceoverSource: String,
        voiceoverVoice: String,
        modelId: String,
        parameters: GenerationParameters,
        videoPath: String,
        thumbnailPath: String?,
        audioPath: String?,
        musicPath: String?,
        musicGenre: String?,
        sourceImagePath: String? = nil,
        createdAt: Date,
        completedAt: Date,
        duration: TimeInterval,
        seed: Int,
        modelRevision: String? = nil,
        quantization: String? = nil,
        qualityMode: String? = nil,
        preset: String? = nil,
        effectiveProfileID: String? = nil,
        effectiveProfileName: String? = nil,
        effectiveProfileReason: String? = nil,
        requestedWidth: Int? = nil,
        requestedHeight: Int? = nil,
        requestedDurationSeconds: Double? = nil,
        targetDurationSeconds: Double? = nil,
        audioEnabled: Bool? = nil,
        generationSource: String? = nil,
        effectiveWidth: Int? = nil,
        effectiveHeight: Int? = nil,
        actualWidth: Int? = nil,
        actualHeight: Int? = nil,
        actualFPS: Double? = nil,
        actualDuration: Double? = nil,
        actualFrameCount: Int? = nil,
        backendKind: String? = nil,
        effectiveFrameCount: Int? = nil,
        effectiveChainWindows: Int? = nil,
        peakMemoryBytes: Int64? = nil,
        swapPeakBytes: Int64? = nil,
        filmProjectID: UUID? = nil,
        shotID: UUID? = nil,
        takeID: UUID? = nil
    ) {
        self.id = id
        self.requestId = requestId
        self.prompt = prompt
        self.brief = brief
        self.enhancedPrompt = enhancedPrompt
        self.negativePrompt = negativePrompt
        self.voiceoverText = voiceoverText
        self.voiceoverSource = voiceoverSource
        self.voiceoverVoice = voiceoverVoice
        self.modelId = modelId
        self.parameters = parameters
        self.videoPath = videoPath
        self.thumbnailPath = thumbnailPath
        self.audioPath = audioPath
        self.musicPath = musicPath
        self.musicGenre = musicGenre
        self.sourceImagePath = sourceImagePath
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.duration = duration
        self.seed = seed
        self.modelRevision = modelRevision
        self.quantization = quantization
        self.qualityMode = qualityMode
        self.preset = preset
        self.effectiveProfileID = effectiveProfileID
        self.effectiveProfileName = effectiveProfileName
        self.effectiveProfileReason = effectiveProfileReason
        self.requestedWidth = requestedWidth
        self.requestedHeight = requestedHeight
        self.requestedDurationSeconds = requestedDurationSeconds
        self.targetDurationSeconds = targetDurationSeconds
        self.audioEnabled = audioEnabled
        self.generationSource = generationSource
        self.effectiveWidth = effectiveWidth
        self.effectiveHeight = effectiveHeight
        self.actualWidth = actualWidth
        self.actualHeight = actualHeight
        self.actualFPS = actualFPS
        self.actualDuration = actualDuration
        self.actualFrameCount = actualFrameCount
        self.backendKind = backendKind
        self.effectiveFrameCount = effectiveFrameCount
        self.effectiveChainWindows = effectiveChainWindows
        self.peakMemoryBytes = peakMemoryBytes
        self.swapPeakBytes = swapPeakBytes
        self.filmProjectID = filmProjectID
        self.shotID = shotID
        self.takeID = takeID
    }

    enum CodingKeys: String, CodingKey {
        case id
        case requestId
        case prompt
        case brief
        case enhancedPrompt
        case negativePrompt
        case voiceoverText
        case voiceoverSource
        case voiceoverVoice
        case modelId
        case parameters
        case videoPath
        case thumbnailPath
        case audioPath
        case musicPath
        case musicGenre
        case sourceImagePath
        case createdAt
        case completedAt
        case duration
        case seed
        case modelRevision
        case quantization
        case qualityMode
        case preset
        case effectiveProfileID
        case effectiveProfileName
        case effectiveProfileReason
        case requestedWidth
        case requestedHeight
        case requestedDurationSeconds
        case targetDurationSeconds
        case audioEnabled
        case generationSource
        case effectiveWidth
        case effectiveHeight
        case actualWidth
        case actualHeight
        case actualFPS
        case actualDuration
        case actualFrameCount
        case backendKind
        case effectiveFrameCount
        case effectiveChainWindows
        case peakMemoryBytes
        case swapPeakBytes
        case filmProjectID
        case shotID
        case takeID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        requestId = try container.decode(UUID.self, forKey: .requestId)
        prompt = try container.decode(String.self, forKey: .prompt)
        brief = try container.decodeIfPresent(String.self, forKey: .brief)
        enhancedPrompt = try container.decodeIfPresent(String.self, forKey: .enhancedPrompt)
        negativePrompt = try container.decode(String.self, forKey: .negativePrompt)
        voiceoverText = try container.decode(String.self, forKey: .voiceoverText)
        voiceoverSource = try container.decode(String.self, forKey: .voiceoverSource)
        voiceoverVoice = try container.decode(String.self, forKey: .voiceoverVoice)
        modelId = try container.decodeIfPresent(String.self, forKey: .modelId) ?? LTXModelCatalog.defaultModelID
        parameters = try container.decode(GenerationParameters.self, forKey: .parameters)
        videoPath = try container.decode(String.self, forKey: .videoPath)
        thumbnailPath = try container.decodeIfPresent(String.self, forKey: .thumbnailPath)
        audioPath = try container.decodeIfPresent(String.self, forKey: .audioPath)
        musicPath = try container.decodeIfPresent(String.self, forKey: .musicPath)
        musicGenre = try container.decodeIfPresent(String.self, forKey: .musicGenre)
        sourceImagePath = try container.decodeIfPresent(String.self, forKey: .sourceImagePath)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        completedAt = try container.decode(Date.self, forKey: .completedAt)
        duration = try container.decode(TimeInterval.self, forKey: .duration)
        seed = try container.decode(Int.self, forKey: .seed)
        modelRevision = try container.decodeIfPresent(String.self, forKey: .modelRevision)
        quantization = try container.decodeIfPresent(String.self, forKey: .quantization)
        qualityMode = try container.decodeIfPresent(String.self, forKey: .qualityMode)
        preset = try container.decodeIfPresent(String.self, forKey: .preset)
        effectiveProfileID = try container.decodeIfPresent(String.self, forKey: .effectiveProfileID)
        effectiveProfileName = try container.decodeIfPresent(String.self, forKey: .effectiveProfileName)
        effectiveProfileReason = try container.decodeIfPresent(String.self, forKey: .effectiveProfileReason)
        requestedWidth = try container.decodeIfPresent(Int.self, forKey: .requestedWidth)
        requestedHeight = try container.decodeIfPresent(Int.self, forKey: .requestedHeight)
        requestedDurationSeconds = try container.decodeIfPresent(Double.self, forKey: .requestedDurationSeconds)
        targetDurationSeconds = try container.decodeIfPresent(Double.self, forKey: .targetDurationSeconds)
        audioEnabled = try container.decodeIfPresent(Bool.self, forKey: .audioEnabled)
        generationSource = try container.decodeIfPresent(String.self, forKey: .generationSource)
        effectiveWidth = try container.decodeIfPresent(Int.self, forKey: .effectiveWidth)
        effectiveHeight = try container.decodeIfPresent(Int.self, forKey: .effectiveHeight)
        actualWidth = try container.decodeIfPresent(Int.self, forKey: .actualWidth)
        actualHeight = try container.decodeIfPresent(Int.self, forKey: .actualHeight)
        actualFPS = try container.decodeIfPresent(Double.self, forKey: .actualFPS)
        actualDuration = try container.decodeIfPresent(Double.self, forKey: .actualDuration)
        actualFrameCount = try container.decodeIfPresent(Int.self, forKey: .actualFrameCount)
        backendKind = try container.decodeIfPresent(String.self, forKey: .backendKind)
        effectiveFrameCount = try container.decodeIfPresent(Int.self, forKey: .effectiveFrameCount)
        effectiveChainWindows = try container.decodeIfPresent(Int.self, forKey: .effectiveChainWindows)
        peakMemoryBytes = try container.decodeIfPresent(Int64.self, forKey: .peakMemoryBytes)
        swapPeakBytes = try container.decodeIfPresent(Int64.self, forKey: .swapPeakBytes)
        filmProjectID = try container.decodeIfPresent(UUID.self, forKey: .filmProjectID)
        shotID = try container.decodeIfPresent(UUID.self, forKey: .shotID)
        takeID = try container.decodeIfPresent(UUID.self, forKey: .takeID)
    }
}

extension GenerationResult {
    static func preview() -> GenerationResult {
        GenerationResult(
            id: UUID(),
            requestId: UUID(),
            prompt: "A cinematic shot of a majestic eagle soaring through mountains",
            enhancedPrompt: "A breathtaking cinematic aerial shot captures a majestic bald eagle soaring gracefully through snow-capped mountain peaks at golden hour",
            negativePrompt: "",
            voiceoverText: "",
            voiceoverSource: "mlx-audio",
            voiceoverVoice: "af_heart",
            modelId: LTXModelCatalog.defaultModelID,
            parameters: .default,
            videoPath: "/tmp/preview.mp4",
            thumbnailPath: nil,
            audioPath: nil,
            musicPath: nil,
            musicGenre: nil,
            sourceImagePath: nil,
            createdAt: Date().addingTimeInterval(-120),
            completedAt: Date(),
            duration: 45.5,
            seed: 42
        )
    }
}
