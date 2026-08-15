import Foundation
@testable import LTXVideoGeneratorCore

func runLTX25ModelSupportTests(_ t: TestKit) {
    t.suite("LTX-2.5 Model Support & Capabilities") {
        // MARK: - A. LTX-2.3 default stability
        t.checkEqual(LTXModelCatalog.defaultModelID, "ltx23_distilled_q4", "default model must be ltx23_distilled_q4")
        let resolvedDefault = GenerationModelResolver.resolve(modelID: nil)
        if case .runnable(let runnable) = resolvedDefault {
            t.checkEqual(runnable.model.id, "ltx23_distilled_q4", "default runnable must be ltx23_distilled_q4")
            t.checkEqual(runnable.backend, .mlxVideoWithAudio, "default backend must be mlxVideoWithAudio")
        } else {
            t.check(false, "nil modelID must resolve to runnable default model")
        }

        // MARK: - B. LTX-2.5 registration & capabilities
        let ltx25Opt = LTX25ModelCatalog.model(id: LTX25ModelCatalog.ltx25ExperimentalID)
        t.check(ltx25Opt != nil, "LTX25ModelCatalog must contain ltx25_experimental")
        if let ltx25 = ltx25Opt {
            t.checkEqual(ltx25.displayName, "LTX-2.5 (Experimental)", "display name must be LTX-2.5 (Experimental)")
            t.checkEqual(ltx25.repo, "Lightricks/LTX-2.5", "repo must be Lightricks/LTX-2.5")
            t.check(!ltx25.supportsBuiltInAudio, "initial audio capability must be false")
        }

        let registry = ModelRegistry.shared
        let descOpt = registry.descriptor(id: LTX25ModelCatalog.ltx25ExperimentalID)
        t.check(descOpt != nil, "ModelRegistry must contain ltx25_experimental descriptor")
        if let desc = descOpt {
            t.checkEqual(desc.architecture.modelVersion, "2.5", "architecture version must be 2.5")
            t.checkEqual(desc.architecture.modelFamily, "LTX", "architecture family must be LTX")
            t.check(desc.capabilities.textToVideo, "must support T2V")
            t.check(desc.capabilities.imageToVideo, "must support I2V")
            t.check(desc.capabilities.keyframes, "must support keyframes")
            t.check(desc.capabilities.continuation, "must support continuation")
            t.checkEqual(desc.runtime.backend, "ltx-2-mlx", "backend must be ltx-2-mlx")
        }

        // MARK: - C. GenerationModelResolver no silent fallback
        let resolved25 = GenerationModelResolver.resolve(modelID: LTX25ModelCatalog.ltx25ExperimentalID)
        if case .runnable(let runnable) = resolved25 {
            t.checkEqual(runnable.model.id, LTX25ModelCatalog.ltx25ExperimentalID, "must resolve exact 2.5 model")
            t.checkEqual(runnable.backend, .ltx2MLX, "must route to ltx2MLX backend")
            t.check(runnable.model.id != LTXModelCatalog.defaultModelID, "must never silently fallback to 2.3")
        } else {
            t.check(false, "ltx25_experimental must resolve to runnable")
        }

        // MARK: - D. LTX2MLXBackend argument generation
        var params = GenerationParameters.default
        params.width = 768
        params.height = 512
        params.numFrames = 73
        params.fps = 24
        params.seed = 42

        let requestT2V = GenerationRequest(
            prompt: "A cinematic shot of a sunset over the ocean",
            modelId: LTX25ModelCatalog.ltx25ExperimentalID,
            parameters: params
        )
        let argsT2V = LTX2MLXBackend.arguments(
            request: requestT2V,
            modelDirectory: "/path/to/ltx25",
            outputPath: "/path/to/out.mp4",
            seed: 42,
            width: 768,
            height: 512
        )
        t.check(argsT2V.contains("--model") && argsT2V.contains("/path/to/ltx25"), "args must contain model path")
        t.check(argsT2V.contains("--width") && argsT2V.contains("768"), "args must contain width")
        t.check(argsT2V.contains("--height") && argsT2V.contains("512"), "args must contain height")
        t.check(argsT2V.contains("--frames") && argsT2V.contains("73"), "args must contain frames")
        t.check(argsT2V.contains("--distilled"), "args must contain --distilled")
        t.check(!argsT2V.contains("--image"), "T2V must not contain --image")

        let requestI2V = GenerationRequest(
            prompt: "A cinematic shot of a sunset over the ocean",
            sourceImagePath: "/path/to/frame.png",
            modelId: LTX25ModelCatalog.ltx25ExperimentalID,
            parameters: params
        )
        let argsI2V = LTX2MLXBackend.arguments(
            request: requestI2V,
            modelDirectory: "/path/to/ltx25",
            outputPath: "/path/to/out.mp4",
            seed: 42,
            width: 768,
            height: 512
        )
        t.check(argsI2V.contains("--image") && argsI2V.contains("/path/to/frame.png"), "I2V must contain --image")

        // MARK: - E. ActiveModelDisplayResolver
        let display = ActiveModelDisplayResolver.resolve(modelID: LTX25ModelCatalog.ltx25ExperimentalID)
        t.checkEqual(display.displayName, "LTX-2.5 (Experimental)", "display name must match")
        t.checkEqual(display.backendBadge, "ltx-2-mlx", "backend badge must be ltx-2-mlx")
        t.checkEqual(display.modelID, LTX25ModelCatalog.ltx25ExperimentalID, "model ID must match")

        // MARK: - F. Auto Movie strict previous-take continuity
        let store = FilmProjectStore.shared
        let projectID = UUID()
        var project = FilmProject(id: projectID, title: "LTX-2.5 Continuity Test")
        project.workflowMode = "hybrid"

        var shot1 = Shot(index: 0, title: "Shot 1")
        shot1.summary = "Elena enters the room."
        shot1.continuityMode = .cut

        var shot2 = Shot(index: 1, title: "Shot 2")
        shot2.summary = "Elena walks to the window."
        shot2.continuityMode = .continueFromPrevious

        project.shots = [shot1, shot2]
        store.save(project)
        defer { store.delete(projectID) }

        let coordinator = AutoMovieRunCoordinator(store: store)
        let mode1 = coordinator.autoMovieContinuityMode(forShotAt: 0, in: project)
        let mode2 = coordinator.autoMovieContinuityMode(forShotAt: 1, in: project)

        t.checkEqual(mode1, .cut, "Shot 1 in Auto Movie must be cut (or opening)")
        t.checkEqual(mode2, .continueFromPrevious, "Shot 2+ in Auto Movie must strictly be continueFromPrevious")

        // MARK: - G. StorageHealthService with LTX-2.5 download estimate
        struct MockDiskProvider: DiskCapacityProviding {
            let capacity: Int64
            func availableCapacity(for url: URL) -> Int64? { capacity }
        }

        // 30 GB available: healthy for a 25 GB download
        let serviceHealthy = StorageHealthService(capacityProvider: MockDiskProvider(capacity: 30 * 1024 * 1024 * 1024))
        let statusHealthy = serviceHealthy.check(url: URL(fileURLWithPath: "/tmp"), for: .modelDownload(expectedBytes: 25 * 1024 * 1024 * 1024))
        t.check(!statusHealthy.isBlocked, "30GB should be healthy for 25GB download")

        // 20 GB available: critical for a 25 GB download
        let serviceCritical = StorageHealthService(capacityProvider: MockDiskProvider(capacity: 20 * 1024 * 1024 * 1024))
        let statusCritical = serviceCritical.check(url: URL(fileURLWithPath: "/tmp"), for: .modelDownload(expectedBytes: 25 * 1024 * 1024 * 1024))
        t.check(statusCritical.isBlocked, "20GB should block a 25GB download")
    }
}
