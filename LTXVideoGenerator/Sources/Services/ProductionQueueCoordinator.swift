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
/// Turns a stored failure reason into text safe to show in the queue.
///
/// Failures now stay on screen until dismissed, which surfaced old backend
/// reasons that embed raw subprocess output — Python tracebacks with
/// `File "/Users/<name>/…"`, model directories on external volumes. The stored
/// reason is diagnostic truth and is never rewritten; only what the panel
/// renders is shortened. A private absolute path keeps its last component,
/// which is the part that identifies the file, and loses the part that
/// identifies the user and their disk layout.
///
/// Deliberately narrow: only absolute paths under the roots that carry a
/// username or machine-local layout are touched. URLs, relative paths and
/// ordinary prose are left alone, and the app's own messages (which already
/// name files by last component) pass through unchanged.
enum ProductionFailurePresenter {

    private static let roots = "(?:Users|private|var|tmp|Volumes)"

    /// `File "/Users/a/b.py"` — the quote bounds the path, so spaces inside it
    /// (`Application Support`) are handled exactly.
    private static let quoted = try! NSRegularExpression(
        pattern: "\"(/\(roots)/[^\"\\n]*)\"")

    /// An unquoted path. It cannot start mid-token, so `https://host/Users/x`
    /// and `file:///Users/x` are not treated as filesystem paths. A following
    /// space-separated token is absorbed while it still looks like more path
    /// (`/Volumes/ELECOM USBHDD/AIModels/…`); without that a volume or folder
    /// name containing a space would cut the match short and leak the rest.
    private static let unquoted = try! NSRegularExpression(
        pattern: "(?<![\\w:/.~-])/\(roots)/[^\\s\"'()<>\\[\\]]*"
            + "(?: [^\\s\"'()<>\\[\\]/]+/[^\\s\"'()<>\\[\\]]*)*")

    static func displayReason(_ reason: String) -> String {
        var text = replace(quoted, in: reason) { match in "\"\(shortened(match))\"" }
        text = replace(unquoted, in: text) { match in
            // Sentence punctuation after a path belongs to the sentence.
            let trailing = match.reversed().prefix { ".,;:".contains($0) }
            let path = String(match.dropLast(trailing.count))
            return shortened(path) + String(trailing.reversed())
        }
        return text
    }

    /// Keeps the last component. `/Users/<name>` and `/Volumes/<name>` on
    /// their own would make that component the username or disk name, so
    /// they collapse entirely.
    static func shortened(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard let last = parts.last else { return "…" }
        if let root = parts.first, root == "Users" || root == "Volumes", parts.count <= 2 {
            return "…"
        }
        return "…/\(last)"
    }

    private static func replace(
        _ regex: NSRegularExpression, in text: String, with transform: (String) -> String
    ) -> String {
        let ns = text as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let full = match.range
            // The quoted pattern captures the path inside the quotes.
            let pathRange = match.numberOfRanges > 1 ? match.range(at: 1) : full
            result += ns.substring(with: NSRange(location: cursor, length: full.location - cursor))
            result += match.numberOfRanges > 1
                ? transform(ns.substring(with: pathRange))
                : transform(ns.substring(with: full))
            cursor = full.location + full.length
        }
        result += ns.substring(from: cursor)
        return result
    }
}

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
    ///
    /// A partly-successful batch is retried *partly*: candidates that already
    /// produced a video are carried forward as recorded outcomes and are not
    /// rendered again. Re-running them would duplicate their History entries and
    /// charge the user a second time for work that succeeded.
    @discardableResult
    func retry(jobID: UUID) -> ProductionJob? {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }),
              jobs[index].canRetry || jobs[index].canRestart else { return nil }
        var retried = jobs[index]

        if !retried.snapshot.pendingRequests.isEmpty {
            let plan = RunRetryPlanner.plan(
                requests: retried.snapshot.pendingRequests,
                outcomes: retried.snapshot.runOutcomes)
            // Nothing left to do: every run already succeeded. Leave the
            // original job alone rather than queueing an empty render.
            if plan.isEmpty { return nil }
            retried.snapshot.pendingRequests = plan.requestsToRun
            retried.snapshot.runOutcomes = plan.preservedOutcomes
        }

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

    /// Persists run-scoped Storyboard state. Called on every meaningful shot
    /// transition, and always before a backend invocation, so recovery reads
    /// what actually happened rather than re-deriving it.
    func updateStoryboardRuns(jobID: UUID, runs: [StoryboardRun]) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        jobs[index].snapshot.storyboardRuns = runs
        persist()
    }

    /// Persists run-scoped Auto Movie state, including the frozen assembly clip
    /// list, on every meaningful transition.
    func updateMovieRuns(jobID: UUID, runs: [MovieRun]) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        jobs[index].snapshot.movieRuns = runs
        persist()
    }

    /// Records what each logical run did, so a later retry can skip the ones
    /// that succeeded. Persisted, so the knowledge survives an app restart.
    func recordRunOutcomes(jobID: UUID, outcomes: [RunOutcomeRecord]) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        var merged = jobs[index].snapshot.runOutcomes
        for outcome in outcomes {
            if let existing = merged.firstIndex(where: { $0.runID == outcome.runID }) {
                merged[existing] = outcome
            } else {
                merged.append(outcome)
            }
        }
        jobs[index].snapshot.runOutcomes = merged
        persist()
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

    /// Dismisses every failure still on display in one step.
    ///
    /// Failures stay visible until dismissed, and a long-lived queue can hold
    /// dozens from old runs; clearing them one × at a time is not a reasonable
    /// ask. This is exactly `remove(jobID:)` applied to those jobs — the same
    /// bookkeeping-only removal, persisted once — and it touches nothing else:
    /// no waiting, running, completed or cancelled record, and never any video.
    func removeFailed() {
        let before = jobs.count
        jobs.removeAll { $0.state.staysVisibleWhenTerminal }
        guard jobs.count != before else { return }
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

    /// Whether the header's Pause/Resume control means anything.
    ///
    /// Pause only stops *new* jobs from starting, so it has something to act
    /// on only while a job is waiting or running. Once failures stay visible
    /// until dismissed, the list is often non-empty with nothing pausable in
    /// it, and a Pause button there reads as a control over those failures.
    ///
    /// A paused queue keeps its Resume visible regardless: hiding it would hide
    /// the one fact that explains why the next submission does not start.
    static func showsPauseControl(jobs: [ProductionJob], isPaused: Bool) -> Bool {
        isPaused || jobs.contains { !$0.state.isTerminal }
    }

    /// Presentation-only projection for the active queue. The newest submitted
    /// work is easiest to find at the top, while scheduling continues to read
    /// the persisted `jobs` array in FIFO order. Terminal records stay persisted
    /// for provenance/output history but leave the active list, matching the
    /// normal render Queue.
    ///
    /// The one exception is a failure, which stays until the user dismisses it
    /// — see `staysVisibleWhenTerminal`. Without that, a job's failure reason
    /// was set and hidden in the same state transition, so the queue row's
    /// reason text could never render for the case it was written for.
    var activeDisplayJobs: [ProductionJob] {
        Self.activeDisplayJobs(from: jobs)
    }

    static func activeDisplayJobs(from jobs: [ProductionJob]) -> [ProductionJob] {
        jobs.enumerated()
            .filter { !$0.element.state.isTerminal
                || $0.element.state.staysVisibleWhenTerminal }
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
