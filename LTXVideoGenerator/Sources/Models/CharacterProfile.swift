import Foundation

struct CharacterProfile: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var name: String
    var prompt: String
    var negativePrompt: String
    var sourceImagePath: String?
    var voiceoverText: String
    var voiceoverSource: String
    var voiceoverVoice: String
    var musicEnabled: Bool
    var musicGenre: String?
    var disableAudio: Bool
    var modelId: String
    var parameters: GenerationParameters
    let createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        prompt: String,
        negativePrompt: String,
        sourceImagePath: String?,
        voiceoverText: String,
        voiceoverSource: String,
        voiceoverVoice: String,
        musicEnabled: Bool,
        musicGenre: String?,
        disableAudio: Bool,
        modelId: String,
        parameters: GenerationParameters,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.negativePrompt = negativePrompt
        self.sourceImagePath = sourceImagePath
        self.voiceoverText = voiceoverText
        self.voiceoverSource = voiceoverSource
        self.voiceoverVoice = voiceoverVoice
        self.musicEnabled = musicEnabled
        self.musicGenre = musicGenre
        self.disableAudio = disableAudio
        self.modelId = modelId
        self.parameters = parameters
        self.createdAt = createdAt
    }
}

/// Explicit, non-mutating boundary for a future "Add from Character Profile"
/// action. Profiles are never migrated automatically, and an external source
/// image path is deliberately not adopted as a managed Character asset.
enum CharacterProfileBibleBridge {
    static func candidate(from profile: CharacterProfile) -> BibleCharacter {
        var appearance = CharacterAppearance()
        appearance.generalNotes = profile.prompt
        return BibleCharacter(
            name: profile.name,
            appearance: appearance,
            roleNotes: "Candidate imported from Character Profile. Review before saving."
        )
    }
}

@MainActor
class CharacterProfileManager: ObservableObject {
    @Published var profiles: [CharacterProfile] = []
    @Published var selectedProfile: CharacterProfile?

    private let profilesFile: URL

    nonisolated init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("LTXVideoGenerator", isDirectory: true)
        profilesFile = appDir.appendingPathComponent("character_profiles.json")

        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
    }

    func loadInitialData() {
        guard FileManager.default.fileExists(atPath: profilesFile.path) else { return }

        do {
            let data = try Data(contentsOf: profilesFile)
            profiles = try JSONDecoder().decode([CharacterProfile].self, from: data)
        } catch {
            print("Failed to load character profiles: \(error)")
        }
    }

    func addProfile(_ profile: CharacterProfile) {
        profiles.append(profile)
        selectedProfile = profile
        saveProfiles()
    }

    func deleteProfile(_ profile: CharacterProfile) {
        profiles.removeAll { $0.id == profile.id }

        if selectedProfile?.id == profile.id {
            selectedProfile = profiles.first
        }

        saveProfiles()
    }

    private func saveProfiles() {
        do {
            let data = try JSONEncoder().encode(profiles)
            try data.write(to: profilesFile)
        } catch {
            print("Failed to save character profiles: \(error)")
        }
    }
}
