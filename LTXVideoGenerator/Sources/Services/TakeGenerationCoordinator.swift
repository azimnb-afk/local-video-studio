import Foundation

/// Builds and tracks take generations for a shot. 1–20 takes per shot, each a
/// different seed, ALWAYS sequential: requests go through the single-flight
/// GenerationService queue — this type never runs generations itself.
final class TakeGenerationCoordinator {

    static let maxTakesPerShot = 20

    enum CoordinatorError: Error, Equatable {
        case invalidTakeCount(Int)
        case shotNotFound(UUID)
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

        var requests: [GenerationRequest] = []
        for i in 0..<count {
            let seed = baseSeed.map { $0 + i } ?? Int.random(in: 0..<Int(Int32.max))
            var params = GenerationParameters.default
            params.width = settings.width
            params.height = settings.height
            params.fps = settings.fps
            params.numFrames = PromptCompiler.frameCount(forSeconds: shot.durationSeconds, fps: settings.fps)
            params.seed = seed

            let take = Take(
                shotID: shotID,
                modelID: settings.modelID,
                seed: seed,
                promptSnapshot: shot.compiledPrompt,
                settingsSnapshot: params,
                requestedWidth: params.width,
                requestedHeight: params.height,
                fps: params.fps,
                requestedDuration: shot.durationSeconds,
                status: .queued
            )
            project.shots[shotIndex].takes.append(take)

            let request = GenerationRequest(
                prompt: shot.compiledPrompt,
                modelId: settings.modelID,
                textEncoderId: settings.textEncoderID,
                parameters: params,
                qualityMode: settings.qualityMode,
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
