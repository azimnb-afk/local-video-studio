import Foundation

// MARK: - Bibles

struct StoryBible: Codable, Equatable {
    var logline: String = ""
    var synopsis: String = ""
    var setting: String = ""
    var tone: String = ""
    var themes: [String] = []
}

struct CharacterAppearance: Codable, Equatable {
    var faceDescription: String = ""
    var hair: String = ""
    var eyes: String = ""
    var ageImpression: String = ""
    var build: String = ""
    var complexion: String = ""
    var distinguishingFeatures: String = ""
    var generalNotes: String = ""

    var compactVisualSummary: String {
        [faceDescription, hair, eyes, ageImpression, build, complexion,
         distinguishingFeatures, generalNotes]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    init() {}

    /// Schema-v1 stored `appearance` as a single String. Preserve it as
    /// general notes while all new projects encode the structured form.
    init(from decoder: Decoder) throws {
        if let legacy = try? decoder.singleValueContainer().decode(String.self) {
            generalNotes = legacy
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        faceDescription = try container.decodeIfPresent(String.self, forKey: .faceDescription) ?? ""
        hair = try container.decodeIfPresent(String.self, forKey: .hair) ?? ""
        eyes = try container.decodeIfPresent(String.self, forKey: .eyes) ?? ""
        ageImpression = try container.decodeIfPresent(String.self, forKey: .ageImpression) ?? ""
        build = try container.decodeIfPresent(String.self, forKey: .build) ?? ""
        complexion = try container.decodeIfPresent(String.self, forKey: .complexion) ?? ""
        distinguishingFeatures = try container.decodeIfPresent(String.self, forKey: .distinguishingFeatures) ?? ""
        generalNotes = try container.decodeIfPresent(String.self, forKey: .generalNotes) ?? ""
    }
}

enum CharacterTraitLock: String, Codable, CaseIterable, Identifiable {
    case face
    case hair
    case eyes
    case body
    case costume
    case accessories

    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }
}

/// String-backed so a future app can add asset types without making an older
/// app reject the entire project. Unknown raw values round-trip unchanged.
struct CharacterReferenceAssetType: RawRepresentable, Codable, Hashable, Identifiable {
    var rawValue: String
    var id: String { rawValue }

    static let characterSheet = Self(rawValue: "characterSheet")
    static let face = Self(rawValue: "face")
    static let front = Self(rawValue: "front")
    static let side = Self(rawValue: "side")
    static let back = Self(rawValue: "back")
    static let expression = Self(rawValue: "expression")
    static let costumeDetail = Self(rawValue: "costumeDetail")
    static let other = Self(rawValue: "other")
    static let knownTypes: [Self] = [
        .characterSheet, .face, .front, .side, .back, .expression, .costumeDetail, .other,
    ]
}

struct CharacterReferenceAsset: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var type: CharacterReferenceAssetType
    var label: String = ""
    /// Path relative to the FilmProject's managed asset root. Never an
    /// external absolute path.
    var projectRelativePath: String?
    /// Reserved for a future content-addressed/local asset manager.
    var managedAssetIdentifier: String?
    var originalFilename: String?
    var notes: String = ""
    var mimeType: String?
    var pixelWidth: Int?
    var pixelHeight: Int?
    var fileSizeBytes: Int64?
    var detectedViews: [String] = []
    var expressions: [String] = []
    var analysisProvider: String?
    var analysisModel: String?
    var analyzedAt: Date?
    var createdAt: Date = Date()

    init(
        id: UUID = UUID(),
        type: CharacterReferenceAssetType,
        label: String = "",
        projectRelativePath: String? = nil,
        managedAssetIdentifier: String? = nil,
        originalFilename: String? = nil,
        notes: String = "",
        mimeType: String? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        fileSizeBytes: Int64? = nil,
        detectedViews: [String] = [],
        expressions: [String] = [],
        analysisProvider: String? = nil,
        analysisModel: String? = nil,
        analyzedAt: Date? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.type = type
        self.label = label
        self.projectRelativePath = projectRelativePath
        self.managedAssetIdentifier = managedAssetIdentifier
        self.originalFilename = originalFilename
        self.notes = notes
        self.mimeType = mimeType
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.fileSizeBytes = fileSizeBytes
        self.detectedViews = detectedViews
        self.expressions = expressions
        self.analysisProvider = analysisProvider
        self.analysisModel = analysisModel
        self.analyzedAt = analyzedAt
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, type, label, projectRelativePath, managedAssetIdentifier,
             originalFilename, notes, mimeType, pixelWidth, pixelHeight,
             fileSizeBytes, detectedViews, expressions, analysisProvider,
             analysisModel, analyzedAt, createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        type = try container.decode(CharacterReferenceAssetType.self, forKey: .type)
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
        projectRelativePath = try container.decodeIfPresent(String.self, forKey: .projectRelativePath)
        managedAssetIdentifier = try container.decodeIfPresent(String.self, forKey: .managedAssetIdentifier)
        originalFilename = try container.decodeIfPresent(String.self, forKey: .originalFilename)
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType)
        pixelWidth = try container.decodeIfPresent(Int.self, forKey: .pixelWidth)
        pixelHeight = try container.decodeIfPresent(Int.self, forKey: .pixelHeight)
        fileSizeBytes = try container.decodeIfPresent(Int64.self, forKey: .fileSizeBytes)
        detectedViews = try container.decodeIfPresent([String].self, forKey: .detectedViews) ?? []
        expressions = try container.decodeIfPresent([String].self, forKey: .expressions) ?? []
        analysisProvider = try container.decodeIfPresent(String.self, forKey: .analysisProvider)
        analysisModel = try container.decodeIfPresent(String.self, forKey: .analysisModel)
        analyzedAt = try container.decodeIfPresent(Date.self, forKey: .analyzedAt)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}

struct CharacterBibleEntry: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var aliases: [String]
    var appearance: CharacterAppearance
    var defaultCostume: String
    var accessories: String
    var personality: String
    var speakingStyle: String
    var roleNotes: String
    var continuityNotes: String
    var lockedTraits: Set<CharacterTraitLock>
    var referenceAssets: [CharacterReferenceAsset]
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        aliases: [String] = [],
        appearance: CharacterAppearance = CharacterAppearance(),
        defaultCostume: String = "",
        accessories: String = "",
        personality: String = "",
        speakingStyle: String = "",
        roleNotes: String = "",
        continuityNotes: String = "",
        lockedTraits: Set<CharacterTraitLock> = [],
        referenceAssets: [CharacterReferenceAsset] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.aliases = aliases
        self.appearance = appearance
        self.defaultCostume = defaultCostume
        self.accessories = accessories
        self.personality = personality
        self.speakingStyle = speakingStyle
        self.roleNotes = roleNotes
        self.continuityNotes = continuityNotes
        self.lockedTraits = lockedTraits
        self.referenceAssets = referenceAssets
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Source-compatible bridge for the original stub's wardrobe label.
    var wardrobe: String {
        get { defaultCostume }
        set { defaultCostume = newValue }
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, aliases, appearance, defaultCostume, accessories, wardrobe, voice,
             personality, speakingStyle, roleNotes, continuityNotes,
             lockedTraits, referenceAssets, referenceImagePath, createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        aliases = try container.decodeIfPresent([String].self, forKey: .aliases) ?? []
        appearance = try container.decodeIfPresent(CharacterAppearance.self, forKey: .appearance) ?? CharacterAppearance()
        defaultCostume = try container.decodeIfPresent(String.self, forKey: .defaultCostume)
            ?? container.decodeIfPresent(String.self, forKey: .wardrobe)
            ?? ""
        accessories = try container.decodeIfPresent(String.self, forKey: .accessories) ?? ""
        personality = try container.decodeIfPresent(String.self, forKey: .personality) ?? ""
        speakingStyle = try container.decodeIfPresent(String.self, forKey: .speakingStyle)
            ?? container.decodeIfPresent(String.self, forKey: .voice)
            ?? ""
        roleNotes = try container.decodeIfPresent(String.self, forKey: .roleNotes) ?? ""
        continuityNotes = try container.decodeIfPresent(String.self, forKey: .continuityNotes) ?? ""
        lockedTraits = try container.decodeIfPresent(Set<CharacterTraitLock>.self, forKey: .lockedTraits) ?? []
        referenceAssets = try container.decodeIfPresent([CharacterReferenceAsset].self, forKey: .referenceAssets) ?? []
        if referenceAssets.isEmpty,
           let legacyPath = try container.decodeIfPresent(String.self, forKey: .referenceImagePath),
           !legacyPath.isEmpty {
            referenceAssets = [CharacterReferenceAsset(
                type: .other,
                label: "Legacy reference",
                projectRelativePath: legacyPath.hasPrefix("/") ? nil : legacyPath,
                originalFilename: URL(fileURLWithPath: legacyPath).lastPathComponent,
                notes: legacyPath.hasPrefix("/") ? "Legacy external path was not adopted as a managed asset." : ""
            )]
        }
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(aliases, forKey: .aliases)
        try container.encode(appearance, forKey: .appearance)
        try container.encode(defaultCostume, forKey: .defaultCostume)
        try container.encode(accessories, forKey: .accessories)
        try container.encode(personality, forKey: .personality)
        try container.encode(speakingStyle, forKey: .speakingStyle)
        try container.encode(roleNotes, forKey: .roleNotes)
        try container.encode(continuityNotes, forKey: .continuityNotes)
        try container.encode(lockedTraits, forKey: .lockedTraits)
        try container.encode(referenceAssets, forKey: .referenceAssets)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}

typealias BibleCharacter = CharacterBibleEntry

struct CharacterBible: Codable, Equatable {
    static let currentSchemaVersion = 1
    var schemaVersion: Int = CharacterBible.currentSchemaVersion
    var characters: [BibleCharacter] = []

    func character(id: UUID) -> BibleCharacter? {
        characters.first { $0.id == id }
    }

    func character(named name: String) -> BibleCharacter? {
        let matches = characters.filter { character in
            character.matchingNames.contains { $0.caseInsensitiveCompare(name.trimmedForCharacterMatch) == .orderedSame }
        }
        return matches.count == 1 ? matches[0] : nil
    }

    init(schemaVersion: Int = CharacterBible.currentSchemaVersion, characters: [BibleCharacter] = []) {
        self.schemaVersion = schemaVersion
        self.characters = characters
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, characters }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? CharacterBible.currentSchemaVersion
        characters = try container.decodeIfPresent([BibleCharacter].self, forKey: .characters) ?? []
    }
}

private extension String {
    var trimmedForCharacterMatch: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension CharacterBibleEntry {
    var matchingNames: [String] { [name] + aliases }
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
    /// Stable references into FilmProject.characterBible. Names are display
    /// data only and may be changed without invalidating these links.
    var characterIDs: [UUID] = []
    /// Character-free prompt retained so Bible edits can deterministically
    /// recompile without repeatedly appending old character context.
    var baseCompiledPrompt: String?
    var compiledPrompt: String = ""      // prompt compiler output
    var takes: [Take] = []
    var selectedTakeID: UUID?

    var selectedTake: Take? {
        guard let selectedTakeID else { return nil }
        return takes.first { $0.id == selectedTakeID }
    }

    init(
        id: UUID = UUID(), index: Int, title: String = "", summary: String = "",
        durationSeconds: Double = 5, camera: CameraPlan = CameraPlan(),
        audio: AudioPlan = AudioPlan(), continuityBefore: ContinuitySnapshot? = nil,
        explicitChanges: [String] = [], characterIDs: [UUID] = [],
        baseCompiledPrompt: String? = nil, compiledPrompt: String = "",
        takes: [Take] = [], selectedTakeID: UUID? = nil
    ) {
        self.id = id
        self.index = index
        self.title = title
        self.summary = summary
        self.durationSeconds = durationSeconds
        self.camera = camera
        self.audio = audio
        self.continuityBefore = continuityBefore
        self.explicitChanges = explicitChanges
        self.characterIDs = characterIDs
        self.baseCompiledPrompt = baseCompiledPrompt
        self.compiledPrompt = compiledPrompt
        self.takes = takes
        self.selectedTakeID = selectedTakeID
    }

    private enum CodingKeys: String, CodingKey {
        case id, index, title, summary, durationSeconds, camera, audio,
             continuityBefore, explicitChanges, characterIDs,
             baseCompiledPrompt, compiledPrompt, takes, selectedTakeID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        index = try container.decode(Int.self, forKey: .index)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        durationSeconds = try container.decodeIfPresent(Double.self, forKey: .durationSeconds) ?? 5
        camera = try container.decodeIfPresent(CameraPlan.self, forKey: .camera) ?? CameraPlan()
        audio = try container.decodeIfPresent(AudioPlan.self, forKey: .audio) ?? AudioPlan()
        continuityBefore = try container.decodeIfPresent(ContinuitySnapshot.self, forKey: .continuityBefore)
        explicitChanges = try container.decodeIfPresent([String].self, forKey: .explicitChanges) ?? []
        characterIDs = try container.decodeIfPresent([UUID].self, forKey: .characterIDs) ?? []
        baseCompiledPrompt = try container.decodeIfPresent(String.self, forKey: .baseCompiledPrompt)
        compiledPrompt = try container.decodeIfPresent(String.self, forKey: .compiledPrompt) ?? ""
        takes = try container.decodeIfPresent([Take].self, forKey: .takes) ?? []
        selectedTakeID = try container.decodeIfPresent(UUID.self, forKey: .selectedTakeID)
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
    static let currentSchemaVersion = 2

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
    var requestedDirectorMode: String?
    var effectiveDirectorMode: String?
    var settings: ProjectSettings = ProjectSettings()
    var storyBible: StoryBible = StoryBible()
    var characterBible: CharacterBible = CharacterBible()
    var shots: [Shot] = []
    var jobs: [GenerationJob] = []

    init(id: UUID = UUID(), title: String) {
        self.id = id
        self.title = title
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, title, createdAt, updatedAt, workflowMode,
             directorProvider, directorModel, planningMode, fallbackReason,
             requestedDirectorMode, effectiveDirectorMode, settings,
             storyBible, characterBible, shots, jobs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        _ = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        schemaVersion = FilmProject.currentSchemaVersion
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decode(String.self, forKey: .title)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        workflowMode = try container.decodeIfPresent(String.self, forKey: .workflowMode)
        directorProvider = try container.decodeIfPresent(String.self, forKey: .directorProvider)
        directorModel = try container.decodeIfPresent(String.self, forKey: .directorModel)
        planningMode = try container.decodeIfPresent(String.self, forKey: .planningMode)
        fallbackReason = try container.decodeIfPresent(String.self, forKey: .fallbackReason)
        requestedDirectorMode = try container.decodeIfPresent(String.self, forKey: .requestedDirectorMode)
        effectiveDirectorMode = try container.decodeIfPresent(String.self, forKey: .effectiveDirectorMode)
        settings = try container.decodeIfPresent(ProjectSettings.self, forKey: .settings) ?? ProjectSettings()
        storyBible = try container.decodeIfPresent(StoryBible.self, forKey: .storyBible) ?? StoryBible()
        characterBible = try container.decodeIfPresent(CharacterBible.self, forKey: .characterBible) ?? CharacterBible()
        shots = try container.decodeIfPresent([Shot].self, forKey: .shots) ?? []
        jobs = try container.decodeIfPresent([GenerationJob].self, forKey: .jobs) ?? []
    }

    mutating func touch() {
        updatedAt = Date()
    }

    func shot(id: UUID) -> Shot? {
        shots.first { $0.id == id }
    }
}
