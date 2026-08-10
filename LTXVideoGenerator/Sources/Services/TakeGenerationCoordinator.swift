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
        // The optional Character Anchor sits between the two: it applies to the
        // opening shot only, never overrides an image the user picked for that
        // shot, and is never re-injected into a later shot, which continues to
        // inherit from the shot before it.
        var usesCharacterAnchor = false
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
        } else if let relativePath = shot.continuityImageRelativePath {
            guard let url = store.managedProjectAssetURL(projectID: projectID, relativePath: relativePath),
                  ContinuityFrameExtractor.isUsableImage(atPath: url.path) else {
                throw CoordinatorError.continuityImageUnavailable(shotID)
            }
            sourceImagePath = url.path
            usesInheritedContinuityFrame = true
        } else if shotIndex == 0, project.characterAnchor.isActive {
            switch CharacterAnchorResolver.resolve(project: project, store: store) {
            case .resolved(let anchor):
                sourceImagePath = anchor.fileURL.path
                usesCharacterAnchor = true
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
            if usesCharacterAnchor {
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
                sourceImagePath: sourceImagePath
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

    /// Marks a take completed from a finished GenerationResult (matched by takeID).
    func recordCompletion(result: GenerationResult) {
        guard let projectID = result.filmProjectID,
              let shotID = result.shotID,
              let takeID = result.takeID,
              var project = store.project(id: projectID),
              let shotIndex = project.shots.firstIndex(where: { $0.id == shotID }),
              let takeIndex = project.shots[shotIndex].takes.firstIndex(where: { $0.id == takeID }) else {
            return
        }
        var take = project.shots[shotIndex].takes[takeIndex]
        take.status = .completed
        take.outputPath = result.videoPath
        take.seed = result.seed
        take.effectiveWidth = result.effectiveWidth
        take.effectiveHeight = result.effectiveHeight
        take.actualWidth = result.actualWidth
        take.actualHeight = result.actualHeight
        take.actualDuration = result.actualDuration
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
        take.generationCompletedAt = result.completedAt
        take.generationTime = result.duration
        take.peakMemoryBytes = result.peakMemoryBytes
        take.swapPeakBytes = result.swapPeakBytes
        if let path = take.outputPath, let info = MediaProbe.probe(path: path) {
            take.audioMetadata = info
        }
        project.shots[shotIndex].takes[takeIndex] = take
        for jobIndex in project.jobs.indices where project.jobs[jobIndex].takeID == takeID {
            project.jobs[jobIndex].state = .completed
            project.jobs[jobIndex].updatedAt = Date()
        }
        store.save(project)
    }

    /// Mirrors a cancelled GenerationRequest into its persisted Take and Job.
    func recordCancellation(request: GenerationRequest) {
        guard let projectID = request.filmProjectID,
              let shotID = request.shotID,
              let takeID = request.takeID,
              var project = store.project(id: projectID),
              let shotIndex = project.shots.firstIndex(where: { $0.id == shotID }),
              let takeIndex = project.shots[shotIndex].takes.firstIndex(where: { $0.id == takeID }) else {
            return
        }
        project.shots[shotIndex].takes[takeIndex].status = .cancelled
        for jobIndex in project.jobs.indices where project.jobs[jobIndex].takeID == takeID {
            project.jobs[jobIndex].state = .cancelled
            project.jobs[jobIndex].updatedAt = Date()
        }
        store.save(project)
    }

    /// Selects a take for final assembly.
    func selectTake(projectID: UUID, shotID: UUID, takeID: UUID) throws {
        guard var project = store.project(id: projectID),
              let shotIndex = project.shots.firstIndex(where: { $0.id == shotID }) else {
            throw CoordinatorError.shotNotFound(shotID)
        }
        project.shots[shotIndex].selectedTakeID = takeID
        store.save(project)
    }
}
