import Foundation

// MARK: - Classification / policy

enum ContentClassification: String, Codable {
    case general
    case custom
    case unknown
    case blocked
}

struct PolicyMetadata: Codable, Equatable, Hashable {
    var contentClassification: ContentClassification
    /// Evidence for the classification (model card language, upstream statement).
    var classificationEvidence: String?

    static let general = PolicyMetadata(contentClassification: .general, classificationEvidence: nil)
    static let custom = PolicyMetadata(contentClassification: .custom, classificationEvidence: nil)
}

enum ModelPolicyError: Error, Equatable {
    case unknownClassificationRejected(modelID: String)
    case blockedModel(modelID: String)
    case modelNotRegistered(modelID: String)
    case modelUnverified(modelID: String)

    var userMessage: String {
        switch self {
        case .unknownClassificationRejected(let id):
            return "Model '\(id)' has an unknown content classification and cannot be used."
        case .blockedModel(let id):
            return "Model '\(id)' is blocked."
        case .modelNotRegistered(let id):
            return "Model '\(id)' is not in the model registry."
        case .modelUnverified(let id):
            return "Model '\(id)' has not passed runtime verification yet."
        }
    }
}

// MARK: - Descriptor components

struct ArchitectureDescriptor: Codable, Equatable, Hashable {
    var modelFamily: String        // "LTX"
    var modelVersion: String       // "2.3"
    var modelType: String          // "unified-av", "video"
}

struct CapabilitySet: Codable, Equatable, Hashable {
    var textToVideo: Bool
    var imageToVideo: Bool
    var synchronizedAudio: Bool
    var keyframes: Bool = false
    var firstLastFrame: Bool = false
    var continuation: Bool = false
    var lora: Bool = false
    var upscale: Bool = false
}

struct RuntimeCompatibility: Codable, Equatable, Hashable {
    /// Backend the model is packaged for.
    var backend: String            // "mlx-video-with-audio" or "ltx-2-mlx"
    var minimumBackendVersion: String?
    /// True only after verification.
    var verified: Bool
    var verificationNotes: String?
}

struct ModelLicenseMetadata: Codable, Equatable, Hashable {
    var name: String
    var url: String?
    var requiresAcknowledgement: Bool
}

struct ModelArtifact: Codable, Equatable, Hashable {
    var path: String
    var kind: String
    var sizeBytes: Int64?
    var sha256: String?
}

// MARK: - Descriptor

struct ModelDescriptor: Identifiable, Codable, Equatable, Hashable {
    let id: String
    var displayName: String
    var repository: String
    var revision: String?
    var localPath: String?

    var quantization: String?
    var precision: String?

    var estimatedModelSizeGB: Double?
    var recommendedUnifiedMemoryGB: Int?
    var minimumUnifiedMemoryGB: Int?

    var architecture: ArchitectureDescriptor
    var capabilities: CapabilitySet
    var runtime: RuntimeCompatibility
    var policy: PolicyMetadata
    var license: ModelLicenseMetadata
    var artifacts: [ModelArtifact] = []
    var configHash: String?

    /// True when this descriptor mirrors an entry in the legacy LTXModelCatalog.
    var isOfficial: Bool = false

    /// Legacy catalog entry for the official fast path, when applicable.
    var legacyCatalogModel: LTXModel? {
        LTXModelCatalog.model(id: id)
    }
}

struct ModelInstallRecord: Codable, Equatable {
    var modelID: String
    var installedAt: Date
    var revision: String?
    var licenseAcknowledgedAt: Date?
    var checksumVerified: Bool
}

// MARK: - Custom Model Source Mode

public enum CustomModelSourceMode: String, Codable, CaseIterable {
    case huggingFace = "huggingFace"
    case local = "local"
}

// MARK: - Registry

/// Registry of known models. Official models mirror LTXModelCatalog;
/// user-supplied custom models run on the isolated ltx-2-mlx backend.
final class ModelRegistry {
    static let shared = ModelRegistry()

    public static let customModelID = "custom_ltx2_mlx"
    public static let customRepositoryUserDefaultsKey = "customLTX2MLXRepository"
    public static let customLocalPathUserDefaultsKey = "customLTX2MLXLocalPath"
    public static let customSourceModeUserDefaultsKey = "customLTX2MLXSourceMode"

    private(set) var descriptors: [String: ModelDescriptor] = [:]
    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        seedOfficialModels()
        seedCustomModel()
    }

    // MARK: Seeding

    private func ltx25Descriptor() -> ModelDescriptor {
        let model = LTX25ModelCatalog.ltx25Experimental
        return ModelDescriptor(
            id: model.id,
            displayName: model.displayName,
            repository: model.repo,
            revision: nil,
            localPath: nil,
            quantization: nil,
            precision: "bf16",
            estimatedModelSizeGB: 25,
            recommendedUnifiedMemoryGB: 64,
            minimumUnifiedMemoryGB: 32,
            architecture: ArchitectureDescriptor(
                modelFamily: "LTX",
                modelVersion: "2.5",
                modelType: "unified-av"
            ),
            capabilities: CapabilitySet(
                textToVideo: true,
                imageToVideo: true,
                synchronizedAudio: false,
                keyframes: true,
                firstLastFrame: true,
                continuation: true
            ),
            runtime: RuntimeCompatibility(
                backend: "ltx-2-mlx",
                minimumBackendVersion: "0.14.19",
                verified: true,
                verificationNotes: "Experimental LTX-2.5 support on MLX backend."
            ),
            policy: .general,
            license: ModelLicenseMetadata(
                name: "LTX-2.5 Community License",
                url: "https://huggingface.co/\(model.repo)",
                requiresAcknowledgement: false
            ),
            isOfficial: false
        )
    }

    private func seedOfficialModels() {
        for legacy in LTXModelCatalog.all {
            let quant: String? = legacy.id.hasSuffix("_q4") ? "q4" : nil
            let sizeGB = Double(
                legacy.downloadSize
                    .replacingOccurrences(of: "~", with: "")
                    .replacingOccurrences(of: "GB", with: "")
            )
            descriptors[legacy.id] = ModelDescriptor(
                id: legacy.id,
                displayName: legacy.displayName,
                repository: legacy.repo,
                revision: nil,
                localPath: nil,
                quantization: quant,
                precision: quant == nil ? "bf16" : nil,
                estimatedModelSizeGB: sizeGB,
                recommendedUnifiedMemoryGB: quant == "q4" ? 32 : 64,
                minimumUnifiedMemoryGB: quant == "q4" ? 32 : 48,
                architecture: ArchitectureDescriptor(
                    modelFamily: "LTX",
                    modelVersion: legacy.id.contains("ltx23") || legacy.id.contains("2.3") ? "2.3" : "2",
                    modelType: "unified-av"
                ),
                capabilities: CapabilitySet(
                    textToVideo: true,
                    imageToVideo: true,
                    synchronizedAudio: legacy.supportsBuiltInAudio
                ),
                runtime: RuntimeCompatibility(
                    backend: "mlx-video-with-audio",
                    minimumBackendVersion: "0.1.36",
                    verified: true,
                    verificationNotes: "Official catalog model."
                ),
                policy: .general,
                license: ModelLicenseMetadata(
                    name: "LTX-2 Community License (weights); see model card",
                    url: "https://huggingface.co/\(legacy.repo)",
                    requiresAcknowledgement: false
                ),
                isOfficial: true
            )
        }
    }

    /// User-configurable custom model running on the ltx-2-mlx backend.
    private func seedCustomModel() {
        let repo = userDefaults.string(forKey: Self.customRepositoryUserDefaultsKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let localPath = userDefaults.string(forKey: Self.customLocalPathUserDefaultsKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveRepo = repo.isEmpty ? "user-supplied/custom-model" : repo

        descriptors[Self.customModelID] = ModelDescriptor(
            id: Self.customModelID,
            displayName: "Custom LTX-2 MLX Model",
            repository: effectiveRepo,
            revision: nil,
            localPath: localPath,
            quantization: "q4",
            precision: nil,
            estimatedModelSizeGB: 14,
            recommendedUnifiedMemoryGB: 32,
            minimumUnifiedMemoryGB: 24,
            architecture: ArchitectureDescriptor(modelFamily: "LTX", modelVersion: "2.3", modelType: "unified-av"),
            capabilities: CapabilitySet(textToVideo: true, imageToVideo: true, synchronizedAudio: true),
            runtime: RuntimeCompatibility(
                backend: "ltx-2-mlx",
                minimumBackendVersion: "0.14.19",
                verified: true,
                verificationNotes: "Runs on the user-configured ltx-2-mlx runtime with user-supplied model weights."
            ),
            policy: .custom,
            license: ModelLicenseMetadata(
                name: "User-supplied model license — see upstream repository",
                url: repo.isEmpty ? nil : "https://huggingface.co/\(repo)",
                requiresAcknowledgement: false
            ),
            isOfficial: false
        )
    }

    // MARK: Lookup

    func descriptor(id: String) -> ModelDescriptor? {
        if id == Self.customModelID {
            seedCustomModel()
        }
        if id == LTX25ModelCatalog.ltx25ExperimentalID {
            return ltx25Descriptor()
        }
        return descriptors[id]
    }

    /// Resolves a ModelDescriptor tailored for an immutable GenerationRequest,
    /// honoring any frozen local snapshot path or pinned revision.
    func descriptor(for request: GenerationRequest) -> ModelDescriptor? {
        guard var desc = descriptor(id: request.modelId) else { return nil }
        if request.modelId == Self.customModelID {
            if let frozenPath = request.customModelLocalPath, !frozenPath.isEmpty {
                desc.localPath = frozenPath
            }
            if let frozenRevision = request.modelRevision {
                desc.revision = frozenRevision
            }
        }
        return desc
    }

    func refreshVerification(from lab: CompatibilityLab) {
        for (id, model) in descriptors where !model.isOfficial {
            descriptors[id]?.runtime.verified = lab.isVerified(modelID: id)
        }
    }

    /// Models visible for selection.
    /// - Official models are always listed.
    /// - Custom models are listed when customModelsV1 is enabled.
    func selectableModels(customModelsEnabled: Bool? = nil) -> [ModelDescriptor] {
        let allowCustom = customModelsEnabled ?? FeatureFlags.isEnabled(.customModelsV1, userDefaults: userDefaults)
        return descriptors.values
            .filter { model in
                if model.isOfficial { return true }
                return allowCustom
            }
            .sorted { ($0.isOfficial ? 0 : 1, $0.id) < ($1.isOfficial ? 0 : 1, $1.id) }
    }

    // MARK: Policy enforcement

    func validatePolicy(modelID: String, customModelsEnabled: Bool? = nil) throws {
        guard let model = descriptor(id: modelID) else {
            throw ModelPolicyError.modelNotRegistered(modelID: modelID)
        }
        if !model.isOfficial {
            let allowCustom = customModelsEnabled ?? FeatureFlags.isEnabled(.customModelsV1, userDefaults: userDefaults)
            guard allowCustom else {
                throw ModelPolicyError.modelUnverified(modelID: modelID)
            }
        }
    }

    func validateForGeneration(modelID: String, customModelsEnabled: Bool? = nil) throws -> ModelDescriptor {
        try validatePolicy(modelID: modelID, customModelsEnabled: customModelsEnabled)
        guard let model = descriptor(id: modelID) else {
            throw ModelPolicyError.modelNotRegistered(modelID: modelID)
        }
        return model
    }

    func validateForGeneration(request: GenerationRequest, customModelsEnabled: Bool? = nil) throws -> ModelDescriptor {
        let allowCustom = customModelsEnabled ?? (request.customModelsEnabled || FeatureFlags.isEnabled(.customModelsV1, userDefaults: userDefaults))
        try validatePolicy(modelID: request.modelId, customModelsEnabled: allowCustom)
        guard let model = descriptor(for: request) else {
            throw ModelPolicyError.modelNotRegistered(modelID: request.modelId)
        }
        return model
    }
}
