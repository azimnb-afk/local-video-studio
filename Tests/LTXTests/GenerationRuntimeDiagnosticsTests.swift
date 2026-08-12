import Foundation
@testable import LTXVideoGeneratorCore

func runGenerationRuntimeDiagnosticsTests(_ t: TestKit) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("LTXTests-runtime-diagnostics-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    struct Context {
        let store: FilmProjectStore
        let projectID: UUID
        let shotID: UUID
        let takeID: UUID
        let request: GenerationRequest
    }

    func makeContext(_ name: String) -> Context {
        let store = FilmProjectStore(projectsDirectory: root.appendingPathComponent(name, isDirectory: true))
        var project = FilmProject(title: name)
        var shot = Shot(index: 0, title: "Runtime diagnostics")
        shot.compiledPrompt = "A test subject walks through a doorway."
        let requestID = UUID()
        var parameters = GenerationParameters.default
        // The 64-pixel floor makes requested and effective resolution distinct
        // without changing any resolver policy.
        parameters.width = 768
        parameters.height = 1080
        parameters.numFrames = 121
        parameters.fps = 24
        let take = Take(
            shotID: shot.id,
            modelID: "acceptance-fixture",
            seed: 42,
            promptSnapshot: shot.compiledPrompt,
            settingsSnapshot: parameters,
            requestedWidth: parameters.width,
            requestedHeight: parameters.height,
            fps: parameters.fps,
            requestedDuration: Double(parameters.numFrames) / Double(parameters.fps),
            status: .queued,
            generationSourceDiagnostics: GenerationSourceDiagnostics(
                requestedContinuityMode: .cut,
                effectiveSource: .none,
                actualVideoMode: .textToVideo,
                sourceFilename: nil,
                sourceProjectRelativePath: nil,
                continuitySourceShotID: nil,
                continuitySourceTakeID: nil,
                continuityTakeSelectionReason: nil,
                refreshAnchorOrigin: nil,
                refreshAnchorSourceShotID: nil,
                refreshAnchorSourceTakeID: nil,
                imagePreparation: nil,
                recordedAt: Date(timeIntervalSinceReferenceDate: 500)
            )
        )
        shot.takes = [take]
        project.shots = [shot]
        let request = GenerationRequest(
            id: requestID,
            prompt: shot.compiledPrompt,
            modelId: take.modelID,
            parameters: parameters,
            filmProjectID: project.id,
            shotID: shot.id,
            takeID: take.id
        )
        project.jobs = [GenerationJob(
            projectID: project.id,
            shotID: shot.id,
            takeID: take.id,
            requestID: request.id
        )]
        store.save(project)
        return Context(
            store: store,
            projectID: project.id,
            shotID: shot.id,
            takeID: take.id,
            request: request
        )
    }

    func take(in context: Context) -> Take? {
        context.store.project(id: context.projectID)?.shots.first?.takes.first
    }

    func fixtureResult(
        context: Context,
        videoPath: String,
        createdAt: Date,
        completedAt: Date
    ) -> GenerationResult {
        var effective = context.request.parameters
        effective.height = 1024
        return GenerationResult(
            id: UUID(),
            requestId: context.request.id,
            prompt: context.request.prompt,
            enhancedPrompt: nil,
            negativePrompt: "",
            voiceoverText: "",
            voiceoverSource: "mlx-audio",
            voiceoverVoice: "af_heart",
            modelId: context.request.modelId,
            parameters: effective,
            videoPath: videoPath,
            thumbnailPath: nil,
            audioPath: nil,
            musicPath: nil,
            musicGenre: nil,
            sourceImagePath: nil,
            createdAt: createdAt,
            completedAt: completedAt,
            duration: completedAt.timeIntervalSince(createdAt),
            seed: 42,
            requestedWidth: context.request.parameters.width,
            requestedHeight: context.request.parameters.height,
            requestedDurationSeconds: context.request.requestedDurationSeconds,
            effectiveWidth: 768,
            effectiveHeight: 1024,
            filmProjectID: context.projectID,
            shotID: context.shotID,
            takeID: context.takeID
        )
    }

    t.suite("Generation runtime diagnostics — success snapshot and media inspection") {
        let context = makeContext("success")
        let coordinator = TakeGenerationCoordinator(store: context.store)
        let startedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        coordinator.recordExecutionStarted(request: context.request, startedAt: startedAt)

        let running = take(in: context)
        t.checkEqual(running?.status, .generating, "runtime start records existing generating Take state")
        t.checkEqual(running?.generationRuntimeDiagnostics?.status, .running, "runtime start records running status")
        t.checkEqual(running?.generationRuntimeDiagnostics?.startedAt, startedAt, "runtime start timestamp persists")
        t.checkEqual(running?.generationRuntimeDiagnostics?.requestedWidth, 768, "requested width snapshot persists")
        t.checkEqual(running?.generationRuntimeDiagnostics?.requestedHeight, 1080, "requested height snapshot persists")
        t.checkEqual(running?.generationRuntimeDiagnostics?.effectiveHeight, 1024, "effective resolution uses existing 64-pixel floor")
        t.checkEqual(context.store.project(id: context.projectID)?.jobs.first?.state, .running, "job mirrors runtime start")

        let fixture = "/tmp/ltx_baseline/T2V-A-ON.mp4"
        guard FileManager.default.fileExists(atPath: fixture),
              let media = MediaProbe.probe(path: fixture) else {
            t.check(false, "runtime fixture MP4 is readable"); return
        }
        let completedAt = startedAt.addingTimeInterval(12.5)
        coordinator.recordCompletion(
            result: fixtureResult(
                context: context,
                videoPath: fixture,
                createdAt: startedAt,
                completedAt: completedAt
            ),
            finalizedAt: completedAt
        )

        let completed = take(in: context)
        let runtime = completed?.generationRuntimeDiagnostics
        t.checkEqual(completed?.status, .completed, "success records completed Take state")
        t.checkEqual(runtime?.status, .succeeded, "success runtime status persists")
        t.checkEqual(runtime?.elapsedSeconds, 12.5, "elapsed time is execution start through finalization")
        t.checkEqual(runtime?.requestedWidth, 768, "requested resolution stays immutable")
        t.checkEqual(runtime?.requestedHeight, 1080, "requested portrait height stays immutable")
        t.checkEqual(runtime?.effectiveWidth, 768, "effective width persists separately")
        t.checkEqual(runtime?.effectiveHeight, 1024, "effective height persists separately")
        t.checkEqual(runtime?.actualWidth, media.width, "actual width comes from the real MP4")
        t.checkEqual(runtime?.actualHeight, media.height, "actual height comes from the real MP4")
        t.checkEqual(runtime?.actualDurationSeconds, media.durationSeconds, "actual duration comes from the real MP4")
        t.checkEqual(runtime?.actualFPS, media.fps, "actual FPS comes from the real MP4")
        t.checkEqual(runtime?.actualFrameCount, media.frameCount, "actual frame count is only whatever ffprobe reports")
        t.checkEqual(runtime?.requestedFrames, 121, "requested frames persist independently")
        t.checkEqual(runtime?.backendResult, .succeeded, "backend success persists")
        t.check(runtime?.backendExitCode == nil, "successful backend has no synthetic exit code")
        t.checkEqual(runtime?.outputFilename, URL(fileURLWithPath: fixture).lastPathComponent, "output filename persists")
        t.checkEqual(runtime?.outputExists, true, "output exists fact persists")
        t.checkEqual(runtime?.outputMetadataReadable, true, "metadata readability persists")
        t.checkEqual(context.store.project(id: context.projectID)?.jobs.first?.state, .completed, "job mirrors runtime success")

        let sourceBefore = completed?.generationSourceDiagnostics
        let runtimeBefore = runtime
        var edited = context.store.project(id: context.projectID)!
        edited.settings.width = 512
        edited.settings.height = 320
        edited.shots[0].camera.movement = "handheld"
        edited.shots[0].continuityMode = .continueFromPrevious
        edited.shots[0].selectedTakeID = UUID()
        context.store.save(edited)
        let reopened = FilmProjectStore(projectsDirectory: context.store.projectsDirectory)
        let historical = reopened.project(id: context.projectID)?.shots.first?.takes.first
        t.checkEqual(historical?.generationRuntimeDiagnostics, runtimeBefore, "later edits do not mutate old runtime facts")
        t.checkEqual(historical?.generationSourceDiagnostics, sourceBefore, "Phase 1 source provenance remains immutable")
        t.checkEqual(historical?.generationRuntimeDiagnostics?.elapsedSeconds, 12.5, "reopen preserves elapsed time")
    }

    t.suite("Generation runtime diagnostics — failure classification and bounded errors") {
        let context = makeContext("backend-failure")
        let coordinator = TakeGenerationCoordinator(store: context.store)
        let startedAt = Date(timeIntervalSinceReferenceDate: 2_000)
        let failedAt = startedAt.addingTimeInterval(3.25)
        coordinator.recordExecutionStarted(request: context.request, startedAt: startedAt)
        let longError = "Exit code 15. " + String(repeating: "backend stderr detail ", count: 100)
        coordinator.recordFailure(
            request: context.request,
            error: LTXError.generationFailed(longError),
            effectiveParameters: context.request.parameters,
            outputPath: root.appendingPathComponent("missing-output.mp4").path,
            finalizedAt: failedAt
        )
        let runtime = take(in: context)?.generationRuntimeDiagnostics
        t.checkEqual(take(in: context)?.status, .failed, "backend failure marks Take failed")
        t.checkEqual(runtime?.status, .failed, "failure runtime status persists")
        t.checkEqual(runtime?.failureStage, .backendGeneration, "backend failure is distinguished from source preparation")
        t.checkEqual(runtime?.backendResult, .failed, "backend failure result persists")
        t.checkEqual(runtime?.backendExitCode, 15, "backend exit code is extracted when existing error exposes it")
        t.checkEqual(runtime?.elapsedSeconds, 3.25, "failed elapsed time persists")
        t.checkEqual(runtime?.outputExists, false, "missing output is recorded without pretending success")
        t.checkEqual(runtime?.outputMetadataReadable, false, "missing output has no readable metadata")
        t.check((runtime?.errorSummary?.count ?? 0) <= GenerationRuntimeFailureClassifier.maximumErrorSummaryLength + 1,
                "persisted error summary is size capped")
        t.checkEqual(context.store.project(id: context.projectID)?.jobs.first?.state, .failed, "job mirrors runtime failure")
        t.check((context.store.project(id: context.projectID)?.jobs.first?.errorMessage?.count ?? 0) <= GenerationRuntimeFailureClassifier.maximumErrorSummaryLength + 1,
                "job error uses the same concise summary")

        let sourceContext = makeContext("source-preparation")
        let sourceCoordinator = TakeGenerationCoordinator(store: sourceContext.store)
        sourceCoordinator.recordExecutionStarted(
            request: sourceContext.request,
            startedAt: Date(timeIntervalSinceReferenceDate: 3_000)
        )
        sourceCoordinator.recordFailure(
            request: sourceContext.request,
            error: LTXError.generationFailed("Unable to prepare the Starting Image: unreadable source."),
            finalizedAt: Date(timeIntervalSinceReferenceDate: 3_001)
        )
        let sourceRuntime = take(in: sourceContext)?.generationRuntimeDiagnostics
        t.checkEqual(sourceRuntime?.failureStage, .sourcePreparation, "source preparation failure remains distinct")
        t.checkEqual(sourceRuntime?.backendResult, .notStarted, "source preparation does not claim a backend run")

        let missingContext = makeContext("output-missing")
        let missingCoordinator = TakeGenerationCoordinator(store: missingContext.store)
        missingCoordinator.recordExecutionStarted(
            request: missingContext.request,
            startedAt: Date(timeIntervalSinceReferenceDate: 4_000)
        )
        missingCoordinator.recordFailure(
            request: missingContext.request,
            error: LTXError.generationFailed("Output file is missing."),
            stage: .outputMissing,
            finalizedAt: Date(timeIntervalSinceReferenceDate: 4_002)
        )
        t.checkEqual(take(in: missingContext)?.generationRuntimeDiagnostics?.failureStage, .outputMissing,
                     "output missing has its own safe failure stage")

        let unknownContext = makeContext("unknown-failure")
        let unknownCoordinator = TakeGenerationCoordinator(store: unknownContext.store)
        unknownCoordinator.recordExecutionStarted(
            request: unknownContext.request,
            startedAt: Date(timeIntervalSinceReferenceDate: 4_100)
        )
        unknownCoordinator.recordFailure(
            request: unknownContext.request,
            error: NSError(domain: "LTXTests", code: 999, userInfo: [NSLocalizedDescriptionKey: "Unexpected bridge state."]),
            stage: .unknown,
            finalizedAt: Date(timeIntervalSinceReferenceDate: 4_101)
        )
        let unknownRuntime = take(in: unknownContext)?.generationRuntimeDiagnostics
        t.checkEqual(unknownRuntime?.failureStage, .unknown, "unknown failures remain safe and explicit")
        t.checkEqual(unknownRuntime?.backendResult, .unavailable, "unknown failure does not invent a backend result")
    }

    t.suite("Generation runtime diagnostics — corrupt output, cancellation, and legacy") {
        let corruptURL = root.appendingPathComponent("corrupt.mp4")
        try? Data("not an MP4".utf8).write(to: corruptURL)
        let corruptContext = makeContext("corrupt-output")
        let corruptCoordinator = TakeGenerationCoordinator(store: corruptContext.store)
        let startedAt = Date(timeIntervalSinceReferenceDate: 5_000)
        corruptCoordinator.recordExecutionStarted(request: corruptContext.request, startedAt: startedAt)
        corruptCoordinator.recordCompletion(
            result: fixtureResult(
                context: corruptContext,
                videoPath: corruptURL.path,
                createdAt: startedAt,
                completedAt: startedAt.addingTimeInterval(1)
            ),
            finalizedAt: startedAt.addingTimeInterval(1)
        )
        let corruptRuntime = take(in: corruptContext)?.generationRuntimeDiagnostics
        t.checkEqual(corruptRuntime?.outputExists, true, "corrupt output existence is recorded")
        t.checkEqual(corruptRuntime?.outputMetadataReadable, false, "corrupt output is safely marked unreadable")
        t.check(corruptRuntime?.actualFrameCount == nil, "unreadable output never receives a guessed frame count")

        let cancelledContext = makeContext("cancelled")
        let cancelledCoordinator = TakeGenerationCoordinator(store: cancelledContext.store)
        cancelledCoordinator.recordExecutionStarted(
            request: cancelledContext.request,
            startedAt: Date(timeIntervalSinceReferenceDate: 6_000)
        )
        cancelledCoordinator.recordCancellation(
            request: cancelledContext.request,
            finalizedAt: Date(timeIntervalSinceReferenceDate: 6_004)
        )
        let cancelledRuntime = take(in: cancelledContext)?.generationRuntimeDiagnostics
        t.checkEqual(cancelledRuntime?.status, .cancelled, "cancellation records runtime status")
        t.checkEqual(cancelledRuntime?.failureStage, .cancelled, "cancellation uses its existing terminal category")
        t.checkEqual(cancelledRuntime?.elapsedSeconds, 4, "cancellation elapsed time persists")
        t.checkEqual(cancelledContext.store.project(id: cancelledContext.projectID)?.jobs.first?.state, .cancelled,
                     "job mirrors runtime cancellation")

        var modern = Take(
            shotID: UUID(), modelID: "m", seed: 1, promptSnapshot: "p",
            settingsSnapshot: .default, requestedWidth: 768, requestedHeight: 512,
            fps: 24, requestedDuration: 5
        )
        modern.generationRuntimeDiagnostics = GenerationRuntimeDiagnostics(
            status: .succeeded,
            startedAt: Date(),
            finishedAt: Date(),
            elapsedSeconds: 1,
            requestedWidth: 768,
            requestedHeight: 512,
            effectiveWidth: 768,
            effectiveHeight: 512,
            actualWidth: 768,
            actualHeight: 512,
            requestedFrames: 25,
            requestedDurationSeconds: 1,
            actualDurationSeconds: 1,
            actualFPS: 24,
            actualFrameCount: nil,
            backendResult: .succeeded,
            backendExitCode: nil,
            failureStage: nil,
            errorSummary: nil,
            outputFilename: "old.mp4",
            outputExists: true,
            outputMetadataReadable: true
        )
        guard var object = try? JSONSerialization.jsonObject(
            with: JSONEncoder().encode(modern)) as? [String: Any] else {
            t.check(false, "modern runtime Take encodes for legacy simulation"); return
        }
        object.removeValue(forKey: "generationRuntimeDiagnostics")
        guard let legacyData = try? JSONSerialization.data(withJSONObject: object),
              let legacy = try? JSONDecoder().decode(Take.self, from: legacyData) else {
            t.check(false, "legacy Take decodes without runtime diagnostics"); return
        }
        t.check(legacy.generationRuntimeDiagnostics == nil,
                "legacy Take remains runtime diagnostics unavailable")
    }
}
