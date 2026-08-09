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

        var sourceImagePath: String? = nil
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
