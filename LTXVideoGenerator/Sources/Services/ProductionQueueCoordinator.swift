import Foundation

/// Global production queue: several movies or renders queued up, executed one
/// after another so the Mac can be left unattended.
///
/// This sits *above* `GenerationService`, which already renders one request at
/// a time. The gap it closes is job-level: without it, queueing two Auto Movies
/// interleaves their shots, because each movie appends its next shot to the
/// shared render queue as the previous one lands (A1, B1, A2, B2…). An outer
/// queue admits exactly one job's work at a time, so a movie finishes — every
/// shot, then its assembly — before the next job is allowed to start.
///
/// Concurrency is fixed at one and is not configurable. On Apple Silicon the
/// renderer competes for unified memory with itself, and a second concurrent
/// render is the fastest way to make both fail.
///
/// The coordinator is deliberately transport-agnostic: it decides *what should
/// run next* and records state, and hands the actual work to a runner closure.
/// That keeps it unit-testable without a GPU, which is what makes the
/// single-active-job guarantee provable rather than asserted.
final class ProductionQueueCoordinator {

    /// How a job's work is actually started. Returning `.started` means the
    /// runner has taken ownership and will report completion later; returning
    /// `.failed` means it could not begin at all.
    enum StartOutcome: Equatable {
        case started
        case failed(String)
    }

    typealias Runner = (ProductionJob) -> StartOutcome

    static let shared = ProductionQueueCoordinator()

    private let store: ProductionQueueStore
    private(set) var jobs: [ProductionJob] = []
    /// Set while a job is executing. Exactly one, ever.
    private(set) var activeJobID: UUID?
    /// When true the queue will not start further waiting jobs. A running job
    /// is left alone — pausing is not cancelling.
    private(set) var isPaused = false

    /// Invoked to start a job. Injected so tests can prove concurrency without
    /// touching the renderer.
    var runner: Runner?
    /// Called whenever the queue changes, so the UI can refresh.
    var onChange: (() -> Void)?

    init(store: ProductionQueueStore = .shared, restoreOnInit: Bool = true) {
        self.store = store
        if restoreOnInit { restore() }
    }

    // MARK: - Restore

    /// Loads the persisted queue and reconciles it with reality.
    ///
    /// A job recorded as running belongs to a process that no longer exists —
    /// its render subprocess died with the app. It becomes `interrupted` rather
    /// than being resumed silently or, worse, reported as completed.
    func restore() {
        jobs = store.load().map { job in
            var job = job
            if job.state == .running {
                job.state = .interrupted
                job.stageDescription = "Interrupted when the app quit"
                job.finishedAt = job.finishedAt ?? Date()
            }
            return job
        }
        activeJobID = nil
        persist()
    }

    // MARK: - Enqueue

    @discardableResult
    func enqueue(_ job: ProductionJob) -> ProductionJob {
        var job = job
        job.state = .waiting
        jobs.append(job)
        persist()
        startNextIfIdle()
        return job
    }

    /// "Generate Now": place at the head of the waiting jobs and start if the
    /// queue is idle. It never bypasses the single-render gate — a job already
    /// running is not interrupted.
    @discardableResult
    func enqueueNext(_ job: ProductionJob) -> ProductionJob {
        var job = job
        job.state = .waiting
        let insertionIndex = jobs.firstIndex { $0.state == .waiting } ?? jobs.count
        jobs.insert(job, at: insertionIndex)
        persist()
        startNextIfIdle()
        return job
    }

    // MARK: - Scheduling

    /// Starts the next waiting job when nothing is active. This is the only
    /// place a job becomes `running`, which is what makes the one-at-a-time
    /// guarantee a single line of reasoning rather than a property of timing.
    func startNextIfIdle() {
        guard !isPaused, activeJobID == nil else { return }
        guard let index = jobs.firstIndex(where: { $0.state == .waiting }) else { return }

        jobs[index].state = .running
        jobs[index].startedAt = Date()
        let job = jobs[index]
        activeJobID = job.id
        persist()

        guard let runner else { return }
        switch runner(job) {
        case .started:
            break
        case .failed(let reason):
            // Preflight failed at execution time — the file was deleted while
            // the job waited, the model went missing, and so on. Fail this job
            // and keep going: one bad job must not stall the queue.
            finish(jobID: job.id, state: .failed, reason: reason)
        }
    }

    // MARK: - Completion reporting

    func markCompleted(jobID: UUID, outputPath: String? = nil) {
        finish(jobID: jobID, state: .completed, outputPath: outputPath)
    }

    func markFailed(jobID: UUID, reason: String) {
        finish(jobID: jobID, state: .failed, reason: reason)
    }

    func markCancelled(jobID: UUID) {
        finish(jobID: jobID, state: .cancelled, reason: nil)
    }

    private func finish(
        jobID: UUID, state: ProductionJobState,
        reason: String? = nil, outputPath: String? = nil
    ) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        jobs[index].state = state
        jobs[index].finishedAt = Date()
        jobs[index].failureReason = reason
        if let outputPath { jobs[index].outputPath = outputPath }
        if activeJobID == jobID { activeJobID = nil }
        persist()
        onChange?()
        startNextIfIdle()
    }

    /// Coarse progress from the running mode, shown in the queue panel.
    func updateProgress(
        jobID: UUID, current: Int? = nil, total: Int? = nil, stage: String? = nil
    ) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        if let current { jobs[index].progressCurrent = current }
        if let total { jobs[index].progressTotal = total }
        if let stage { jobs[index].stageDescription = stage }
        persist()
        onChange?()
    }

    // MARK: - User actions

    /// Cancels a job. A waiting job simply stops being eligible; a running one
    /// is reported cancelled and the queue moves on. Stopping the underlying
    /// render is the caller's responsibility — the coordinator does not reach
    /// into the renderer.
    func cancel(jobID: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        guard !jobs[index].state.isTerminal else { return }
        finish(jobID: jobID, state: .cancelled)
    }

    /// Re-queues a failed or cancelled job from its original snapshot, so a
    /// retry renders what was queued rather than what the UI holds now.
    @discardableResult
    func retry(jobID: UUID) -> ProductionJob? {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }),
              jobs[index].canRetry || jobs[index].canRestart else { return nil }
        var retried = jobs[index]
        retried.id = UUID()
        retried.state = .waiting
        retried.startedAt = nil
        retried.finishedAt = nil
        retried.failureReason = nil
        retried.progressCurrent = nil
        retried.stageDescription = nil
        retried.createdAt = Date()
        jobs.append(retried)
        persist()
        startNextIfIdle()
        return retried
    }

    /// Removes a queue record. Never touches generated video or projects — a
    /// queue entry is bookkeeping, not the output.
    func remove(jobID: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        if jobs[index].state == .running { return }
        jobs.remove(at: index)
        persist()
        onChange?()
    }

    func moveUp(jobID: UUID) { move(jobID: jobID, offset: -1) }
    func moveDown(jobID: UUID) { move(jobID: jobID, offset: 1) }

    /// Reordering applies to waiting jobs only, and only swaps with another
    /// waiting job, so a running job can never be pushed around.
    private func move(jobID: UUID, offset: Int) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }),
              jobs[index].state == .waiting else { return }
        let waitingIndices = jobs.indices.filter { jobs[$0].state == .waiting }
        guard let position = waitingIndices.firstIndex(of: index) else { return }
        let targetPosition = position + offset
        guard targetPosition >= 0, targetPosition < waitingIndices.count else { return }
        jobs.swapAt(index, waitingIndices[targetPosition])
        persist()
        onChange?()
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        persistPauseState()
        if !paused { startNextIfIdle() }
    }

    // MARK: - Queries

    var activeJob: ProductionJob? {
        guard let activeJobID else { return nil }
        return jobs.first { $0.id == activeJobID }
    }

    var waitingCount: Int { jobs.filter { $0.state == .waiting }.count }

    var hasUnfinishedWork: Bool { jobs.contains { !$0.state.isTerminal } }

    /// Presentation-only projection for the active queue. The newest submitted
    /// work is easiest to find at the top, while scheduling continues to read
    /// the persisted `jobs` array in FIFO order. Terminal records stay persisted
    /// for provenance/output history but leave the active list, matching the
    /// normal render Queue.
    var activeDisplayJobs: [ProductionJob] {
        Self.activeDisplayJobs(from: jobs)
    }

    static func activeDisplayJobs(from jobs: [ProductionJob]) -> [ProductionJob] {
        jobs.enumerated()
            .filter { !$0.element.state.isTerminal }
            .sorted { lhs, rhs in
                if lhs.element.createdAt != rhs.element.createdAt {
                    return lhs.element.createdAt > rhs.element.createdAt
                }
                return lhs.offset > rhs.offset
            }
            .map(\.element)
    }

    func job(id: UUID) -> ProductionJob? { jobs.first { $0.id == id } }

    // MARK: - Persistence

    private func persist() {
        store.save(jobs)
        onChange?()
    }

    /// Pause is session state rather than queue content: a paused queue that is
    /// relaunched should start working again, not stay silently stopped.
    private func persistPauseState() {}
}
