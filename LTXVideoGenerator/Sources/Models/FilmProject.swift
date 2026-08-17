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
    var displayName: String {
        switch self {
        case .face: return "Facial Features"
        case .hair: return "Hair"
        case .eyes: return "Eyes"
        case .body: return "Body Appearance"
        case .costume: return "Costume"
        case .accessories: return "Accessories"
        }
    }
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

    var displayName: String {
        switch self {
        case .characterSheet: return "Character Sheet"
        case .face: return "Face / Close-Up"
        case .front: return "Front"
        case .side: return "Side"
        case .back: return "Back"
        case .expression: return "Expression"
        case .costumeDetail: return "Costume Detail"
        default: return rawValue.capitalized
        }
    }
}

extension CharacterReferenceAsset {
    var isStartingImageCandidate: Bool {
        type != .characterSheet
    }

    var displayLabel: String {
        if !label.isEmpty && label != type.displayName {
            return "\(type.displayName) (\(label))"
        }
        return type.displayName
    }
}

/// Stable crop provenance stored independently of any analysis derivative.
/// Coordinates use the visually oriented source image with a top-left origin.
/// Every component is normalized to 0...1 so the crop can always be mapped
/// back to the project-owned original at its native resolution.
struct NormalizedCropRect: Codable, Equatable, Hashable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    static let fullImage = Self(x: 0, y: 0, width: 1, height: 1)

    /// Accepts only tiny floating-point overflow at the right/bottom edge.
    /// Invalid geometry is never silently converted into a reference asset.
    func validated(edgeEpsilon: Double = 0.000_1) -> Self? {
        guard x.isFinite, y.isFinite, width.isFinite, height.isFinite,
              x >= 0, y >= 0, width > 0, height > 0,
              x <= 1, y <= 1,
              x + width <= 1 + edgeEpsilon,
              y + height <= 1 + edgeEpsilon else { return nil }
        let clampedWidth = min(width, 1 - x)
        let clampedHeight = min(height, 1 - y)
        guard clampedWidth > 0, clampedHeight > 0 else { return nil }
        return Self(x: x, y: y, width: clampedWidth, height: clampedHeight)
    }
}

/// String-backed for forward-compatible provenance. Vision proposals are not
/// truth until reviewed; manual and user-adjusted results remain distinct.
struct CharacterReferenceExtractionMethod: RawRepresentable, Codable, Hashable {
    var rawValue: String

    static let visionProposed = Self(rawValue: "visionProposed")
    static let manual = Self(rawValue: "manual")
    static let visionProposedUserAdjusted = Self(rawValue: "visionProposedUserAdjusted")
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
    /// Optional because deleting the source sheet does not invalidate an
    /// already-extracted project-owned reference image.
    var sourceAssetID: UUID?
    var sourceCropRect: NormalizedCropRect?
    var sourceImageWidth: Int?
    var sourceImageHeight: Int?
    var extractionMethod: CharacterReferenceExtractionMethod?
    var isUserAdjusted: Bool?
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
        sourceAssetID: UUID? = nil,
        sourceCropRect: NormalizedCropRect? = nil,
        sourceImageWidth: Int? = nil,
        sourceImageHeight: Int? = nil,
        extractionMethod: CharacterReferenceExtractionMethod? = nil,
        isUserAdjusted: Bool? = nil,
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
        self.sourceAssetID = sourceAssetID
        self.sourceCropRect = sourceCropRect
        self.sourceImageWidth = sourceImageWidth
        self.sourceImageHeight = sourceImageHeight
        self.extractionMethod = extractionMethod
        self.isUserAdjusted = isUserAdjusted
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, type, label, projectRelativePath, managedAssetIdentifier,
             originalFilename, notes, mimeType, pixelWidth, pixelHeight,
             fileSizeBytes, detectedViews, expressions, analysisProvider,
             analysisModel, analyzedAt, sourceAssetID, sourceCropRect,
             sourceImageWidth, sourceImageHeight, extractionMethod,
             isUserAdjusted, createdAt
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
        sourceAssetID = try container.decodeIfPresent(UUID.self, forKey: .sourceAssetID)
        sourceCropRect = try container.decodeIfPresent(NormalizedCropRect.self, forKey: .sourceCropRect)
        sourceImageWidth = try container.decodeIfPresent(Int.self, forKey: .sourceImageWidth)
        sourceImageHeight = try container.decodeIfPresent(Int.self, forKey: .sourceImageHeight)
        extractionMethod = try container.decodeIfPresent(CharacterReferenceExtractionMethod.self, forKey: .extractionMethod)
        isUserAdjusted = try container.decodeIfPresent(Bool.self, forKey: .isUserAdjusted)
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

/// Story-level motion intent. These values describe pacing only; they do not
/// alter frames, FPS, duration, presets, or backend parameters.
enum MotionTempo: String, Codable, CaseIterable {
    case slow
    case normal
    case fast
}

enum CameraTempo: String, Codable, CaseIterable {
    case `static`
    case slow
    case normal
    case fast
}

enum PlaybackStyle: String, Codable, CaseIterable {
    case realTime
    case slowMotion
    case fastMotion
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

    var startingImageReferenceAssetID: UUID?
    var sourceImagePath: String?
    /// Historical source/provenance for this queued generation. Optional so
    /// all projects written before Generation Diagnostics continue to decode.
    var generationSourceDiagnostics: GenerationSourceDiagnostics?
    /// Historical execution facts. Optional so projects created before runtime
    /// diagnostics safely remain "unavailable" rather than being guessed from
    /// current settings or a later output file.
    var generationRuntimeDiagnostics: GenerationRuntimeDiagnostics?
}

// MARK: - Continuity chain

/// How a shot relates visually to the shot before it.
///
/// `continueFromPrevious` reuses the previous shot's final frame as this
/// shot's starting image (existing single-image I2V bridge), which visually
/// carries the person, wardrobe, location and lighting forward. `cut` starts
/// the shot independently. `auto` lets the planner decide, and resolves
/// conservatively to `cut` when the relationship is unclear.
///
/// This is a visual anchor, not identity conditioning: it improves continuity
/// but never guarantees the same person or place.
enum ShotContinuityMode: String, Codable, CaseIterable {
    case auto
    case continueFromPrevious = "continue"
    case cut

    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .continueFromPrevious: return "Continue"
        case .cut: return "Cut"
        }
    }
}

/// Why a shot cannot currently generate because its continuity input is
/// unavailable. Continuity is never silently downgraded to plain text-to-video.
enum ContinuityBlockReason: String, Codable, Error {
    case previousShotIncomplete
    case previousOutputMissing
    case frameExtractionFailed
    case continuityAssetMissing

    var userMessage: String {
        switch self {
        case .previousShotIncomplete:
            return "Waiting for the previous shot to finish before this shot can continue from it."
        case .previousOutputMissing:
            return "The previous shot's video file is missing, so this shot cannot continue from it."
        case .frameExtractionFailed:
            return "Could not read the final frame of the previous shot."
        case .continuityAssetMissing:
            return "The inherited starting frame for this shot is missing."
        }
    }
}

/// How the image recorded in `identityRefreshAnchorRelativePath` was obtained.
/// Optional on `Shot` so projects written by the original MVP still decode;
/// an absent value is treated as a generated anchor with the legacy staleness
/// rule.
enum IdentityRefreshAnchorOrigin: String, Codable, Equatable {
    case generated
    case reusedOpeningReference
    case reusedPriorRefresh

    var displayName: String {
        switch self {
        case .generated: return "Generated refresh"
        case .reusedOpeningReference: return "Opening Reference reuse"
        case .reusedPriorRefresh: return "Prior refresh reuse"
        }
    }
}

// MARK: - Shot

struct Shot: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var index: Int               // order within the project
    var title: String = ""
    var summary: String = ""     // what happens in this shot
    var durationSeconds: Double = 5
    var camera: CameraPlan = CameraPlan()
    /// Persisted planning intent, independent of CameraPlan's movement type.
    var motionTempo: MotionTempo = .normal
    var cameraTempo: CameraTempo = .normal
    var playbackStyle: PlaybackStyle = .realTime
    var audio: AudioPlan = AudioPlan()
    var continuityBefore: ContinuitySnapshot?
    var explicitChanges: [String] = []   // changes this shot introduces
    /// Stable references into FilmProject.characterBible. Names are display
    /// data only and may be changed without invalidating these links.
    var characterIDs: [UUID] = []
    var startingImageReferenceAssetID: UUID?
    /// Character-free prompt retained so Bible edits can deterministically
    /// recompile without repeatedly appending old character context.
    var baseCompiledPrompt: String?
    var compiledPrompt: String = ""      // prompt compiler output
    var takes: [Take] = []
    var selectedTakeID: UUID?

    // MARK: Continuity chain (all optional; absent in projects created before
    // the feature existed, which keep behaving exactly as before).

    /// Effective mode used for generation, badges and the continuity chain.
    /// For Auto Movie this is the reconciled value; everywhere else it is the
    /// planner/user intent unchanged.
    var continuityMode: ShotContinuityMode?
    /// What the Director originally asked for, kept so a reconciled promotion
    /// stays visible after reload (Director: cut → effective: continue).
    var plannedContinuityMode: ShotContinuityMode?
    /// Why the effective mode differs from, or matches, the planned one.
    var continuityReconciliationReason: String?
    /// Project-relative path of the frame inherited from the previous shot.
    var continuityImageRelativePath: String?
    /// A fresh identity-bearing starting image generated for this shot because
    /// the frame it would have inherited could not supply one. Managed,
    /// project-relative, and invalidated when the upstream take changes.
    var identityRefreshAnchorRelativePath: String?
    /// Whether the refresh stage reused an existing image or rendered a new
    /// preparation clip. This is observability and staleness metadata, not a
    /// new source-precedence mechanism.
    var identityRefreshAnchorOrigin: IdentityRefreshAnchorOrigin?
    /// For a reused prior refresh, identifies the Shot that owns the original
    /// persisted anchor. Opening Reference reuse has no source Shot.
    var identityRefreshAnchorSourceShotID: UUID?
    /// The take the refresh was derived from, so a Retake upstream marks it
    /// stale instead of silently reusing an anchor built from an old frame.
    var identityRefreshSourceTakeID: UUID?
    /// Short human-readable record of what the policy decided, for the shot UI.
    var identityRefreshNote: String?
    /// Take the inherited frame was extracted from, so a Retake can be
    /// detected as making this shot's continuity input stale.
    var continuitySourceTakeID: UUID?
    /// Set when a `continue` shot cannot resolve its inherited frame.
    var continuityBlockedReason: ContinuityBlockReason?

    // MARK: Capability-aware planning (Auto Movie only, both optional)

    /// The framing the Director asked for, when the capability pass planned a
    /// different one. Absent when the shot was planned as-is.
    var originalCameraScale: String?
    /// Why the effective plan differs from the planned one.
    var capabilityAdjustmentReason: String?

    var selectedTake: Take? {
        guard let selectedTakeID else { return nil }
        return takes.first { $0.id == selectedTakeID }
    }

    /// Take usable for assembly: an explicit selection wins; otherwise a single
    /// completed take may stand in. Multiple completed takes with no selection
    /// stay ambiguous on purpose — the app never ranks takes automatically.
    var assemblyCandidateTake: Take? {
        if let selectedTake, selectedTake.status == .completed { return selectedTake }
        if selectedTakeID != nil { return nil }
        let completed = takes.filter { $0.status == .completed }
        return completed.count == 1 ? completed[0] : nil
    }

    /// Latest completed take, used as the continuity source when no explicit
    /// selection exists.
    var continuitySourceTake: Take? {
        if let selectedTake, selectedTake.status == .completed { return selectedTake }
        return takes
            .filter { $0.status == .completed }
            .max { ($0.generationCompletedAt ?? .distantPast) < ($1.generationCompletedAt ?? .distantPast) }
    }

    init(
        id: UUID = UUID(), index: Int, title: String = "", summary: String = "",
        durationSeconds: Double = 5, camera: CameraPlan = CameraPlan(),
        motionTempo: MotionTempo = .normal,
        cameraTempo: CameraTempo = .normal,
        playbackStyle: PlaybackStyle = .realTime,
        audio: AudioPlan = AudioPlan(), continuityBefore: ContinuitySnapshot? = nil,
        explicitChanges: [String] = [], characterIDs: [UUID] = [],
        startingImageReferenceAssetID: UUID? = nil,
        baseCompiledPrompt: String? = nil, compiledPrompt: String = "",
        takes: [Take] = [], selectedTakeID: UUID? = nil,
        continuityMode: ShotContinuityMode? = nil,
        plannedContinuityMode: ShotContinuityMode? = nil,
        continuityReconciliationReason: String? = nil,
        continuityImageRelativePath: String? = nil,
        continuitySourceTakeID: UUID? = nil,
        continuityBlockedReason: ContinuityBlockReason? = nil,
        originalCameraScale: String? = nil,
        capabilityAdjustmentReason: String? = nil
    ) {
        self.id = id
        self.index = index
        self.title = title
        self.summary = summary
        self.durationSeconds = durationSeconds
        self.camera = camera
        self.motionTempo = motionTempo
        self.cameraTempo = cameraTempo
        self.playbackStyle = playbackStyle
        self.audio = audio
        self.continuityBefore = continuityBefore
        self.explicitChanges = explicitChanges
        self.characterIDs = characterIDs
        self.startingImageReferenceAssetID = startingImageReferenceAssetID
        self.baseCompiledPrompt = baseCompiledPrompt
        self.compiledPrompt = compiledPrompt
        self.takes = takes
        self.selectedTakeID = selectedTakeID
        self.continuityMode = continuityMode
        self.plannedContinuityMode = plannedContinuityMode
        self.continuityReconciliationReason = continuityReconciliationReason
        self.continuityImageRelativePath = continuityImageRelativePath
        self.continuitySourceTakeID = continuitySourceTakeID
        self.continuityBlockedReason = continuityBlockedReason
        self.originalCameraScale = originalCameraScale
        self.capabilityAdjustmentReason = capabilityAdjustmentReason
    }

    private enum CodingKeys: String, CodingKey {
        case id, index, title, summary, durationSeconds, camera,
             motionTempo, cameraTempo, playbackStyle, audio,
             continuityBefore, explicitChanges, characterIDs,
             startingImageReferenceAssetID,
             baseCompiledPrompt, compiledPrompt, takes, selectedTakeID,
             continuityMode, plannedContinuityMode, continuityReconciliationReason,
             continuityImageRelativePath,
             continuitySourceTakeID, continuityBlockedReason,
             originalCameraScale, capabilityAdjustmentReason,
             identityRefreshAnchorRelativePath, identityRefreshAnchorOrigin,
             identityRefreshAnchorSourceShotID, identityRefreshSourceTakeID,
             identityRefreshNote
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        index = try container.decode(Int.self, forKey: .index)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        durationSeconds = try container.decodeIfPresent(Double.self, forKey: .durationSeconds) ?? 5
        camera = try container.decodeIfPresent(CameraPlan.self, forKey: .camera) ?? CameraPlan()
        motionTempo = try container.decodeIfPresent(MotionTempo.self, forKey: .motionTempo) ?? .normal
        cameraTempo = try container.decodeIfPresent(CameraTempo.self, forKey: .cameraTempo) ?? .normal
        playbackStyle = try container.decodeIfPresent(PlaybackStyle.self, forKey: .playbackStyle) ?? .realTime
        audio = try container.decodeIfPresent(AudioPlan.self, forKey: .audio) ?? AudioPlan()
        continuityBefore = try container.decodeIfPresent(ContinuitySnapshot.self, forKey: .continuityBefore)
        explicitChanges = try container.decodeIfPresent([String].self, forKey: .explicitChanges) ?? []
        characterIDs = try container.decodeIfPresent([UUID].self, forKey: .characterIDs) ?? []
        startingImageReferenceAssetID = try container.decodeIfPresent(UUID.self, forKey: .startingImageReferenceAssetID)
        baseCompiledPrompt = try container.decodeIfPresent(String.self, forKey: .baseCompiledPrompt)
        compiledPrompt = try container.decodeIfPresent(String.self, forKey: .compiledPrompt) ?? ""
        takes = try container.decodeIfPresent([Take].self, forKey: .takes) ?? []
        selectedTakeID = try container.decodeIfPresent(UUID.self, forKey: .selectedTakeID)
        continuityMode = try container.decodeIfPresent(ShotContinuityMode.self, forKey: .continuityMode)
        plannedContinuityMode = try container.decodeIfPresent(ShotContinuityMode.self, forKey: .plannedContinuityMode)
        continuityReconciliationReason = try container.decodeIfPresent(String.self, forKey: .continuityReconciliationReason)
        continuityImageRelativePath = try container.decodeIfPresent(String.self, forKey: .continuityImageRelativePath)
        // Absent in every project written before Adaptive Identity Refresh;
        // those simply have no refresh anchor, which is correct for them.
        identityRefreshAnchorRelativePath = try container.decodeIfPresent(
            String.self, forKey: .identityRefreshAnchorRelativePath)
        identityRefreshAnchorOrigin = try container.decodeIfPresent(
            IdentityRefreshAnchorOrigin.self, forKey: .identityRefreshAnchorOrigin)
        identityRefreshAnchorSourceShotID = try container.decodeIfPresent(
            UUID.self, forKey: .identityRefreshAnchorSourceShotID)
        identityRefreshSourceTakeID = try container.decodeIfPresent(
            UUID.self, forKey: .identityRefreshSourceTakeID)
        identityRefreshNote = try container.decodeIfPresent(
            String.self, forKey: .identityRefreshNote)
        continuitySourceTakeID = try container.decodeIfPresent(UUID.self, forKey: .continuitySourceTakeID)
        continuityBlockedReason = try container.decodeIfPresent(ContinuityBlockReason.self, forKey: .continuityBlockedReason)
        originalCameraScale = try container.decodeIfPresent(String.self, forKey: .originalCameraScale)
        capabilityAdjustmentReason = try container.decodeIfPresent(String.self, forKey: .capabilityAdjustmentReason)
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

    var effectiveWidth: Int { (width / 64) * 64 }
    var effectiveHeight: Int { (height / 64) * 64 }

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

    /// Writes down the size this project is *actually* generating at, before it
    /// becomes an explicit Custom size.
    ///
    /// Custom keeps whatever dimensions it holds so an explicit user size beats
    /// automatic orientation. That makes the switch onto Custom lossy: the
    /// stored `width`/`height` are the preset's landscape base, while the real
    /// canvas is that base oriented to the source image. Freezing without
    /// resolving first silently turns a portrait project landscape, which is
    /// what a user hit by only toggling Audio.
    ///
    /// No-op when already Custom (nothing left to derive) and when the preset
    /// has no oriented size to offer.
    mutating func materializeOrientedSizeBeforeCustom(orientation: SourceImageOrientation) {
        let previous = resolvedPreset
        guard previous != .custom else { return }
        guard let dimensions = GenerationSettingsResolver.orientedPresetDimensions(
            preset: previous,
            orientation: orientation,
            modelID: modelID,
            audioEnabled: resolvedAudioEnabled
        ) else { return }
        width = dimensions.width
        height = dimensions.height
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
    /// Which local protocol produced the plan ("structuredJSON"/"textProtocol").
    /// Absent in every project planned before capability negotiation existed,
    /// and absent for Basic Director plans, which use no local protocol.
    var directorProtocol: String?
    var fallbackReason: String?
    var requestedDirectorMode: String?
    var effectiveDirectorMode: String?
    var settings: ProjectSettings = ProjectSettings()
    var storyBible: StoryBible = StoryBible()
    var characterBible: CharacterBible = CharacterBible()
    var shots: [Shot] = []
    var jobs: [GenerationJob] = []

    // MARK: Automatic assembly bookkeeping (optional; legacy projects decode
    // with these absent and simply have no assembly recorded yet).

    /// Ordered take identity the last successful assembly was produced from.
    /// Re-running with an unchanged signature is skipped, which is what makes
    /// automatic assembly fire exactly once per completed run.
    var lastAssemblySignature: String?
    var assembledMoviePath: String?
    var assembledAt: Date?

    /// Enabled continuity chaining for this project's automatic run.
    var continuityChainEnabled: Bool?

    /// Optional visual reference for the opening shot only. Absent in every
    /// project saved before the feature existed, which decodes as disabled.
    var characterAnchor: CharacterAnchor = CharacterAnchor()

    /// Optional scene-like still used as the opening shot's first frame. Takes
    /// precedence over `characterAnchor`, which points at a Character Bible
    /// asset rather than at a frame. Absent in older projects.
    var openingReferenceImage: OpeningReferenceImage?
    /// What local vision saw in `openingReferenceImage`. Derived state: it is
    /// only trusted while `sourceRelativePath` still matches the attached
    /// image, so replacing or clearing the reference cannot leave a stale
    /// costume behind.
    var openingReferenceAppearance: OpeningReferenceAppearance?
    /// How the Opening Reference compares with the Character Sheet. Reporting
    /// only: it never rewrites canonical identity and never changes which image
    /// the first shot starts from.
    var characterOpeningConsistency: CharacterOpeningConsistency?

    /// One global BGM overlay applied once, after Final Assembly, to the
    /// whole movie. Never injected into any Shot's audio plan or prompt.
    /// Absent in every project written before this feature; those decode
    /// with `bgmEnabled == false` and produce byte-identical Final Assembly
    /// behavior to before this field existed.
    var finalAudio: FinalAudioSettings = FinalAudioSettings()

    init(id: UUID = UUID(), title: String) {
        self.id = id
        self.title = title
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, title, createdAt, updatedAt, workflowMode,
             directorProvider, directorModel, planningMode, fallbackReason,
             requestedDirectorMode, effectiveDirectorMode, directorProtocol, settings,
             storyBible, characterBible, shots, jobs,
             lastAssemblySignature, assembledMoviePath, assembledAt,
             continuityChainEnabled, characterAnchor, openingReferenceImage,
             openingReferenceAppearance, characterOpeningConsistency, finalAudio
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
        directorProtocol = try container.decodeIfPresent(String.self, forKey: .directorProtocol)
        fallbackReason = try container.decodeIfPresent(String.self, forKey: .fallbackReason)
        requestedDirectorMode = try container.decodeIfPresent(String.self, forKey: .requestedDirectorMode)
        effectiveDirectorMode = try container.decodeIfPresent(String.self, forKey: .effectiveDirectorMode)
        settings = try container.decodeIfPresent(ProjectSettings.self, forKey: .settings) ?? ProjectSettings()
        storyBible = try container.decodeIfPresent(StoryBible.self, forKey: .storyBible) ?? StoryBible()
        characterBible = try container.decodeIfPresent(CharacterBible.self, forKey: .characterBible) ?? CharacterBible()
        shots = try container.decodeIfPresent([Shot].self, forKey: .shots) ?? []
        jobs = try container.decodeIfPresent([GenerationJob].self, forKey: .jobs) ?? []
        lastAssemblySignature = try container.decodeIfPresent(String.self, forKey: .lastAssemblySignature)
        assembledMoviePath = try container.decodeIfPresent(String.self, forKey: .assembledMoviePath)
        assembledAt = try container.decodeIfPresent(Date.self, forKey: .assembledAt)
        continuityChainEnabled = try container.decodeIfPresent(Bool.self, forKey: .continuityChainEnabled)
        characterAnchor = try container.decodeIfPresent(CharacterAnchor.self, forKey: .characterAnchor)
            ?? CharacterAnchor()
        openingReferenceImage = try container.decodeIfPresent(
            OpeningReferenceImage.self, forKey: .openingReferenceImage)
        // Absent in every project written before this feature; those simply
        // have no derived appearance, which is the correct answer for them.
        openingReferenceAppearance = try container.decodeIfPresent(
            OpeningReferenceAppearance.self, forKey: .openingReferenceAppearance)
        characterOpeningConsistency = try container.decodeIfPresent(
            CharacterOpeningConsistency.self, forKey: .characterOpeningConsistency)
        // Absent in every project written before this feature; those decode
        // with BGM off, reproducing their exact previous assembly output.
        finalAudio = try container.decodeIfPresent(FinalAudioSettings.self, forKey: .finalAudio)
            ?? FinalAudioSettings()
    }

    mutating func touch() {
        updatedAt = Date()
    }

    func shot(id: UUID) -> Shot? {
        shots.first { $0.id == id }
    }

    func findReferenceAsset(id assetID: UUID) -> (character: BibleCharacter, asset: CharacterReferenceAsset)? {
        for character in characterBible.characters {
            if let asset = character.referenceAssets.first(where: { $0.id == assetID }) {
                return (character, asset)
            }
        }
        return nil
    }

    func managedReferenceAssetURL(for assetID: UUID, store: FilmProjectStore = .shared) -> URL? {
        guard let (_, asset) = findReferenceAsset(id: assetID),
              let relativePath = asset.projectRelativePath else {
            return nil
        }
        return store.managedCharacterAssetURL(projectID: id, relativePath: relativePath)
    }

    mutating func setStartingImageAsset(_ assetID: UUID?, forShot shotID: UUID) {
        guard let shotIndex = shots.firstIndex(where: { $0.id == shotID }) else { return }
        shots[shotIndex].startingImageReferenceAssetID = assetID
    }

    mutating func sanitizeStartingImageReferences() {
        let validAssetIDs = Set(characterBible.characters.flatMap { $0.referenceAssets.map(\.id) })
        for i in shots.indices {
            if let assetID = shots[i].startingImageReferenceAssetID, !validAssetIDs.contains(assetID) {
                shots[i].startingImageReferenceAssetID = nil
            }
        }
    }
}

struct AspectMismatchCalculator {
    /// Returns true if aspect ratio difference is >= 20% or orientation differs between source and target.
    static func hasAspectMismatch(
        sourceWidth: Int?,
        sourceHeight: Int?,
        targetWidth: Int,
        targetHeight: Int,
        threshold: Double = 0.20
    ) -> Bool {
        guard let sw = sourceWidth, let sh = sourceHeight, sw > 0, sh > 0, targetWidth > 0, targetHeight > 0 else {
            return false
        }

        // Orientation mismatch check (portrait vs landscape)
        let sourceIsPortrait = sw < sh
        let targetIsPortrait = targetWidth < targetHeight
        if sourceIsPortrait != targetIsPortrait {
            return true
        }

        let sourceAspect = Double(sw) / Double(sh)
        let targetAspect = Double(targetWidth) / Double(targetHeight)
        let ratio = sourceAspect / targetAspect
        return abs(ratio - 1.0) >= threshold
    }
}
