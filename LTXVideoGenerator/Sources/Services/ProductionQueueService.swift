import Foundation
import Combine

/// Whether a workflow may hand a new job to the production queue.
///
/// Deliberately independent of whether a generation is already running. The
/// queue exists so that a new request can wait its turn, so "something is
/// rendering" is a reason for the job to be queued rather than started — never
/// a reason to refuse the submission. Every Generate button in the app submits
/// a `ProductionJob`; none of them render directly.
///
/// Submission is gated only by whether the request itself is well-formed, plus
/// any in-flight preparation for *this* submission (One Shot's Director
/// planning), which would otherwise be re-entered by a second click.
enum GenerationSubmissionPolicy {
    static func canSubmit(
        prompt: String,
        isPreparing: Bool = false,
        blockingError: String? = nil
    ) -> Bool {
        guard blockingError == nil, !isPreparing else { return false }
        return !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Builds the immutable queue boundary for the direct Generate workflow.
///
/// The Generate view owns only validation and submission. Once this returns a
/// job, the Production Queue owns its complete render lifetime. The fully
/// formed request is stored verbatim so later edits to prompt, model, seed or
/// source image selection cannot change a waiting job.
enum DirectGenerationSubmission {
    enum SubmissionError: LocalizedError, Equatable {
        case emptyPrompt
        case sourceImageUnavailable(String)
        case unsupportedModel(String)

        var errorDescription: String? {
            switch self {
            case .emptyPrompt:
                return "Enter a prompt before generating."
            case .sourceImageUnavailable:
                return "The selected starting image is missing or unreadable. Choose it again."
            case .unsupportedModel(let message):
                return message
            }
        }
    }

    static func makeJob(
        request: GenerationRequest,
        title: String? = nil,
        fileManager: FileManager = .default
    ) throws -> ProductionJob {
        guard GenerationSubmissionPolicy.canSubmit(prompt: request.prompt) else {
            throw SubmissionError.emptyPrompt
        }
        if let path = request.sourceImagePath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty,
           !fileManager.isReadableFile(atPath: path) {
            throw SubmissionError.sourceImageUnavailable(path)
        }
        if case .unsupported(let reason) = GenerationModelResolver.resolve(modelID: request.modelId) {
            throw SubmissionError.unsupportedModel(reason.userMessage)
        }

        // This is the concrete submission-time snapshot shown in preflight and
        // handed to the renderer. GenerationService may still apply its normal
        // execution-time memory fallback; that behavior is intentionally
        // unchanged.
        let frozenRequest = FeatureFlags.isEnabled(.autoQualityV1)
            ? GenerationSettingsResolver.resolveForPreflight(request: request).request
            : request
        var snapshot = ProductionJobSnapshot()
        snapshot.prompt = frozenRequest.prompt
        snapshot.settings = frozenRequest.parameters
        snapshot.modelID = frozenRequest.modelId
        snapshot.textEncoderID = frozenRequest.textEncoderId
        snapshot.preset = frozenRequest.preset
        snapshot.qualityMode = frozenRequest.qualityMode
        snapshot.audioEnabled = !frozenRequest.disableAudio
        snapshot.targetDurationSeconds = frozenRequest.targetDurationSeconds
        snapshot.seed = frozenRequest.parameters.seed
        snapshot.batchCount = 1
        snapshot.pendingRequests = [frozenRequest]

        return ProductionJob(
            kind: .generate,
            title: title ?? shortTitle(frozenRequest.prompt),
            snapshot: snapshot
        )
    }

    private static func shortTitle(_ prompt: String) -> String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 60 ? String(trimmed.prefix(60)) + "…" : trimmed
    }
}

/// Binds the global production queue to the app: owns the coordinator, starts
/// each job through the mode it belongs to, and watches for the job finishing.
///
/// `GenerationService` already renders one request at a time, so this does not
/// add a second renderer. What it adds is the job boundary — a movie's shots and
/// its final assembly all belong to one job, and no other job is admitted until
/// that whole job is done. Without it, two queued movies interleave their shots
/// through the shared render queue.
@MainActor
final class ProductionQueueService: ObservableObject {

    static let shared = ProductionQueueService()

    @Published private(set) var jobs: [ProductionJob] = []
    @Published private(set) var activeJobID: UUID?
    @Published private(set) var isPaused = false

    private let coordinator: ProductionQueueCoordinator
    private let store = FilmProjectStore.shared
    private var generationService: GenerationService?
    private var cancellables = Set<AnyCancellable>()
    /// True between admitting a job and observing it finish. Guards against the
    /// idle-looking moment before the renderer has picked the work up.
    private var isAwaitingCompletion = false
    /// Last run-level outcome reported by the generation service. Only a
    /// terminal outcome for the *active job's own project* is ever acted on.
    private var lastFilmRunEvent: FilmRunEvent?

    init(coordinator: ProductionQueueCoordinator = .shared) {
        self.coordinator = coordinator
        coordinator.runner = { [weak self] job in
            guard let self else { return .failed("Queue is unavailable") }
            return self.start(job)
        }
        coordinator.onChange = { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    /// Connected once the generation service exists, so the queue can watch for
    /// the renderer going idle.
    func attach(generationService: GenerationService) {
        guard self.generationService !== generationService else { return }
        self.generationService = generationService
        generationService.$queue
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.checkActiveJobProgress() }
            .store(in: &cancellables)
        // The render queue is not enough on its own. Final assembly runs after
        // the last take has left the queue, so `$queue` goes quiet while the
        // job is still legitimately unfinished; without this second signal the
        // job would sit in "Assembling" forever and every job behind it would
        // never start.
        generationService.$lastFilmRunEvent
            .receive(on: RunLoop.main)
            .sink { [weak self] event in
                guard let self, let event else { return }
                self.lastFilmRunEvent = event
                self.checkActiveJobProgress()
            }
            .store(in: &cancellables)
        coordinator.startNextIfIdle()
    }

    // MARK: - Enqueue

    @discardableResult
    func enqueue(_ job: ProductionJob) -> ProductionJob {
        let frozen = FeatureFlags.isEnabled(.autoQualityV1)
            ? Self.freezingPresetResolution(in: job)
            : job
        let queued = coordinator.enqueue(frozen)
        refresh()
        return queued
    }

    /// "Generate Now": ahead of the other waiting jobs, but still behind the
    /// single render slot — a running job is never preempted.
    @discardableResult
    func enqueueNext(_ job: ProductionJob) -> ProductionJob {
        let frozen = FeatureFlags.isEnabled(.autoQualityV1)
            ? Self.freezingPresetResolution(in: job)
            : job
        let queued = coordinator.enqueueNext(frozen)
        refresh()
        return queued
    }

    /// Resolves preset-derived requests before persistence. In particular this
    /// freezes source orientation, so replacing an image while a job waits can
    /// neither rotate its target canvas nor cause a portrait/landscape ping-pong.
    nonisolated static func freezingPresetResolution(in job: ProductionJob) -> ProductionJob {
        guard !job.snapshot.pendingRequests.isEmpty else { return job }
        var frozenJob = job
        let requests = job.snapshot.pendingRequests.map {
            GenerationSettingsResolver.resolveForPreflight(request: $0).request
        }
        frozenJob.snapshot.pendingRequests = requests
        if let first = requests.first {
            frozenJob.snapshot.settings = first.parameters
            frozenJob.snapshot.modelID = first.modelId
            frozenJob.snapshot.textEncoderID = first.textEncoderId
            frozenJob.snapshot.preset = first.preset
            frozenJob.snapshot.qualityMode = first.qualityMode
            frozenJob.snapshot.audioEnabled = !first.disableAudio
            frozenJob.snapshot.targetDurationSeconds = first.targetDurationSeconds
            frozenJob.snapshot.seed = first.parameters.seed
        }
        return frozenJob
    }

    // MARK: - User actions

    func cancel(jobID: UUID) {
        if coordinator.activeJobID == jobID {
            // Drop everything the cancelled job had queued behind it, then
            // stop the render actually in flight, so a cancelled movie does not
            // keep going through its remaining shots.
            generationService?.clearQueue()
            generationService?.cancelCurrent()
            isAwaitingCompletion = false
        }
        coordinator.cancel(jobID: jobID)
        refresh()
    }

    func retry(jobID: UUID) { coordinator.retry(jobID: jobID); refresh() }
    func remove(jobID: UUID) { coordinator.remove(jobID: jobID); refresh() }
    func moveUp(jobID: UUID) { coordinator.moveUp(jobID: jobID); refresh() }
    func moveDown(jobID: UUID) { coordinator.moveDown(jobID: jobID); refresh() }
    func setPaused(_ paused: Bool) { coordinator.setPaused(paused); refresh() }

    /// UI ordering is intentionally independent from execution ordering.
    var activeDisplayJobs: [ProductionJob] {
        ProductionQueueCoordinator.activeDisplayJobs(from: jobs)
    }

    // MARK: - Execution

    /// Starts a job. Preflight runs here — at execution time, not at enqueue —
    /// because a file can disappear while a job waits its turn.
    private func start(_ job: ProductionJob) -> ProductionQueueCoordinator.StartOutcome {
        guard let generationService else { return .failed("Generation service unavailable") }
        // A previous run's outcome must not be read as this one's, including on
        // a retry of the same project.
        lastFilmRunEvent = nil

        switch job.kind {
        case .generate, .oneShot:
            let requests = job.snapshot.pendingRequests
            guard !requests.isEmpty else { return .failed("Nothing to render for this job") }
            // A previous terminal job's global error must not be attributed to
            // this immutable job. Any new backend failure is then owned and
            // persisted by this job when the renderer drains.
            generationService.clearError()
            isAwaitingCompletion = true
            coordinator.updateProgress(
                jobID: job.id, current: 0, total: requests.count,
                stage: requests.count > 1 ? "Generation 0 / \(requests.count)" : "Generating")
            generationService.addBatch(requests)
            return .started

        case .storyboard, .autoMovie:
            guard let projectID = job.snapshot.projectID,
                  let project = store.project(id: projectID) else {
                return .failed("The project for this job no longer exists")
            }
            // Execution-time preflight: the opening reference may have been
            // deleted while the job waited, and opening on a different-looking
            // protagonist is exactly what the feature exists to prevent.
            if case .failure(let issue)? = CharacterAnchorResolver.resolveOpeningReference(
                project: project, store: store) {
                return .failed(issue.message)
            }
            if case .unavailable(let issue) = CharacterAnchorResolver.resolve(
                project: project, store: store) {
                return .failed(issue.message)
            }
            var pending: [GenerationRequest] = []
            _ = AutoMovieRunCoordinator(store: store)
                .advance(projectID: projectID) { pending = $0 }
            guard !pending.isEmpty else {
                return .failed("This project has no shots left to render")
            }
            isAwaitingCompletion = true
            coordinator.updateProgress(
                jobID: job.id, current: 1, total: project.shots.count,
                stage: "Shot 1 / \(project.shots.count)")
            generationService.addBatch(pending)
            return .started
        }
    }

    /// Watches the renderer for the active job reaching its end.
    ///
    /// A film job is finished when the render queue has drained *and* the run
    /// coordinator has nothing further to advance — which covers both "all shots
    /// rendered and assembled" and "a shot failed, so no assembly happens".
    private func checkActiveJobProgress() {
        guard isAwaitingCompletion,
              let generationService,
              let job = coordinator.activeJob else { return }

        if generationService.isProcessing || !generationService.queue.isEmpty {
            updateRunningProgress(for: job)
            return
        }

        switch job.kind {
        case .generate, .oneShot:
            // Every request was enqueued together, so an empty renderer really
            // does mean this job is terminal. Preserve backend failure as a
            // failed ProductionJob instead of reporting a missing video as a
            // successful queue completion.
            isAwaitingCompletion = false
            if let error = generationService.error {
                coordinator.markFailed(jobID: job.id, reason: error.localizedDescription)
            } else {
                coordinator.markCompleted(jobID: job.id)
            }

        case .storyboard, .autoMovie:
            guard let projectID = job.snapshot.projectID,
                  let project = store.project(id: projectID) else {
                isAwaitingCompletion = false
                coordinator.markFailed(jobID: job.id, reason: "The project could not be read")
                return
            }
            // An empty renderer is NOT proof a movie is finished. Between two
            // shots the queue is momentarily empty: the finished take has been
            // removed and the next shot is only appended once the run
            // coordinator advances. Completion is therefore decided by the
            // project plus what the run last reported, never by the renderer
            // being idle for an instant.
            switch FilmJobDecider.decide(project: project, runOutcome: runOutcome(for: projectID)) {
            case .completed(let outputPath):
                isAwaitingCompletion = false
                coordinator.markCompleted(jobID: job.id, outputPath: outputPath)
            case .failed(let reason):
                isAwaitingCompletion = false
                coordinator.markFailed(jobID: job.id, reason: reason)
            case .assembling:
                // Hold the job open so the next one cannot start over the top
                // of the final assembly. `$lastFilmRunEvent` — not the render
                // queue — is what wakes this up when the assembly finishes.
                coordinator.updateProgress(jobID: job.id, stage: "Assembling")
                return
            case .running(let current, let total):
                coordinator.updateProgress(
                    jobID: job.id, current: current, total: total,
                    stage: "Shot \(current) / \(total)")
                return
            }
        }
        refresh()
    }

    /// The run outcome, but only when it belongs to the project being asked
    /// about — events from another project say nothing about this job.
    private func runOutcome(for projectID: UUID) -> FilmRunEvent.Kind? {
        guard let event = lastFilmRunEvent, event.projectID == projectID else { return nil }
        return event.kind
    }

    private func updateRunningProgress(for job: ProductionJob) {
        switch job.kind {
        case .storyboard, .autoMovie:
            guard let projectID = job.snapshot.projectID,
                  let project = store.project(id: projectID) else { return }
            // Same decider as the completion path, so the shot the panel shows
            // can never disagree with the shot the queue believes it is on.
            guard case .running(let current, let total) = FilmJobDecider.decide(
                project: project, runOutcome: runOutcome(for: projectID)) else { return }
            coordinator.updateProgress(
                jobID: job.id, current: current, total: total,
                stage: "Shot \(current) / \(total)")
        case .generate, .oneShot:
            guard let total = job.progressTotal, total > 1,
                  let remaining = generationService?.queue.filter({ $0.status == .pending }).count
            else { return }
            let done = max(0, total - remaining - 1)
            coordinator.updateProgress(
                jobID: job.id, current: done, total: total,
                stage: "Generation \(min(done + 1, total)) / \(total)")
        }
    }

    private func refresh() {
        jobs = coordinator.jobs
        activeJobID = coordinator.activeJobID
        isPaused = coordinator.isPaused
    }
}
