import Foundation

/// Resolves display metadata for the active generation model shown in the sidebar.
/// This reflects the model selected for NEW generations and updates in real time
/// when the user changes the active model in Preferences, Generate, or One Shot.
enum ActiveModelDisplayResolver {

    struct DisplayInfo: Equatable {
        let modelID: String
        let displayName: String
        let backendBadge: String
        let isCustom: Bool
        let isReady: Bool
        let statusText: String
    }

    /// Resolves display info for a model ID.
    /// Never falls back to a silent default when a custom model is selected.
    /// Never exposes private local file paths, private repository IDs, or third-party brand strings.
    static func resolve(
        modelID: String?,
        generationServiceLoaded: Bool = false,
        userDefaults: UserDefaults = .standard
    ) -> DisplayInfo {
        let effectiveID = (modelID == nil || modelID!.isEmpty)
            ? LTXModelCatalog.defaultModelID
            : modelID!

        if effectiveID == ModelRegistry.customModelID {
            let readiness = LTX2MLXRuntime.readiness(userDefaults: userDefaults)
            let status = readiness.canGenerate ? "Ready" : "Not Configured"
            return DisplayInfo(
                modelID: effectiveID,
                displayName: "Custom LTX-2 MLX Model",
                backendBadge: "ltx-2-mlx",
                isCustom: true,
                isReady: readiness.canGenerate,
                statusText: status
            )
        }

        if MiniMaxH3Configuration.isMiniMaxH3(modelID: effectiveID) {
            let isHQ = effectiveID == MiniMaxH3Configuration.highQualityModelID
            let raw = userDefaults.string(forKey: MiniMaxH3Configuration.lastReadinessStateKey)
            let state = raw.flatMap(MiniMaxH3RuntimeState.init(rawValue:)) ?? .notConfigured
            let recordedModelID = userDefaults.string(forKey: MiniMaxH3Configuration.lastReadinessModelIDKey)
            let modelMatches = recordedModelID == effectiveID
            let ready = state == .ready && modelMatches
            let status: String
            if let recordedModelID, recordedModelID != effectiveID {
                status = "Wrong Model"
            } else if state == .ready && recordedModelID == nil {
                status = "Not Configured"
            } else {
                switch state {
                case .notConfigured: status = "Not Configured"
                case .notRunning: status = "Stopped"
                case .starting: status = "Starting"
                case .ready: status = "Ready"
                case .wrongModel: status = "Wrong Model"
                case .failed, .broken: status = "Failed"
                }
            }
            return DisplayInfo(
                modelID: effectiveID,
                displayName: isHQ ? MiniMaxH3Configuration.highQualityDisplayName : MiniMaxH3Configuration.standardDisplayName,
                backendBadge: isHQ ? "H3 · High Quality" : "H3 · Standard",
                isCustom: false,
                isReady: ready,
                statusText: status
            )
        }

        if let profile = CustomModelProfileStore.profile(forModelID: effectiveID, userDefaults: userDefaults) {
            let runtimeReadiness = LTX2MLXRuntime.runtimeReadiness(userDefaults: userDefaults)
            let modelReadiness = CustomModelProfileStore.readiness(for: profile, userDefaults: userDefaults)
            let canGenerate = runtimeReadiness.isReady && modelReadiness.isReady
            let status = canGenerate ? "Ready" : "Not Configured"
            return DisplayInfo(
                modelID: effectiveID,
                displayName: profile.displayName,
                backendBadge: profile.runtimeKind,
                isCustom: true,
                isReady: canGenerate,
                statusText: status
            )
        }

        if let ltx25 = LTX25ModelCatalog.model(id: effectiveID) {
            let readiness = LTX2MLXRuntime.readiness(repository: ltx25.repo, userDefaults: userDefaults)
            let status = readiness.canGenerate ? "Ready" : "Not Configured"
            return DisplayInfo(
                modelID: effectiveID,
                displayName: ltx25.displayName,
                backendBadge: "ltx-2-mlx",
                isCustom: false,
                isReady: readiness.canGenerate,
                statusText: status
            )
        }

        if let official = LTXModelCatalog.model(id: effectiveID) {
            let status = generationServiceLoaded ? "Environment Ready" : "Environment Not Ready"
            return DisplayInfo(
                modelID: effectiveID,
                displayName: official.displayName,
                backendBadge: "MLX",
                isCustom: false,
                isReady: generationServiceLoaded,
                statusText: status
            )
        }

        // Registry lookup for generic registered models
        let registry = ModelRegistry(userDefaults: userDefaults)
        if let descriptor = registry.descriptor(id: effectiveID) {
            let badge = descriptor.runtime.backend == "ltx-2-mlx" ? "ltx-2-mlx" : "MLX"
            return DisplayInfo(
                modelID: effectiveID,
                displayName: descriptor.displayName,
                backendBadge: badge,
                isCustom: !descriptor.isOfficial,
                isReady: false,
                statusText: "Not Ready"
            )
        }

        return DisplayInfo(
            modelID: effectiveID,
            displayName: LTXModelCatalog.defaultModel.displayName,
            backendBadge: "MLX",
            isCustom: false,
            isReady: generationServiceLoaded,
            statusText: generationServiceLoaded ? "Environment Ready" : "Environment Not Ready"
        )
    }
}
