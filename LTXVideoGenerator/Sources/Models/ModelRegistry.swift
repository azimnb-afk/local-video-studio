import Foundation

// MARK: - Classification / policy

enum ContentClassification: String, Codable {
    case general
    case adultVerified
    case unknown
    case blocked
}

struct PolicyMetadata: Codable, Equatable, Hashable {
    var contentClassification: ContentClassification
    /// Evidence for the classification (model card language, upstream statement).
    var classificationEvidence: String?

    static let general = PolicyMetadata(contentClassification: .general, classificationEvidence: nil)
}

enum ModelPolicyError: Error, Equatable {
    case adultModelRequiresAdultMode(modelID: String)
    case unknownClassificationRejected(modelID: String)
    case blockedModel(modelID: String)
    case modelNotRegistered(modelID: String)
    case modelUnverified(modelID: String)

    var userMessage: String {
        switch self {
        case .adultModelRequiresAdultMode(let id):
            return "Model '\(id)' is adult-verified. Enable Adult Content Mode in Preferences to use it."
        case .unknownClassificationRejected(let id):
            return "Model '\(id)' has an unknown content classification and cannot be used."
        case .blockedModel(let id):
            return "Model '\(id)' is blocked."
        case .modelNotRegistered(let id):
            return "Model '\(id)' is not in the model registry."
        case .modelUnverified(let id):
            return "Model '\(id)' has not passed runtime verification yet (Compatibility Lab)."
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
    // Advanced capabilities default false; only set true after backend runtime
    // verification (capability-driven UI/API — never assume from upstream LTX).
    var keyframes: Bool = false
    var firstLastFrame: Bool = false
    var continuation: Bool = false
    var lora: Bool = false
    var upscale: Bool = false
}

struct RuntimeCompatibility: Codable, Equatable, Hashable {
    /// Backend the model is packaged for.
    var backend: String            // "mlx-video-with-audio"
    var minimumBackendVersion: String?
    /// True only after the full verification gate has passed on this backend.
    var verified: Bool
    var verificationNotes: String?
}

struct ModelLicenseMetadata: Codable, Equatable, Hashable {
    var name: String               // "LTX-2 Community License", "unknown"
    var url: String?
    /// Explicit user acknowledgement recorded at install time.
    var requiresAcknowledgement: Bool
}

struct ModelArtifact: Codable, Equatable, Hashable {
    var path: String               // repo-relative
    var kind: String               // "transformer", "vae", "text-encoder", "config", "audio"
    var sizeBytes: Int64?
    var sha256: String?
}

// MARK: - Descriptor

struct ModelDescriptor: Identifiable, Codable, Equatable, Hashable {
    let id: String
    var displayName: String
    var repository: String
    /// Pinned revision (commit hash or tag). nil = unpinned (not verifiable).
    var revision: String?
    /// Local snapshot path when installed outside the HF cache.
    var localPath: String?

    var quantization: String?      // "q4", "q8", "bf16"
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

// MARK: - Registry

/// Registry of known models. Official models mirror LTXModelCatalog (the legacy
/// source of truth for the fast path) and are always available; derived/lab
/// models appear only behind feature flags and are policy-gated.
final class ModelRegistry {
    static let shared = ModelRegistry()

    static let adultModeUserDefaultsKey = "adultContentModeEnabled"

    private(set) var descriptors: [String: ModelDescriptor] = [:]
    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        seedOfficialModels()
        seedLabModels()
    }

    var adultModeEnabled: Bool {
        userDefaults.bool(forKey: Self.adultModeUserDefaultsKey)
    }

    // MARK: Seeding

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
                revision: nil,  // Official models track upstream main; pinning is a future install-record concern.
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
                    verificationNotes: "Official catalog model; working fast path (Phase 0 baseline)."
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

    /// Compatibility-lab (derived) models. verified=false until the Phase 2
    /// verification gate passes at runtime on this backend. Never auto-downloaded.
    private func seedLabModels() {
        let tenErosLicense = ModelLicenseMetadata(
            name: "ltx-2-license (per MLXBits metadata) — verify before production",
            url: "https://huggingface.co/MLXBits/ltx-2.3-10eros-v1.2-mlx-q8",
            requiresAcknowledgement: true
        )
        descriptors["10eros_v12_q8"] = ModelDescriptor(
            id: "10eros_v12_q8",
            displayName: "10Eros v1.2 MLX Q8 (Lab — unverified)",
            repository: "MLXBits/ltx-2.3-10eros-v1.2-mlx-q8",
            revision: nil,  // Must be pinned during install before verification can pass.
            localPath: nil,
            quantization: "q8",
            precision: nil,
            estimatedModelSizeGB: 26,
            recommendedUnifiedMemoryGB: 48,
            minimumUnifiedMemoryGB: 32,
            architecture: ArchitectureDescriptor(modelFamily: "LTX", modelVersion: "2.3", modelType: "unified-av"),
            capabilities: CapabilitySet(textToVideo: true, imageToVideo: true, synchronizedAudio: true),
            runtime: RuntimeCompatibility(
                backend: "mlx-video-with-audio",
                minimumBackendVersion: nil,
                verified: false,
                verificationNotes: "Packaged for dgrauet/ltx-2-mlx; direct compatibility with mlx-video-with-audio is UNVERIFIED."
            ),
            policy: PolicyMetadata(
                contentClassification: .adultVerified,
                classificationEvidence: "Upstream 10Eros model card describes adult-content finetune (Deep Research)."
            ),
            license: tenErosLicense
        )
        descriptors["10eros_v13_dmd_q4"] = ModelDescriptor(
            id: "10eros_v13_dmd_q4",
            displayName: "10Eros v1.3 DMD MLX Q4 (Lab — unverified)",
            repository: "MLXBits/ltx-2.3-10eros-v1.3-dmd-mlx-q4",
            revision: nil,
            localPath: nil,
            quantization: "q4",
            precision: nil,
            estimatedModelSizeGB: 14,
            recommendedUnifiedMemoryGB: 32,
            minimumUnifiedMemoryGB: 24,
            architecture: ArchitectureDescriptor(modelFamily: "LTX", modelVersion: "2.3", modelType: "unified-av"),
            capabilities: CapabilitySet(textToVideo: true, imageToVideo: true, synchronizedAudio: true),
            runtime: RuntimeCompatibility(
                backend: "mlx-video-with-audio",
                minimumBackendVersion: nil,
                verified: false,
                verificationNotes: "Packaged for dgrauet/ltx-2-mlx; direct compatibility with mlx-video-with-audio is UNVERIFIED."
            ),
            policy: PolicyMetadata(
                contentClassification: .adultVerified,
                classificationEvidence: "Upstream 10Eros model card describes adult-content finetune (Deep Research)."
            ),
            license: tenErosLicense
        )
    }

    // MARK: Lookup

    func descriptor(id: String) -> ModelDescriptor? {
        descriptors[id]
    }

    /// Promotes/demotes derived-model verification from Compatibility Lab
    /// reports. Official models are never demoted here.
    func refreshVerification(from lab: CompatibilityLab) {
        for (id, model) in descriptors where !model.isOfficial {
            descriptors[id]?.runtime.verified = lab.isVerified(modelID: id)
        }
    }

    /// Models visible for selection given flags and the adult-mode setting.
    /// - Official models are always listed.
    /// - Derived (lab) models require derivedModelsV1; adult-classified ones
    ///   additionally require adultModelsV1 + Adult Content Mode ON.
    func selectableModels(adultMode: Bool? = nil) -> [ModelDescriptor] {
        let adult = adultMode ?? adultModeEnabled
        return descriptors.values
            .filter { model in
                if model.isOfficial { return true }
                guard FeatureFlags.isEnabled(.derivedModelsV1, userDefaults: userDefaults) else { return false }
                switch model.policy.contentClassification {
                case .general:
                    return true
                case .adultVerified:
                    return adult && FeatureFlags.isEnabled(.adultModelsV1, userDefaults: userDefaults)
                case .unknown, .blocked:
                    return false
                }
            }
            .sorted { ($0.isOfficial ? 0 : 1, $0.id) < ($1.isOfficial ? 0 : 1, $1.id) }
    }

    // MARK: Policy enforcement

    /// Full policy matrix. Enforced at Service and API layers, not just UI.
    ///
    ///     adultMode=false + general       = allowed
    ///     adultMode=false + adultVerified = reject
    ///     adultMode=true  + adultVerified = allowed
    ///     adultMode=true  + unknown       = reject
    ///     blocked                          = always reject
    func validatePolicy(modelID: String, adultMode: Bool? = nil) throws {
        guard let model = descriptors[modelID] else {
            throw ModelPolicyError.modelNotRegistered(modelID: modelID)
        }
        let adult = adultMode ?? adultModeEnabled
        switch model.policy.contentClassification {
        case .general:
            return
        case .adultVerified:
            guard adult else {
                throw ModelPolicyError.adultModelRequiresAdultMode(modelID: modelID)
            }
        case .unknown:
            throw ModelPolicyError.unknownClassificationRejected(modelID: modelID)
        case .blocked:
            throw ModelPolicyError.blockedModel(modelID: modelID)
        }
    }

    /// Policy + runtime verification. A non-verified model may never generate.
    func validateForGeneration(modelID: String, adultMode: Bool? = nil) throws -> ModelDescriptor {
        try validatePolicy(modelID: modelID, adultMode: adultMode)
        guard let model = descriptors[modelID] else {
            throw ModelPolicyError.modelNotRegistered(modelID: modelID)
        }
        guard model.runtime.verified else {
            throw ModelPolicyError.modelUnverified(modelID: modelID)
        }
        return model
    }
}
