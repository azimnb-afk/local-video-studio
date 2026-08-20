import Foundation
@testable import LTXVideoGeneratorCore

/// Explicit real-runtime acceptance for the experimental MiniMax H3 renderer.
/// Every mode uses isolated Project/History/Video directories and the same
/// GenerationService/registry/adapter path as the app. Nothing here reads or
/// writes the Personal or Dev Application Support trees.
enum MiniMaxH3AcceptanceHarness {
    private static let endpoint = MiniMaxH3Configuration.defaultEndpoint

    private struct DefaultsSnapshot {
        let endpoint: Any?

        init() {
            endpoint = UserDefaults.standard.object(forKey: MiniMaxH3Configuration.endpointKey)
            UserDefaults.standard.set(
                MiniMaxH3Configuration.defaultEndpoint,
                forKey: MiniMaxH3Configuration.endpointKey)
        }

        func restore() {
            if let endpoint {
                UserDefaults.standard.set(endpoint, forKey: MiniMaxH3Configuration.endpointKey)
            } else {
                UserDefaults.standard.removeObject(forKey: MiniMaxH3Configuration.endpointKey)
            }
        }
    }

    @MainActor
    static func run(mode: String, sourceImagePath: String?) async -> Int32 {
        let defaults = DefaultsSnapshot()
        defer { defaults.restore() }

        let status = await MiniMaxH3RuntimeManager.shared.status(
            snapshot: MiniMaxH3Configuration.Snapshot(
                modelDirectory: nil,
                runtimeExecutablePath: nil,
                endpoint: endpoint))
        print("H3_READY_STATE=\(status.state.rawValue)")
        print("H3_SERVER_OWNERSHIP=\(status.ownership?.rawValue ?? "none")")
        print("H3_LOADED_MODEL=\(status.loadedModelID ?? "none")")
        guard status.isReady,
              status.loadedModelID == MiniMaxH3Configuration.expectedServerModelID else {
            print("FAILED: exact-model H3 runtime is not ready: \(status.detail)")
            return 2
        }

        do {
            switch mode {
            case "normal":
                return try await runDirect(
                    label: "h3-normal", sourceImagePath: nil,
                    duration: 2.3, generationSource: "generate", expectedChain: 1)
            case "i2v":
                let source = try validatedSource(sourceImagePath)
                return try await runDirect(
                    label: "h3-i2v", sourceImagePath: source,
                    duration: 2.3, generationSource: "generate", expectedChain: 1)
            case "oneshot":
                return try await runOneShot()
            case "automovie":
                let source = try validatedSource(sourceImagePath)
                return try await runAutoMovie(sourceImagePath: source)
            case "long":
                let source = try validatedSource(sourceImagePath)
                return try await runDirect(
                    label: "h3-chain4", sourceImagePath: source,
                    duration: 6.0, generationSource: "generate", expectedChain: 4)
            default:
                print("Unknown H3 acceptance mode: \(mode)")
                print("Use: normal | i2v <image> | oneshot | automovie <image> | long <image>")
                return 64
            }
        } catch {
            print("FAILED: \(error.localizedDescription)")
            return 1
        }
    }

    @MainActor
    private static func runDirect(
        label: String,
        sourceImagePath: String?,
        duration: Double,
        generationSource: String,
        expectedChain: Int
    ) async throws -> Int32 {
        let env = V3AcceptanceHarness.makeEnvironment(label: label)
        defer { V3AcceptanceHarness.restoreOutputDir(env) }

        var parameters = GenerationParameters.default
        // Deliberately retain a different requested size so the persisted
        // Requested / Effective / Actual boundary is exercised by real media.
        parameters.width = 768
        parameters.height = 512
        parameters.fps = 24
        parameters.numFrames = PromptCompiler.frameCount(forSeconds: duration, fps: 24)
        parameters.numInferenceSteps = 30
        parameters.seed = 4242

        let request = GenerationRequest(
            prompt: sourceImagePath == nil
                ? "A young man wearing glasses and a dark jacket stands in a softly lit studio. He slowly turns toward the camera while maintaining a relaxed posture. The camera remains still."
                : "The same young man wearing glasses and a dark jacket slowly turns toward the camera while maintaining a relaxed posture. The camera remains still. His face, clothing, hairstyle, background, and lighting remain consistent throughout the shot.",
            sourceImagePath: sourceImagePath,
            disableAudio: false,
            modelId: MiniMaxH3Configuration.modelID,
            parameters: parameters,
            qualityMode: GenerationPreset.standard.qualityMode.rawValue,
            preset: GenerationPreset.standard.rawValue,
            targetDurationSeconds: duration,
            generationSource: generationSource,
            minimaxH3Endpoint: endpoint)

        print("PRODUCTION_PATH=GenerationService->ModelRegistry->AdapterRegistry->MiniMaxH3Adapter->MiniMaxH3Backend")
        print("REQUEST_ID=\(request.id.uuidString)")
        print("REQUESTED=\(parameters.width)x\(parameters.height) duration=\(duration)s audio=on")
        let result = await generate(request: request, environment: env, timeoutSeconds: 3_600)
        guard let result else { return 1 }
        guard validate(
            result: result,
            expectedRequestID: request.id,
            expectedSourcePath: sourceImagePath,
            expectedRequestedDuration: duration,
            expectedChain: expectedChain) else { return 1 }

        let reopenedHistory = HistoryManager(rootDirectory: env.tmpDir.appendingPathComponent("History"))
        reopenedHistory.loadInitialData()
        guard let reopened = reopenedHistory.results.first(where: { $0.requestId == request.id }),
              reopened.backendKind == GenerationBackendKind.minimaxH3.rawValue,
              reopened.effectiveChainWindows == expectedChain else {
            print("FAILED: persisted History did not reopen with the H3 snapshot")
            return 1
        }
        print("ARCHIVE_REOPEN=PASS")
        printArchive(result)
        print("EVIDENCE_DIR=\(env.tmpDir.path)")
        return 0
    }

    @MainActor
    private static func runOneShot() async throws -> Int32 {
        let env = V3AcceptanceHarness.makeEnvironment(label: "h3-oneshot")
        defer { V3AcceptanceHarness.restoreOutputDir(env) }

        var parameters = GenerationParameters.default
        parameters.width = 768
        parameters.height = 512
        parameters.fps = 24
        parameters.seed = 5151
        let brief = "A woman in a blue coat stands in a quiet railway station, slowly looks toward the arriving train, and comes to a natural stop. The camera remains still."
        let base = GenerationRequest(
            prompt: brief,
            brief: brief,
            disableAudio: false,
            modelId: MiniMaxH3Configuration.modelID,
            parameters: parameters,
            qualityMode: GenerationPreset.standard.qualityMode.rawValue,
            preset: GenerationPreset.standard.rawValue,
            targetDurationSeconds: 2.3,
            generationSource: "oneShot",
            minimaxH3Endpoint: endpoint)
        let director = LocalDirector(providers: [TemplateDirectorProvider()])
        let planned = try await director.makeRequest(brief: brief, base: base)
        print("DIRECTOR=\(planned.providerName)")
        print("PLAN_ACTION=\(planned.plan.action)")
        print("H3_COMPILED_PROMPT=\(planned.request.prompt)")
        let result = await generate(
            request: planned.request, environment: env, timeoutSeconds: 3_600)
        guard let result,
              validate(
                result: result,
                expectedRequestID: planned.request.id,
                expectedSourcePath: nil,
                expectedRequestedDuration: 2.3,
                expectedChain: 1) else { return 1 }
        printArchive(result)
        print("EVIDENCE_DIR=\(env.tmpDir.path)")
        return 0
    }

    @MainActor
    private static func runAutoMovie(sourceImagePath: String) async throws -> Int32 {
        let env = V3AcceptanceHarness.makeEnvironment(label: "h3-automovie")
        defer { V3AcceptanceHarness.restoreOutputDir(env) }

        let settings = ProjectSettings(
            modelID: MiniMaxH3Configuration.modelID,
            textEncoderID: LTXTextEncoderCatalog.defaultTextEncoderID,
            qualityMode: GenerationPreset.standard.qualityMode.rawValue,
            preset: GenerationPreset.standard.rawValue,
            width: 768,
            height: 512,
            fps: 24,
            audioEnabled: true,
            targetDurationSeconds: 10)
        let storyboardDirector = StoryboardDirector(
            providers: [TemplateStoryboardProvider()], requestedMode: .basic)
        let planner = HybridProjectCoordinator(director: storyboardDirector)
        let brief = "A young man wearing glasses and a dark jacket stands in a softly lit studio. First, he slowly turns toward the camera. Next, he relaxes his shoulders and comes to a natural stop. Keep the same person, clothing, background, and lighting. About 10 seconds, one continuous scene."
        var (project, violations, provider) = try await planner.makeProject(
            title: "H3 Auto Movie Acceptance", brief: brief, settings: settings)
        print("DIRECTOR=\(provider)")
        print("PLANNED_SHOTS=\(project.shots.count)")
        print("PLAN_VIOLATIONS=\(violations.count)")
        guard project.shots.count == 2 else {
            print("FAILED: deterministic Basic Director acceptance expected 2 shots")
            return 1
        }

        // Shot 1 has no previous shot to cut away from, so the established
        // product entry point is Opening Reference (not New Start Frame,
        // which intentionally applies only to later explicit Cuts).
        project.openingReferenceImage = try env.store.importOpeningReferenceImage(
            from: URL(fileURLWithPath: sourceImagePath), projectID: project.id)
        project.shots[0].continuityMode = .cut
        project.shots[1].continuityMode = .continueFromPrevious
        env.store.save(project)

        var outputs: [String] = []
        for index in 0..<2 {
            let generated = await V3AcceptanceHarness.generateNextShot(
                env: env,
                projectID: project.id,
                label: "H3 AUTO MOVIE SHOT \(index + 1)",
                timeoutSeconds: 3_600)
            guard let path = generated.videoPath else { return 1 }
            outputs.append(path)
        }

        env.coordinator.autoSelectUnambiguousTakes(projectID: project.id)
        guard let finalProject = env.store.project(id: project.id) else {
            print("FAILED: Auto Movie project did not persist")
            return 1
        }
        guard finalProject.shots.count == 2,
              let firstTake = finalProject.shots[0].selectedTake,
              let secondTake = finalProject.shots[1].selectedTake else {
            print("FAILED: generated Takes were not selected")
            return 1
        }
        guard firstTake.modelID == MiniMaxH3Configuration.modelID,
              secondTake.modelID == MiniMaxH3Configuration.modelID,
              secondTake.generationSourceDiagnostics?.effectiveSource == .inheritedLastFrame,
              secondTake.generationSourceDiagnostics?.continuitySourceTakeID == firstTake.id,
              secondTake.sourceImagePath != nil else {
            print("FAILED: H3 Continue did not inherit Shot 1's selected final frame")
            return 1
        }

        let finalDirectory = env.tmpDir.appendingPathComponent("Final", isDirectory: true)
        try FileManager.default.createDirectory(at: finalDirectory, withIntermediateDirectories: true)
        let finalPath = finalDirectory.appendingPathComponent("h3_auto_movie.mp4").path
        let info = try FinalAssemblyService.assemble(
            project: finalProject, outputPath: finalPath, store: env.store)
        guard FileManager.default.fileExists(atPath: finalPath),
              info.durationSeconds != nil else {
            print("FAILED: Final Assembly produced no readable movie")
            return 1
        }

        print("SHOT_1_OUTPUT=\(outputs[0])")
        print("SHOT_1_CHAIN=\(firstTake.generationRuntimeDiagnostics?.effectiveChainWindows ?? -1)")
        print("SHOT_2_OUTPUT=\(outputs[1])")
        print("SHOT_2_CHAIN=\(secondTake.generationRuntimeDiagnostics?.effectiveChainWindows ?? -1)")
        print("SHOT_2_SOURCE=\(secondTake.generationSourceDiagnostics?.effectiveSource.rawValue ?? "none")")
        print("SHOT_2_SOURCE_TAKE=\(secondTake.generationSourceDiagnostics?.continuitySourceTakeID?.uuidString ?? "none")")
        print("FINAL_ASSEMBLY=\(finalPath)")
        print("FINAL_DURATION=\(info.durationSeconds ?? -1)")
        print("EVIDENCE_DIR=\(env.tmpDir.path)")
        return 0
    }

    @MainActor
    private static func generate(
        request: GenerationRequest,
        environment: V3AcceptanceHarness.Environment,
        timeoutSeconds: Double
    ) async -> GenerationResult? {
        let started = Date()
        environment.generationService.addToQueue(request)
        while Date().timeIntervalSince(started) < timeoutSeconds {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if !environment.generationService.isProcessing,
               environment.generationService.queue.isEmpty { break }
            if Int(Date().timeIntervalSince(started)) % 60 == 0 {
                print("WAITING elapsed=\(Int(Date().timeIntervalSince(started)))s status=\(environment.generationService.statusMessage)")
            }
        }
        guard let result = environment.historyManager.results.first(where: { $0.requestId == request.id }) else {
            print("FAILED: no GenerationResult; service error=\(String(describing: environment.generationService.error))")
            return nil
        }
        print("GENERATION_ELAPSED=\(String(format: "%.3f", Date().timeIntervalSince(started)))")
        return result
    }

    private static func validate(
        result: GenerationResult,
        expectedRequestID: UUID,
        expectedSourcePath: String?,
        expectedRequestedDuration: Double,
        expectedChain: Int
    ) -> Bool {
        let info = MediaProbe.probe(path: result.videoPath)
        let valid = result.requestId == expectedRequestID
            && result.modelId == MiniMaxH3Configuration.modelID
            && result.backendKind == GenerationBackendKind.minimaxH3.rawValue
            && abs((result.requestedDurationSeconds ?? -1) - expectedRequestedDuration) < 0.000_001
            && result.effectiveWidth == 512
            && result.effectiveHeight == 288
            && result.effectiveChainWindows == expectedChain
            && result.actualWidth == 512
            && result.actualHeight == 288
            && result.actualFrameCount == result.effectiveFrameCount
            && result.sourceImagePath == expectedSourcePath
            && FileManager.default.fileExists(atPath: result.videoPath)
            && info?.videoCodec == "h264"
            && info?.hasAudio == true
        if !valid {
            print("FAILED: real output/archive validation did not satisfy H3 contract")
            printArchive(result)
            print("MEDIA=\(String(describing: info))")
        }
        return valid
    }

    private static func printArchive(_ result: GenerationResult) {
        print("ARCHIVE_MODEL_ID=\(result.modelId)")
        print("ARCHIVE_BACKEND=\(result.backendKind ?? "none")")
        print("ARCHIVE_REQUESTED=\(result.requestedWidth ?? -1)x\(result.requestedHeight ?? -1) duration=\(result.requestedDurationSeconds ?? -1)")
        print("ARCHIVE_EFFECTIVE=\(result.effectiveWidth ?? -1)x\(result.effectiveHeight ?? -1) frames=\(result.effectiveFrameCount ?? -1) chain=\(result.effectiveChainWindows ?? -1)")
        print("ARCHIVE_ACTUAL=\(result.actualWidth ?? -1)x\(result.actualHeight ?? -1) fps=\(result.actualFPS ?? -1) frames=\(result.actualFrameCount ?? -1) duration=\(result.actualDuration ?? -1)")
        print("ARCHIVE_AUDIO=\(result.audioEnabled == true ? "on" : "off")")
        print("ARCHIVE_SEED=\(result.seed)")
        print("OUTPUT=\(result.videoPath)")
    }

    private static func validatedSource(_ path: String?) throws -> String {
        guard let path, !path.isEmpty,
              FileManager.default.fileExists(atPath: path) else {
            throw NSError(
                domain: "MiniMaxH3Acceptance", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "A readable source image path is required."])
        }
        return path
    }
}
