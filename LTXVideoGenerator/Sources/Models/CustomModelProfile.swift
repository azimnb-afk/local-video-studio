import Foundation

/// Represents a user-configured local model profile running on an isolated runtime (e.g. ltx-2-mlx).
struct CustomModelProfile: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var displayName: String
    var modelFamily: String
    var runtimeKind: String
    var modelPath: String
    var isEnabled: Bool
    var createdAt: Date

    init(
        id: UUID = UUID(),
        displayName: String,
        modelFamily: String = "LTX",
        runtimeKind: String = "ltx-2-mlx",
        modelPath: String,
        isEnabled: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.modelFamily = modelFamily
        self.runtimeKind = runtimeKind
        self.modelPath = modelPath
        self.isEnabled = isEnabled
        self.createdAt = createdAt
    }

    /// Prefix used to encode this profile into a unique modelID for selection and routing.
    static let idPrefix = "custom_profile_"

    /// The model ID string used in ModelRegistry and GenerationRequest (e.g. "custom_profile_<UUID>").
    var modelID: String {
        "\(Self.idPrefix)\(id.uuidString)"
    }

    /// Resolves a profile UUID from a prefixed model ID string, or nil if not a profile model ID.
    static func profileID(from modelID: String) -> UUID? {
        guard modelID.hasPrefix(idPrefix) else { return nil }
        let rawUUID = String(modelID.dropFirst(idPrefix.count))
        return UUID(uuidString: rawUUID)
    }
}

/// Persistent store and management policy for CustomModelProfile collections.
enum CustomModelProfileStore {
    static let maxProfiles = 5
    static let profilesUserDefaultsKey = "customModelProfiles"
    static let legacyLocalPathUserDefaultsKey = "customLTX2MLXLocalPath"
    static let legacyRepositoryUserDefaultsKey = "customLTX2MLXRepository"
    static let legacySourceModeUserDefaultsKey = "customLTX2MLXSourceMode"

    enum StoreError: LocalizedError, Equatable {
        case maximumProfilesReached(limit: Int)
        case profileNotFound(UUID)
        case emptyDisplayName
        case emptyModelPath

        var errorDescription: String? {
            switch self {
            case .maximumProfilesReached(let limit):
                return "Cannot add more than \(limit) custom model profiles."
            case .profileNotFound(let id):
                return "Custom model profile '\(id)' was not found."
            case .emptyDisplayName:
                return "Model profile display name cannot be empty."
            case .emptyModelPath:
                return "Model folder path cannot be empty."
            }
        }
    }

    /// Loads all saved profiles from UserDefaults, performing idempotent one-time legacy migration if needed.
    static func loadProfiles(userDefaults: UserDefaults = .standard) -> [CustomModelProfile] {
        if let data = userDefaults.data(forKey: profilesUserDefaultsKey) {
            if let decoded = try? JSONDecoder().decode([CustomModelProfile].self, from: data) {
                return Array(decoded.prefix(maxProfiles))
            }
        }

        // One-time legacy migration check
        if let legacyPath = userDefaults.string(forKey: legacyLocalPathUserDefaultsKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !legacyPath.isEmpty {
            let migratedProfile = CustomModelProfile(
                displayName: "Custom LTX-2 MLX Model",
                modelFamily: "LTX",
                runtimeKind: "ltx-2-mlx",
                modelPath: legacyPath,
                isEnabled: true,
                createdAt: Date()
            )
            let profiles = [migratedProfile]
            saveProfiles(profiles, userDefaults: userDefaults)
            return profiles
        }

        return []
    }

    /// Saves the profile list to UserDefaults. Enforces maxProfiles limit.
    static func saveProfiles(_ profiles: [CustomModelProfile], userDefaults: UserDefaults = .standard) {
        let capped = Array(profiles.prefix(maxProfiles))
        if let data = try? JSONEncoder().encode(capped) {
            userDefaults.set(data, forKey: profilesUserDefaultsKey)
        }
    }

    /// Adds a new custom model profile.
    static func addProfile(_ profile: CustomModelProfile, userDefaults: UserDefaults = .standard) throws {
        let trimmedName = profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw StoreError.emptyDisplayName }
        let trimmedPath = profile.modelPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { throw StoreError.emptyModelPath }

        var profiles = loadProfiles(userDefaults: userDefaults)
        guard profiles.count < maxProfiles else {
            throw StoreError.maximumProfilesReached(limit: maxProfiles)
        }

        var newProfile = profile
        newProfile.displayName = trimmedName
        newProfile.modelPath = trimmedPath

        // If duplicate ID exists, replace; otherwise append
        if let index = profiles.firstIndex(where: { $0.id == newProfile.id }) {
            profiles[index] = newProfile
        } else {
            profiles.append(newProfile)
        }

        saveProfiles(profiles, userDefaults: userDefaults)
    }

    /// Updates an existing custom model profile.
    static func updateProfile(_ profile: CustomModelProfile, userDefaults: UserDefaults = .standard) throws {
        let trimmedName = profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw StoreError.emptyDisplayName }
        let trimmedPath = profile.modelPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { throw StoreError.emptyModelPath }

        var profiles = loadProfiles(userDefaults: userDefaults)
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else {
            throw StoreError.profileNotFound(profile.id)
        }

        var updated = profile
        updated.displayName = trimmedName
        updated.modelPath = trimmedPath
        profiles[index] = updated
        saveProfiles(profiles, userDefaults: userDefaults)
    }

    /// Removes a custom model profile by ID. Never touches or deletes disk model files.
    static func removeProfile(id: UUID, userDefaults: UserDefaults = .standard) {
        var profiles = loadProfiles(userDefaults: userDefaults)
        profiles.removeAll { $0.id == id }
        saveProfiles(profiles, userDefaults: userDefaults)
    }

    /// Finds a profile by UUID.
    static func profile(for id: UUID, userDefaults: UserDefaults = .standard) -> CustomModelProfile? {
        loadProfiles(userDefaults: userDefaults).first { $0.id == id }
    }

    /// Finds a profile by prefixed model ID (e.g. "custom_profile_<UUID>").
    static func profile(forModelID modelID: String, userDefaults: UserDefaults = .standard) -> CustomModelProfile? {
        guard let id = CustomModelProfile.profileID(from: modelID) else { return nil }
        return profile(for: id, userDefaults: userDefaults)
    }

    /// Resolves profile-specific readiness.
    static func readiness(
        for profile: CustomModelProfile,
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) -> LTX2MLXRuntime.ComponentReadiness {
        LTX2MLXRuntime.modelReadiness(
            localPath: profile.modelPath,
            sourceMode: .local,
            userDefaults: userDefaults,
            fileManager: fileManager
        )
    }
}
