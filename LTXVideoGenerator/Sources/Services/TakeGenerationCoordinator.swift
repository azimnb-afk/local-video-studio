import Foundation

/// Builds and tracks take generations for a shot. 1–20 takes per shot, each a
/// different seed, ALWAYS sequential: requests go through the single-flight
/// GenerationService queue — this type never runs generations itself.
final class TakeGenerationCoordinator {

    static let maxTakesPerShot = 20

    enum CoordinatorError: Error, Equatable, LocalizedError {
        case invalidTakeCount(Int)
        case shotNotFound(UUID)
        case startingImageNotFound(UUID)
        case startingImageUnavailable(UUID)
        case continuityImageUnavailable(UUID)
        case characterAnchorUnavailable(CharacterAnchorIssue)
        case openingReferenceUnavailable(OpeningReferenceIssue)

        var errorDescription: String? {
            switch self {
            case .invalidTakeCount(let count):
                return "Invalid take count (\(count))."
            case .shotNotFound(let id):
                return "Shot (\(id.uuidString.prefix(6))) not found."
            case .startingImageNotFound(let id):
                return "Selected starting image asset (\(id.uuidString.prefix(6))) not found in project."
            case .startingImageUnavailable(let id):
                return "Selected starting image file for asset (\(id.uuidString.prefix(6))) is unavailable on disk."
            case .continuityImageUnavailable(let id):
                return "Shot (\(id.uuidString.prefix(6))) should continue from the previous shot, but its inherited starting frame is unavailable. Retry the shot or switch it to Cut."
            case .characterAnchorUnavailable(let issue):
                return "Character Anchor cannot be used: \(issue.message) Choose another reference or turn the anchor off."
            case .openingReferenceUnavailable(let issue):
                return "Opening Reference Image cannot be used: \(issue.message) Choose another image or clear it."
            }
        }
    }

    private let store: FilmProjectStore
    private let generationService: GenerationService?

    init(store: FilmProjectStore = .shared, generationService: GenerationService? = nil) {
        self.store = store
        self.generationService = generationService
    }

    /// Creates `count` takes for the shot and the matching GenerationRequests.
    /// Returns the requests; when a GenerationService is attached they are also
    /// enqueued (sequentially, concurrency stays 1).
    @discardableResult
    func planTakes(
        projectID: UUID,
        shotID: UUID,
        count: Int,
        baseSeed: Int? = nil
    ) throws -> [GenerationRequest] {
        guard (1...Self.maxTakesPerShot).contains(count) else {
            throw CoordinatorError.invalidTakeCount(count)
        }
        guard var project = store.project(id: projectID),
              let shotIndex = project.shots.firstIndex(where: { $0.id == shotID }) else {
            throw CoordinatorError.shotNotFound(shotID)
        }
        let mayInheritPreviousShot: Bool
        if project.workflowMode == AutoMovieRunCoordinator.autoMovieWorkflowMode {
            mayInheritPreviousShot = AutoMovieRunCoordinator(store: store)
                .resolvedContinuityMode(forShotAt: shotIndex, in: project)
                == .continueFromPrevious
        } else {
            // Preserve legacy/manual Storyboard behaviour: absent/auto modes
            // may use a prepared path, but an explicit Cut never may.
            mayInheritPreviousShot = shotIndex > 0 && project.shots[shotIndex].continuityMode != .cut
        }

        // Auto Movie's first run, Shot-card Regenerate, and bulk regeneration
        // all end here. Refresh the inherited frame at this shared boundary so
        // a newly selected upstream Take cannot be bypassed by an older cached
        // continuity image. Explicit shot images and Cuts keep their existing
        // precedence and never consult a previous Take.
        if project.workflowMode == AutoMovieRunCoordinator.autoMovieWorkflowMode,
           mayInheritPreviousShot,
           project.shots[shotIndex].startingImageReferenceAssetID == nil,
           shouldPrepareAutoMovieContinuity(project: project, shotIndex: shotIndex) {
            let coordinator = AutoMovieRunCoordinator(store: store)
            guard case .success = coordinator.prepareContinuityAsset(
                projectID: projectID, shotIndex: shotIndex
            ), let refreshed = store.project(id: projectID) else {
                throw CoordinatorError.continuityImageUnavailable(shotID)
            }
            project = refreshed
        }

        let shot = project.shots[shotIndex]
        let settings = project.settings
        let targetDuration = settings.resolvedPreset == .custom ? nil : shot.durationSeconds
        let generationSource = project.workflowMode == "hybrid" ? "hybrid" : "storyboard"

        // Starting image precedence:
        //   1. the shot's explicit user/CharacterBible selection
        //   2. a frame inherited from the previous shot (continuity chain)
        //   3. none — ordinary text-to-video
        // A shot that is supposed to continue but has an unusable inherited
        // frame is rejected rather than quietly rendered as text-to-video.
        var sourceImagePath: String? = nil
        // Only a frame inherited from the previous shot gets the calibrated
        // continuity strength; an image the user chose keeps the existing
        // exact-first-frame behaviour.
        var usesInheritedContinuityFrame = false
        var effectiveSource: LTXContinuitySource = .none
        // The optional Character Anchor sits between the two: it applies to the
        // opening shot only, never overrides an image the user picked for that
        // shot, and is never re-injected into a later shot, which continues to
        // inherit from the shot before it.
        var usesCharacterAnchor = false
        var usesOpeningReference = false
        if let assetID = shot.startingImageReferenceAssetID {
            guard let (_, asset) = project.findReferenceAsset(id: assetID) else {
                throw CoordinatorError.startingImageNotFound(assetID)
            }
            guard let relativePath = asset.projectRelativePath,
                  let url = store.managedCharacterAssetURL(projectID: projectID, relativePath: relativePath),
                  FileManager.default.fileExists(atPath: url.path) else {
                throw CoordinatorError.startingImageUnavailable(assetID)
            }
            sourceImagePath = url.path
            effectiveSource = .explicitStartingImage
        } else if mayInheritPreviousShot,
                  let refreshPath = shot.identityRefreshAnchorRelativePath,
                  !refreshPath.isEmpty,
                  let url = store.managedProjectAssetURL(projectID: projectID, relativePath: refreshPath),
                  ContinuityFrameExtractor.isUsableImage(atPath: url.path) {
            // A refresh anchor is only ever created when the frame this shot
            // would otherwise inherit could not carry the character into a
            // closer framing. It conditions like an inherited frame, so the
            // camera and action still move on.
            sourceImagePath = url.path
            usesInheritedContinuityFrame = true
            effectiveSource = .identityRefreshAnchor
        } else if mayInheritPreviousShot,
                  let relativePath = shot.continuityImageRelativePath {
            guard let url = store.managedProjectAssetURL(projectID: projectID, relativePath: relativePath),
                  ContinuityFrameExtractor.isUsableImage(atPath: url.path) else {
                throw CoordinatorError.continuityImageUnavailable(shotID)
            }
            sourceImagePath = url.path
            usesInheritedContinuityFrame = true
            effectiveSource = .inheritedLastFrame
        } else if shotIndex == 0,
                  let openingReference = CharacterAnchorResolver.resolveOpeningReference(
                      project: project, store: store) {
            // A scene-like still the user picked is the most explicit statement
            // of how the movie should open, so it outranks the Character Bible
            // anchor below.
            switch openingReference {
            case .success(let url):
                sourceImagePath = url.path
                usesOpeningReference = true
                effectiveSource = .openingReference
            case .failure(let issue):
                throw CoordinatorError.openingReferenceUnavailable(issue)
            }
        } else if shotIndex == 0, project.characterAnchor.isActive {
            switch CharacterAnchorResolver.resolve(project: project, store: store) {
            case .resolved(let anchor):
                sourceImagePath = anchor.fileURL.path
                usesCharacterAnchor = true
                effectiveSource = .characterAnchor
            case .unavailable(let issue):
                throw CoordinatorError.characterAnchorUnavailable(issue)
            case .inactive:
                break
            }
        }

        // How hard the inherited frame should hold. Only meaningful once the
        // shot is already inheriting: this never decides cut vs continue.
        var continuityStrengthPolicy: ContinuityStrengthPolicy = .standard
        if usesInheritedContinuityFrame, shotIndex > 0 {
            continuityStrengthPolicy = ContinuityStrengthResolver.policy(
                previous: project.shots[shotIndex - 1], current: shot
            )
        }

        var requests: [GenerationRequest] = []
        for i in 0..<count {
            let seed = baseSeed.map { $0 + i } ?? Int.random(in: 0..<Int(Int32.max))
            var params = GenerationParameters.default
            params.width = settings.width
            params.height = settings.height
            params.fps = settings.fps
            params.numFrames = settings.resolvedPreset == .custom
                ? (settings.numFrames ?? PromptCompiler.frameCount(forSeconds: shot.durationSeconds, fps: settings.fps))
                : PromptCompiler.frameCount(forSeconds: shot.durationSeconds, fps: settings.fps)
            params.numInferenceSteps = settings.resolvedInferenceSteps
            params.seed = seed
            if usesOpeningReference {
                // The user chose this frame as the movie's first frame, so it
                // is conditioned exactly like an explicit Starting Image.
                params.imageStrength = OpeningReferencePolicy.openingImageStrength
            } else if usesCharacterAnchor {
                // A character sheet extraction is a posed figure on a plain
                // background. Pinning it as an exact first frame drags that
                // whole plate into the movie, so the anchor conditions more
                // loosely than a user-chosen starting image: enough to carry
                // face, hair and costume, little enough for the shot to be a
                // shot.
                params.imageStrength = CharacterAnchorPolicy.openingImageStrength
            } else if usesInheritedContinuityFrame {
                // Pinning the first frame exactly (1.0) preserved the scene but
                // froze the composition, so continuing shots never progressed.
                // The calibrated value keeps the set, wardrobe and lighting
                // while letting the camera and action move on, and a shot that
                // also asks for a large framing change gets the looser anchor.
                params.imageStrength = ContinuityStrengthResolver.strength(for: continuityStrengthPolicy)
            }

            let take = Take(
                shotID: shotID,
                modelID: settings.modelID,
                seed: seed,
                promptSnapshot: shot.compiledPrompt,
                settingsSnapshot: params,
                preset: settings.resolvedPreset.rawValue,
                qualityMode: settings.qualityMode,
                audioEnabled: settings.resolvedAudioEnabled,
                requestedWidth: params.width,
                requestedHeight: params.height,
                fps: params.fps,
                requestedDuration: Double(params.numFrames) / Double(params.fps),
                targetDurationSeconds: targetDuration,
                status: .queued,
                startingImageReferenceAssetID: shot.startingImageReferenceAssetID,
                sourceImagePath: sourceImagePath,
                generationSourceDiagnostics: makeSourceDiagnostics(
                    project: project,
                    shot: shot,
                    shotIndex: shotIndex,
                    source: effectiveSource,
                    sourceImagePath: sourceImagePath
                )
            )
            project.shots[shotIndex].takes.append(take)

            let request = GenerationRequest(
                prompt: shot.compiledPrompt,
                sourceImagePath: sourceImagePath,
                disableAudio: !settings.resolvedAudioEnabled,
                modelId: settings.modelID,
                textEncoderId: settings.textEncoderID,
                parameters: params,
                qualityMode: settings.qualityMode,
                preset: settings.resolvedPreset.rawValue,
                targetDurationSeconds: targetDuration,
                generationSource: generationSource,
                filmProjectID: projectID,
                shotID: shotID,
                takeID: take.id
            )
            project.jobs.append(GenerationJob(
                projectID: projectID, shotID: shotID, takeID: take.id,
                requestID: request.id
            ))
            requests.append(request)
        }
        store.save(project)
        // Sequential by construction: addBatch feeds the single-flight queue.
        if let service = generationService {
            Task { @MainActor in
                service.addBatch(requests)
            }
        }
        return requests
    }

    private func shouldPrepareAutoMovieContinuity(
        project: FilmProject,
        shotIndex: Int
    ) -> Bool {
        guard shotIndex > 0 else { return false }
        let previous = project.shots[shotIndex - 1]
        let target = project.shots[shotIndex]
        let hasCompletedTake = previous.takes.contains { $0.status == .completed }
        guard hasCompletedTake else { return false }
        let hasExistingOutput = previous.takes.contains { take in
            take.status == .completed
                && take.outputPath.map(FileManager.default.fileExists(atPath:)) == true
        }
        // A changed selection must be resolved even when none of the videos
        // still exists, otherwise an older downstream cache would silently win.
        return hasExistingOutput
            || target.continuitySourceTakeID != previous.continuitySourceTake?.id
    }

    /// Records only the observed output of `ImageConditioningPreparer` for an
    /// already-queued Take. It never re-runs source selection or modifies the
    /// request that reaches the backend.
    func recordImagePreparation(
        request: GenerationRequest,
        preparedConditioning: PreparedImageConditioning?
    ) {
        guard let projectID = request.filmProjectID,
              let shotID = request.shotID,
              let takeID = request.takeID,
              var project = store.project(id: projectID),
              let shotIndex = project.shots.firstIndex(where: { $0.id == shotID }),
              let takeIndex = project.shots[shotIndex].takes.firstIndex(where: { $0.id == takeID }),
              var diagnostics = project.shots[shotIndex].takes[takeIndex].generationSourceDiagnostics else {
            return
        }
        diagnostics.imagePreparation = preparedConditioning.map { prepared in
            GenerationImagePreparationDiagnostics(
                originalWidth: prepared.geometry.sourceWidth,
                originalHeight: prepared.geometry.sourceHeight,
                effectiveWidth: prepared.geometry.targetWidth,
                effectiveHeight: prepared.geometry.targetHeight,
                mode: prepared.mode == .reusedExactCanvas ? .noOp : .scaleToFillCenterCrop,
                backendFilename: prepared.preparedURL.lastPathComponent
            )
        }
        project.shots[shotIndex].takes[takeIndex].generationSourceDiagnostics = diagnostics
        store.save(project)
    }

    /// Marks the existing Take as executing and captures the start of the
    /// runtime observation window. This is deliberately after queue selection
    /// and before Python/source preparation; it never changes the request or
    /// any generation policy.
    func recordExecutionStarted(
        request: GenerationRequest,
        startedAt: Date = Date()
    ) {
        guard let projectID = request.filmProjectID,
              let shotID = request.shotID,
              let takeID = request.takeID,
              var project = store.project(id: projectID),
              let shotIndex = project.shots.firstIndex(where: { $0.id == shotID }),
              let takeIndex = project.shots[shotIndex].takes.firstIndex(where: { $0.id == takeID }) else {
            return
        }

        var take = project.shots[shotIndex].takes[takeIndex]
        let effective = request.parameters
        take.status = .generating
        take.generationStartedAt = startedAt
        take.generationCompletedAt = nil
        take.generationTime = nil
        take.generationRuntimeDiagnostics = GenerationRuntimeDiagnostics(
            status: .running,
            startedAt: startedAt,
            finishedAt: nil,
            elapsedSeconds: nil,
            requestedWidth: take.requestedWidth,
            requestedHeight: take.requestedHeight,
            effectiveWidth: effectiveDimension(effective.width),
            effectiveHeight: effectiveDimension(effective.height),
            actualWidth: nil,
            actualHeight: nil,
            requestedFrames: take.settingsSnapshot.numFrames,
            requestedDurationSeconds: take.requestedDuration,
            actualDurationSeconds: nil,
            actualFPS: nil,
            actualFrameCount: nil,
            backendResult: .notStarted,
            backendExitCode: nil,
            failureStage: nil,
            errorSummary: nil,
            outputFilename: nil,
            outputExists: false,
            outputMetadataReadable: nil
        )
        project.shots[shotIndex].takes[takeIndex] = take
        for jobIndex in project.jobs.indices where project.jobs[jobIndex].takeID == takeID {
            project.jobs[jobIndex].state = .running
            project.jobs[jobIndex].updatedAt = startedAt
            project.jobs[jobIndex].errorMessage = nil
        }
        store.save(project)
    }

    /// Marks a take completed from a finished GenerationResult (matched by takeID).
    func recordCompletion(result: GenerationResult, finalizedAt: Date = Date()) {
        guard let projectID = result.filmProjectID,
              let shotID = result.shotID,
              let takeID = result.takeID,
              var project = store.project(id: projectID),
              let shotIndex = project.shots.firstIndex(where: { $0.id == shotID }),
              let takeIndex = project.shots[shotIndex].takes.firstIndex(where: { $0.id == takeID }) else {
            return
        }
        var take = project.shots[shotIndex].takes[takeIndex]
        let outputExists = FileManager.default.fileExists(atPath: result.videoPath)
        let mediaInfo = outputExists ? MediaProbe.probe(path: result.videoPath) : nil
        let previousRuntime = take.generationRuntimeDiagnostics
        let startedAt = previousRuntime?.startedAt ?? take.generationStartedAt ?? result.createdAt
        let elapsed = max(0, finalizedAt.timeIntervalSince(startedAt))
        let requestedFrames = previousRuntime?.requestedFrames ?? take.settingsSnapshot.numFrames
        let requestedDuration = previousRuntime?.requestedDurationSeconds ?? take.requestedDuration
        let actualMetadataWasRead = mediaInfo != nil
            || result.actualWidth != nil
            || result.actualHeight != nil
            || result.actualDuration != nil
            || result.actualFPS != nil
        take.status = .completed
        take.outputPath = result.videoPath
        take.seed = result.seed
        take.effectiveWidth = result.effectiveWidth
        take.effectiveHeight = result.effectiveHeight
        take.actualWidth = result.actualWidth ?? mediaInfo?.width
        take.actualHeight = result.actualHeight ?? mediaInfo?.height
        take.actualDuration = result.actualDuration ?? mediaInfo?.durationSeconds
        take.modelRevision = result.modelRevision
        take.quantization = result.quantization
        take.preset = result.preset ?? take.preset
        take.qualityMode = result.qualityMode ?? take.qualityMode
        take.effectiveProfileID = result.effectiveProfileID
        take.effectiveProfileName = result.effectiveProfileName
        take.effectiveProfileReason = result.effectiveProfileReason
        take.targetDurationSeconds = result.targetDurationSeconds ?? take.targetDurationSeconds
        take.audioEnabled = result.audioEnabled ?? take.audioEnabled
        take.settingsSnapshot = result.parameters
        take.fps = result.parameters.fps
        take.requestedDuration = result.requestedDurationSeconds ?? take.requestedDuration
        take.generationStartedAt = startedAt
        take.generationCompletedAt = result.completedAt
        take.generationTime = result.duration
        take.peakMemoryBytes = result.peakMemoryBytes
        take.swapPeakBytes = result.swapPeakBytes
        if let mediaInfo {
            take.audioMetadata = mediaInfo
        }
        take.generationRuntimeDiagnostics = GenerationRuntimeDiagnostics(
            status: .succeeded,
            startedAt: startedAt,
            finishedAt: finalizedAt,
            elapsedSeconds: elapsed,
            requestedWidth: previousRuntime?.requestedWidth ?? take.requestedWidth,
            requestedHeight: previousRuntime?.requestedHeight ?? take.requestedHeight,
            effectiveWidth: result.effectiveWidth ?? effectiveDimension(result.parameters.width),
            effectiveHeight: result.effectiveHeight ?? effectiveDimension(result.parameters.height),
            actualWidth: mediaInfo?.width ?? result.actualWidth,
            actualHeight: mediaInfo?.height ?? result.actualHeight,
            requestedFrames: requestedFrames,
            requestedDurationSeconds: requestedDuration,
            actualDurationSeconds: mediaInfo?.durationSeconds ?? result.actualDuration,
            actualFPS: mediaInfo?.fps ?? result.actualFPS,
            actualFrameCount: mediaInfo?.frameCount,
            backendResult: .succeeded,
            backendExitCode: nil,
            failureStage: nil,
            errorSummary: nil,
            outputFilename: URL(fileURLWithPath: result.videoPath).lastPathComponent,
            outputExists: outputExists,
            outputMetadataReadable: actualMetadataWasRead
        )
        project.shots[shotIndex].takes[takeIndex] = take
        for jobIndex in project.jobs.indices where project.jobs[jobIndex].takeID == takeID {
            project.jobs[jobIndex].state = .completed
            project.jobs[jobIndex].updatedAt = finalizedAt
            project.jobs[jobIndex].errorMessage = nil
        }
        store.save(project)
    }

    /// Persists a terminal failure without changing the error returned to the
    /// queue/UI. Full stderr remains in the existing runner log; the project
    /// stores only a bounded summary and the existing output-file facts.
    func recordFailure(
        request: GenerationRequest,
        error: Error,
        stage explicitStage: GenerationFailureStage? = nil,
        effectiveParameters: GenerationParameters? = nil,
        outputPath: String? = nil,
        finalizedAt: Date = Date()
    ) {
        guard let projectID = request.filmProjectID,
              let shotID = request.shotID,
              let takeID = request.takeID,
              var project = store.project(id: projectID),
              let shotIndex = project.shots.firstIndex(where: { $0.id == shotID }),
              let takeIndex = project.shots[shotIndex].takes.firstIndex(where: { $0.id == takeID }) else {
            return
        }

        var take = project.shots[shotIndex].takes[takeIndex]
        let stage = explicitStage ?? GenerationRuntimeFailureClassifier.stage(for: error)
        let summary = GenerationRuntimeFailureClassifier.conciseSummary(for: error)
        let previousRuntime = take.generationRuntimeDiagnostics
        let startedAt = previousRuntime?.startedAt ?? take.generationStartedAt ?? finalizedAt
        let elapsed = max(0, finalizedAt.timeIntervalSince(startedAt))
        let parameters = effectiveParameters ?? request.parameters
        let recordedOutputPath = outputPath ?? take.outputPath
        let outputExists = recordedOutputPath.map(FileManager.default.fileExists(atPath:)) ?? false
        let mediaInfo = (recordedOutputPath.flatMap { outputExists ? MediaProbe.probe(path: $0) : nil })
        let backendResult: GenerationBackendResultStatus
        switch stage {
        case .sourcePreparation, .backendLaunch:
            backendResult = .notStarted
        case .cancelled:
            backendResult = .cancelled
        case .unknown:
            backendResult = .unavailable
        case .backendGeneration, .outputMissing, .outputValidation:
            backendResult = .failed
        }

        take.status = .failed
        take.outputPath = recordedOutputPath
        take.actualWidth = mediaInfo?.width ?? take.actualWidth
        take.actualHeight = mediaInfo?.height ?? take.actualHeight
        take.actualDuration = mediaInfo?.durationSeconds ?? take.actualDuration
        take.audioMetadata = mediaInfo ?? take.audioMetadata
        take.generationStartedAt = startedAt
        take.generationCompletedAt = finalizedAt
        take.generationTime = elapsed
        take.generationRuntimeDiagnostics = GenerationRuntimeDiagnostics(
            status: .failed,
            startedAt: startedAt,
            finishedAt: finalizedAt,
            elapsedSeconds: elapsed,
            requestedWidth: previousRuntime?.requestedWidth ?? take.requestedWidth,
            requestedHeight: previousRuntime?.requestedHeight ?? take.requestedHeight,
            effectiveWidth: effectiveDimension(parameters.width),
            effectiveHeight: effectiveDimension(parameters.height),
            actualWidth: mediaInfo?.width,
            actualHeight: mediaInfo?.height,
            requestedFrames: previousRuntime?.requestedFrames ?? take.settingsSnapshot.numFrames,
            requestedDurationSeconds: previousRuntime?.requestedDurationSeconds ?? take.requestedDuration,
            actualDurationSeconds: mediaInfo?.durationSeconds,
            actualFPS: mediaInfo?.fps,
            actualFrameCount: mediaInfo?.frameCount,
            backendResult: backendResult,
            backendExitCode: GenerationRuntimeFailureClassifier.exitCode(from: error),
            failureStage: stage,
            errorSummary: summary,
            outputFilename: recordedOutputPath.map { URL(fileURLWithPath: $0).lastPathComponent },
            outputExists: outputExists,
            outputMetadataReadable: outputExists ? mediaInfo != nil : false
        )
        project.shots[shotIndex].takes[takeIndex] = take
        for jobIndex in project.jobs.indices where project.jobs[jobIndex].takeID == takeID {
            project.jobs[jobIndex].state = .failed
            project.jobs[jobIndex].updatedAt = finalizedAt
            project.jobs[jobIndex].errorMessage = summary
        }
        store.save(project)
    }

    /// Mirrors a cancelled GenerationRequest into its persisted Take and Job.
    func recordCancellation(
        request: GenerationRequest,
        effectiveParameters: GenerationParameters? = nil,
        outputPath: String? = nil,
        finalizedAt: Date = Date()
    ) {
        guard let projectID = request.filmProjectID,
              let shotID = request.shotID,
              let takeID = request.takeID,
              var project = store.project(id: projectID),
              let shotIndex = project.shots.firstIndex(where: { $0.id == shotID }),
              let takeIndex = project.shots[shotIndex].takes.firstIndex(where: { $0.id == takeID }) else {
            return
        }
        var take = project.shots[shotIndex].takes[takeIndex]
        let previousRuntime = take.generationRuntimeDiagnostics
        let startedAt = previousRuntime?.startedAt ?? take.generationStartedAt ?? finalizedAt
        let elapsed = max(0, finalizedAt.timeIntervalSince(startedAt))
        let parameters = effectiveParameters ?? request.parameters
        let recordedOutputPath = outputPath ?? take.outputPath
        let outputExists = recordedOutputPath.map(FileManager.default.fileExists(atPath:)) ?? false
        let mediaInfo = recordedOutputPath.flatMap { outputExists ? MediaProbe.probe(path: $0) : nil }
        take.status = .cancelled
        take.outputPath = recordedOutputPath
        take.actualWidth = mediaInfo?.width ?? take.actualWidth
        take.actualHeight = mediaInfo?.height ?? take.actualHeight
        take.actualDuration = mediaInfo?.durationSeconds ?? take.actualDuration
        take.audioMetadata = mediaInfo ?? take.audioMetadata
        take.generationStartedAt = startedAt
        take.generationCompletedAt = finalizedAt
        take.generationTime = elapsed
        take.generationRuntimeDiagnostics = GenerationRuntimeDiagnostics(
            status: .cancelled,
            startedAt: startedAt,
            finishedAt: finalizedAt,
            elapsedSeconds: elapsed,
            requestedWidth: previousRuntime?.requestedWidth ?? take.requestedWidth,
            requestedHeight: previousRuntime?.requestedHeight ?? take.requestedHeight,
            effectiveWidth: effectiveDimension(parameters.width),
            effectiveHeight: effectiveDimension(parameters.height),
            actualWidth: mediaInfo?.width,
            actualHeight: mediaInfo?.height,
            requestedFrames: previousRuntime?.requestedFrames ?? take.settingsSnapshot.numFrames,
            requestedDurationSeconds: previousRuntime?.requestedDurationSeconds ?? take.requestedDuration,
            actualDurationSeconds: mediaInfo?.durationSeconds,
            actualFPS: mediaInfo?.fps,
            actualFrameCount: mediaInfo?.frameCount,
            backendResult: .cancelled,
            backendExitCode: nil,
            failureStage: .cancelled,
            errorSummary: "Generation cancelled.",
            outputFilename: recordedOutputPath.map { URL(fileURLWithPath: $0).lastPathComponent },
            outputExists: outputExists,
            outputMetadataReadable: outputExists ? mediaInfo != nil : false
        )
        project.shots[shotIndex].takes[takeIndex] = take
        for jobIndex in project.jobs.indices where project.jobs[jobIndex].takeID == takeID {
            project.jobs[jobIndex].state = .cancelled
            project.jobs[jobIndex].updatedAt = finalizedAt
            project.jobs[jobIndex].errorMessage = nil
        }
        store.save(project)
    }

    private func effectiveDimension(_ value: Int) -> Int {
        (value / 64) * 64
    }

    /// Selects a take for final assembly.
    func selectTake(projectID: UUID, shotID: UUID, takeID: UUID) throws {
        guard var project = store.project(id: projectID),
              let shotIndex = project.shots.firstIndex(where: { $0.id == shotID }) else {
            throw CoordinatorError.shotNotFound(shotID)
        }
        project.shots[shotIndex].selectedTakeID = takeID
        if project.shots.indices.contains(shotIndex + 1) {
            let downstreamIndex = shotIndex + 1
            IdentityRefreshService.invalidateAnchorForContinuitySourceChange(
                shotIndex: downstreamIndex,
                previousSourceTakeID: project.shots[downstreamIndex].continuitySourceTakeID,
                currentSourceTakeID: takeID,
                in: &project
            )
        }
        store.save(project)
    }

    private func makeSourceDiagnostics(
        project: FilmProject,
        shot: Shot,
        shotIndex: Int,
        source: LTXContinuitySource,
        sourceImagePath: String?
    ) -> GenerationSourceDiagnostics {
        let previousShot = shotIndex > 0 ? project.shots[shotIndex - 1] : nil
        let continuityTakeID: UUID?
        let continuitySelection: ContinuityTakeSelectionReason?
        switch source {
        case .inheritedLastFrame:
            continuityTakeID = shot.continuitySourceTakeID
            continuitySelection = selectionReason(
                for: continuityTakeID,
                in: previousShot
            )
        case .identityRefreshAnchor:
            continuityTakeID = shot.identityRefreshSourceTakeID
            continuitySelection = selectionReason(
                for: continuityTakeID,
                in: previousShot
            )
        default:
            continuityTakeID = nil
            continuitySelection = nil
        }
        return GenerationSourceDiagnostics(
            requestedContinuityMode: shot.continuityMode,
            effectiveSource: source,
            actualVideoMode: sourceImagePath == nil ? .textToVideo : .imageToVideo,
            sourceFilename: sourceImagePath.map { URL(fileURLWithPath: $0).lastPathComponent },
            sourceProjectRelativePath: relativeProjectPath(
                sourceImagePath, projectID: project.id
            ),
            continuitySourceShotID: source == .inheritedLastFrame ? previousShot?.id : nil,
            continuitySourceTakeID: continuityTakeID,
            continuityTakeSelectionReason: continuitySelection,
            refreshAnchorOrigin: source == .identityRefreshAnchor
                ? shot.identityRefreshAnchorOrigin : nil,
            refreshAnchorSourceShotID: source == .identityRefreshAnchor
                ? shot.identityRefreshAnchorSourceShotID : nil,
            refreshAnchorSourceTakeID: source == .identityRefreshAnchor
                ? shot.identityRefreshSourceTakeID : nil,
            imagePreparation: nil,
            recordedAt: Date()
        )
    }

    private func selectionReason(
        for takeID: UUID?,
        in previousShot: Shot?
    ) -> ContinuityTakeSelectionReason? {
        guard let takeID, let previousShot else { return nil }
        return previousShot.selectedTake?.id == takeID
            ? .selectedTake : .latestCompletedTake
    }

    private func relativeProjectPath(_ path: String?, projectID: UUID) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let root = store.projectsDirectory
            .appendingPathComponent(projectID.uuidString, isDirectory: true)
            .standardizedFileURL.path
        let candidate = URL(fileURLWithPath: path).standardizedFileURL.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard candidate.hasPrefix(prefix) else { return nil }
        return String(candidate.dropFirst(prefix.count))
    }
}
