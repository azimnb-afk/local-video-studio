import Foundation

// MARK: - Bibles

struct StoryBible: Codable, Equatable {
    var logline: String = ""
    var synopsis: String = ""
    var setting: String = ""
    var tone: String = ""
    var themes: [String] = []
}

struct CharacterBibleEntry: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var appearance: String = ""
    var wardrobe: String = ""
    var voice: String = ""
    var personality: String = ""
    var referenceImagePath: String?
}

struct CharacterBible: Codable, Equatable {
    var characters: [CharacterBibleEntry] = []

    func character(named name: String) -> CharacterBibleEntry? {
        characters.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}

// MARK: - Continuity snapshot (deterministic state carried between shots)

struct ContinuitySnapshot: Codable, Equatable {
    var location: String = ""
    var timeOfDay: String = ""
    var weather: String = ""
    var lighting: String = ""
    var characterOutfit: [String: String] = [:]     // character name → outfit
    var characterPosition: [String: String] = [:]
    var characterCondition: [String: String] = [:]  // e.g. "wet", "injured arm"
    var props: [String] = []
    var propOwner: [String: String] = [:]           // prop → character
    var wetness: [String: String] = [:]
    var injuries: [String: String] = [:]
    var dialogueState: String = ""
    var storyState: String = ""
}

// MARK: - Shot planning

struct CameraPlan: Codable, Equatable {
    var shotScale: String = "medium"     // extreme-wide/wide/medium/close-up/extreme-close-up
    var angle: String = "eye-level"      // low/eye-level/high/overhead
    var movement: String = "static"      // static/pan/tilt/dolly/track/handheld
    var composition: String = ""
}

struct AudioPlan: Codable, Equatable {
    var dialogue: [ShotDialogueLine] = []
    var footsteps: Bool = false
    var foley: [String] = []
    var sfx: [String] = []
    var ambience: String = ""
    // Global BGM lives at project level, never per shot (avoids seams).
}

struct ShotDialogueLine: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var speaker: String
    var text: String
    var language: String?
    var romanization: String?
}

// MARK: - Take

enum TakeStatus: String, Codable {
    case planned
    case queued
    case generating
    case completed
    case failed
    case cancelled
    case interrupted
}

struct Take: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var shotID: UUID

    var modelID: String
    var modelVersion: String?
    var modelRevision: String?
    var quantization: String?

    var seed: Int

    var promptSnapshot: String
    var negativePromptSnapshot: String = ""
    var settingsSnapshot: GenerationParameters
    var preset: String?
    var qualityMode: String?
    var effectiveProfileID: String?
    var effectiveProfileName: String?
    var effectiveProfileReason: String?
    var audioEnabled: Bool?

    var requestedWidth: Int
    var requestedHeight: Int
    var effectiveWidth: Int?
    var effectiveHeight: Int?
    var actualWidth: Int?
    var actualHeight: Int?

    var fps: Int
    var requestedDuration: Double
    var targetDurationSeconds: Double?
    var actualDuration: Double?

    var audioMetadata: MediaInfo?

    var outputPath: String?

    var favorite: Bool = false
    var rating: Int = 0          // 0-5
    var notes: String = ""
    var status: TakeStatus = .planned

    var generationStartedAt: Date?
    var generationCompletedAt: Date?
    var generationTime: Double?

    var peakMemoryBytes: Int64?
    var swapPeakBytes: Int64?
}

// MARK: - Shot

struct Shot: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var index: Int               // order within the project
    var title: String = ""
    var summary: String = ""     // what happens in this shot
    var durationSeconds: Double = 5
    var camera: CameraPlan = CameraPlan()
    var audio: AudioPlan = AudioPlan()
    var continuityBefore: ContinuitySnapshot?
    var explicitChanges: [String] = []   // changes this shot introduces
    var compiledPrompt: String = ""      // prompt compiler output
    var takes: [Take] = []
    var selectedTakeID: UUID?

    var selectedTake: Take? {
        guard let selectedTakeID else { return nil }
        return takes.first { $0.id == selectedTakeID }
    }
}

// MARK: - Project

struct ProjectSettings: Codable, Equatable {
    var modelID: String = LTXModelCatalog.defaultModelID
    var textEncoderID: String = LTXTextEncoderCatalog.defaultTextEncoderID
    var qualityMode: String = QualityMode.auto.rawValue
    /// Optional for schema-v1 migration. Missing legacy values resolve from
    /// qualityMode (normally Standard/Auto).
    var preset: String?
    var width: Int = 768
    var height: Int = 512
    var fps: Int = 24
    var numFrames: Int?
    var numInferenceSteps: Int?
    var audioEnabled: Bool?
    var targetDurationSeconds: Double?
    var globalBGMGenre: String?   // project-level BGM (applied at final assembly)
    var japaneseHandling: String = JapaneseDialogueHandling.native.rawValue

    var resolvedPreset: GenerationPreset {
        GenerationPreset.resolving(presetRaw: preset, qualityModeRaw: qualityMode)
    }

    var resolvedAudioEnabled: Bool { audioEnabled ?? true }
    var resolvedInferenceSteps: Int { numInferenceSteps ?? 30 }

    /// New GUI projects inherit the user's current model/text-encoder choices.
    /// Codable defaults above remain stable for legacy project migration.
    static func usingCurrentSelections(userDefaults: UserDefaults = .standard) -> ProjectSettings {
        var settings = ProjectSettings()
        settings.modelID = LTXModelCatalog.selectedModel(userDefaults: userDefaults).id
        settings.textEncoderID = LTXTextEncoderCatalog.selectedTextEncoder(userDefaults: userDefaults).id
        return settings
    }

    mutating func applyPreset(_ newPreset: GenerationPreset) {
        preset = newPreset.rawValue
        qualityMode = newPreset.qualityMode.rawValue
        switch newPreset {
        case .custom:
            numFrames = numFrames ?? 121
            numInferenceSteps = numInferenceSteps ?? 30
            audioEnabled = audioEnabled ?? true
        case .quickPreview:
            width = GenerationParameters.preview.width
            height = GenerationParameters.preview.height
            fps = GenerationParameters.preview.fps
            numFrames = GenerationParameters.preview.numFrames
            numInferenceSteps = GenerationParameters.preview.numInferenceSteps
            audioEnabled = true
        case .standard:
            width = GenerationParameters.default.width
            height = GenerationParameters.default.height
            fps = GenerationParameters.default.fps
            numFrames = GenerationParameters.default.numFrames
            numInferenceSteps = GenerationParameters.default.numInferenceSteps
            audioEnabled = true
        case .highQuality:
            width = GenerationParameters.highQuality.width
            height = GenerationParameters.highQuality.height
            fps = GenerationParameters.highQuality.fps
            numFrames = GenerationParameters.highQuality.numFrames
            numInferenceSteps = GenerationParameters.highQuality.numInferenceSteps
            audioEnabled = true
        }
    }

    mutating func markCustom() {
        applyPreset(.custom)
    }
}

enum GenerationJobState: String, Codable {
    case queued
    case running
    case completed
    case failed
    case cancelled
}

struct GenerationJob: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var projectID: UUID?
    var shotID: UUID?
    var takeID: UUID?
    var requestID: UUID
    var state: GenerationJobState = .queued
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var errorMessage: String?
}

struct FilmProject: Codable, Equatable, Identifiable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = FilmProject.currentSchemaVersion
    var id: UUID = UUID()
    var title: String
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    /// nil means a legacy/manual storyboard project.
    var workflowMode: String?
    /// Planning provenance. Optional fields preserve schema-v1 compatibility.
    var directorProvider: String?
    var directorModel: String?
    var planningMode: String?
    var fallbackReason: String?
    var settings: ProjectSettings = ProjectSettings()
    var storyBible: StoryBible = StoryBible()
    var characterBible: CharacterBible = CharacterBible()
    var shots: [Shot] = []
    var jobs: [GenerationJob] = []

    mutating func touch() {
        updatedAt = Date()
    }

    func shot(id: UUID) -> Shot? {
        shots.first { $0.id == id }
    }
}
