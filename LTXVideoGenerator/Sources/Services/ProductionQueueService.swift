import Foundation
import Combine

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
        coordinator.startNextIfIdle()
    }

    // MARK: - Enqueue

    @discardableResult
    func enqueue(_ job: ProductionJob) -> ProductionJob {
        let queued = coordinator.enqueue(job)
        refresh()
        return queued
    }

    /// "Generate Now": ahead of the other waiting jobs, but still behind the
    /// single render slot — a running job is never preempted.
    @discardableResult
    func enqueueNext(_ job: ProductionJob) -> ProductionJob {
        let queued = coordinator.enqueueNext(job)
        refresh()
        return queued
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

    // MARK: - Execution

    /// Starts a job. Preflight runs here — at execution time, not at enqueue —
    /// because a file can disappear while a job waits its turn.
    private func start(_ job: ProductionJob) -> ProductionQueueCoordinator.StartOutcome {
        guard let generationService else { return .failed("Generation service unavailable") }

        switch job.kind {
        case .generate, .oneShot:
            let requests = job.snapshot.pendingRequests
            guard !requests.isEmpty else { return .failed("Nothing to render for this job") }
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
            // does mean this job is done.
            isAwaitingCompletion = false
            coordinator.markCompleted(jobID: job.id)

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
            // project, not by the renderer being idle for an instant.
            let shotFailed = project.shots.contains { shot in
                shot.takes.contains { $0.status == .failed }
                    && shot.selectedTake?.status != .completed
            }
            if shotFailed {
                isAwaitingCompletion = false
                coordinator.markFailed(
                    jobID: job.id, reason: "A shot failed; the movie was not assembled.")
                break
            }
            let everyShotRendered = !project.shots.isEmpty && project.shots.allSatisfy { shot in
                shot.takes.contains { $0.status == .completed }
            }
            guard everyShotRendered else {
                // Still mid-run; the next shot is about to be queued.
                updateRunningProgress(for: job)
                return
            }
            if let assembled = project.assembledMoviePath, !assembled.isEmpty {
                isAwaitingCompletion = false
                coordinator.markCompleted(jobID: job.id, outputPath: assembled)
            } else {
                // All shots are rendered but assembly has not landed yet. Hold
                // the job open so the next one cannot start over the top of the
                // final assembly.
                coordinator.updateProgress(jobID: job.id, stage: "Assembling")
                return
            }
        }
        refresh()
    }

    private func updateRunningProgress(for job: ProductionJob) {
        switch job.kind {
        case .storyboard, .autoMovie:
            guard let projectID = job.snapshot.projectID,
                  let project = store.project(id: projectID) else { return }
            let done = project.shots.filter { $0.selectedTake?.status == .completed }.count
            coordinator.updateProgress(
                jobID: job.id, current: min(done + 1, project.shots.count),
                total: project.shots.count,
                stage: "Shot \(min(done + 1, project.shots.count)) / \(project.shots.count)")
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
