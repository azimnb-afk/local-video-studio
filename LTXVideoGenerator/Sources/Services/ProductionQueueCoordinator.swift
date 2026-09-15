import Foundation

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

/// One work of a multi-work job, as the queue row shows it.
///
/// A job of 作品数 N used to present as a single state and a single reason, so
/// "something failed" could not say which work, and a failed parent read as if
/// every work had failed. Every surface already records per-work truth — Generate
/// and One Shot per request (`batchIndex` + `runOutcomes`, matched by request
/// id), Storyboard and Auto Movie per run (`batchIndex` + shot and assembly
/// state) — so this is derived on demand and never persisted.
struct ProductionWorkDisplayItem: Equatable, Identifiable {
    enum State: Equatable {
        case waiting, running, completed, failed, interrupted, cancelled
        /// Never ran, and the parent stopped for a reason that is not the
        /// work's own. Said plainly rather than guessed at.
        case notRun
    }

    /// 0-based, matching `batchIndex`. The UI is 1-based.
    let index: Int
    let state: State
    /// Sanitised for display. Only a work's own reason, never the parent's.
    let failureReason: String?
    let hasOutput: Bool

    var id: Int { index }
    var label: String { "作品 \(index + 1)" }
}

enum ProductionWorkPresenter {

    /// Per-work rows for a job, or `[]` when there is nothing to break down:
    /// a single work, or a legacy job that recorded no per-work state.
    ///
    /// - Parameter activeRequestID: the render request currently in flight,
    ///   so a running Generate/One Shot work is identified from the renderer
    ///   rather than inferred from order.
    static func items(for job: ProductionJob, activeRequestID: UUID? = nil) -> [ProductionWorkDisplayItem] {
        let snapshot = job.snapshot
        if !snapshot.storyboardRuns.isEmpty {
            guard snapshot.storyboardRuns.count > 1 else { return [] }
            return snapshot.storyboardRuns
                .sorted { $0.batchIndex < $1.batchIndex }
                .map { storyboardItem($0, parent: job.state) }
        }
        if !snapshot.movieRuns.isEmpty {
            guard snapshot.movieRuns.count > 1 else { return [] }
            return snapshot.movieRuns
                .sorted { $0.batchIndex < $1.batchIndex }
                .map { movieItem($0, parent: job.state) }
        }
        return requestItems(job, activeRequestID: activeRequestID)
    }

    /// Whether the parent's own reason is only a restatement of what the works
    /// already show — `RunFailureSummary` builds it from them — so it is not
    /// printed twice.
    static func parentReasonIsCoveredByWorks(_ job: ProductionJob, items: [ProductionWorkDisplayItem]) -> Bool {
        guard let parent = job.failureReason.map(ProductionFailurePresenter.displayReason) else {
            return false
        }
        return items.contains { item in
            guard let reason = item.failureReason else { return false }
            return parent == reason || parent.hasPrefix(reason)
        }
    }

    // MARK: Generate / One Shot

    private static func requestItems(_ job: ProductionJob, activeRequestID: UUID?) -> [ProductionWorkDisplayItem] {
        let requests = job.snapshot.pendingRequests
        guard requests.count > 1 else { return [] }
        // Matched by request id only. An outcome whose run id is not one of
        // this job's requests belongs to some other job and is ignored.
        let ids = Set(requests.map(\.id))
        let outcomes = Dictionary(
            job.snapshot.runOutcomes.filter { ids.contains($0.runID) }.map { ($0.runID, $0) },
            uniquingKeysWith: { _, latest in latest })
        // A pre-multi-queue job recorded neither order nor outcomes; once it is
        // finished there is no per-work truth to show.
        let recordedPerWork = job.snapshot.snapshotVersion >= 2 || !outcomes.isEmpty
        guard recordedPerWork || !job.state.isTerminal else { return [] }

        let ordered = requests.enumerated().sorted { lhs, rhs in
            (lhs.element.batchIndex ?? lhs.offset) < (rhs.element.batchIndex ?? rhs.offset)
        }
        return ordered.enumerated().map { position, entry in
            let request = entry.element
            let index = request.batchIndex ?? position
            guard let outcome = outcomes[request.id] else {
                let live: ProductionWorkDisplayItem.State =
                    request.id == activeRequestID ? .running : .waiting
                return ProductionWorkDisplayItem(
                    index: index, state: unfinished(live, parent: job.state),
                    failureReason: nil, hasOutput: false)
            }
            switch outcome.outcome {
            case .completed:
                return ProductionWorkDisplayItem(
                    index: index, state: .completed, failureReason: nil,
                    hasOutput: !(outcome.outputPath ?? "").isEmpty)
            case .failed:
                // Stopped because a sibling hit a batch-wide failure: it never
                // ran, and saying "failed" would imply it was tried.
                return ProductionWorkDisplayItem(
                    index: index, state: outcome.notAttempted == true ? .notRun : .failed,
                    failureReason: outcome.failureReason.map(ProductionFailurePresenter.displayReason),
                    hasOutput: false)
            case .cancelled:
                return ProductionWorkDisplayItem(index: index, state: .cancelled, failureReason: nil, hasOutput: false)
            case .interrupted:
                return ProductionWorkDisplayItem(index: index, state: .interrupted, failureReason: nil, hasOutput: false)
            case .queued, .running:
                let live: ProductionWorkDisplayItem.State =
                    request.id == activeRequestID ? .running : .waiting
                return ProductionWorkDisplayItem(
                    index: index, state: unfinished(live, parent: job.state),
                    failureReason: nil, hasOutput: false)
            }
        }
    }

    // MARK: Storyboard / Auto Movie

    private static func storyboardItem(_ run: StoryboardRun, parent: ProductionJobState) -> ProductionWorkDisplayItem {
        let reason = shotFailureReason(run.shotStates)
        let state: ProductionWorkDisplayItem.State
        switch run.derivedState {
        case .cancelled: state = .cancelled
        case .completed: state = .completed
        case .failed, .dependencyBlocked:
            state = notAttempted(run.shotStates) ? .notRun : .failed
        case .interrupted: state = .interrupted
        case .running: state = unfinished(.running, parent: parent)
        case .queued, .waitingForDependency: state = unfinished(.waiting, parent: parent)
        }
        return ProductionWorkDisplayItem(
            index: run.batchIndex, state: state,
            failureReason: state == .failed || state == .notRun ? reason : nil,
            hasOutput: state == .completed
                && run.shotStates.allSatisfy { !($0.outputPath ?? "").isEmpty })
    }

    private static func movieItem(_ run: MovieRun, parent: ProductionJobState) -> ProductionWorkDisplayItem {
        // A movie is done when its film exists, not when its shots do.
        let assembly = run.assembly
        let state: ProductionWorkDisplayItem.State
        var reason: String?
        if run.isCancelled || assembly.state == .cancelled {
            state = .cancelled
        } else if assembly.state == .completed {
            state = .completed
        } else {
            switch run.derivedShotState {
            case .failed, .dependencyBlocked:
                state = notAttempted(run.shotStates) ? .notRun : .failed
                reason = shotFailureReason(run.shotStates)
            case .interrupted:
                state = .interrupted
            case .cancelled:
                state = .cancelled
            case .running:
                state = unfinished(.running, parent: parent)
            case .completed:
                switch assembly.state {
                case .failed:
                    state = .failed
                    reason = assembly.failureReason.map(ProductionFailurePresenter.displayReason)
                case .interrupted:
                    state = .interrupted
                case .running, .ready:
                    state = unfinished(.running, parent: parent)
                case .waiting, .completed, .cancelled:
                    state = unfinished(.waiting, parent: parent)
                }
            case .queued, .waitingForDependency:
                state = unfinished(.waiting, parent: parent)
            }
        }
        return ProductionWorkDisplayItem(
            index: run.batchIndex, state: state, failureReason: reason,
            hasOutput: state == .completed && !(assembly.outputPath ?? "").isEmpty)
    }

    // MARK: Shared

    /// A work that had not finished is only waiting or running while its parent
    /// is still live. Once the parent has stopped, the work stopped with it.
    private static func unfinished(
        _ live: ProductionWorkDisplayItem.State, parent: ProductionJobState
    ) -> ProductionWorkDisplayItem.State {
        switch parent {
        case .waiting: return .waiting
        case .running: return live
        case .interrupted: return .interrupted
        case .cancelled: return .cancelled
        case .failed, .completed: return .notRun
        }
    }

    /// A work stopped by a sibling's batch-wide failure: nothing in it failed or
    /// ran, and at least one shot was marked not attempted.
    private static func notAttempted(_ shots: [ShotRunState]) -> Bool {
        shots.contains { $0.notAttempted == true }
            && !shots.contains { $0.state == .failed || $0.state == .running || $0.state == .completed }
    }

    private static func shotFailureReason(_ shots: [ShotRunState]) -> String? {
        let failing = shots.first { $0.state == .failed }
            ?? shots.first { $0.state == .dependencyBlocked }
        return failing?.failureReason.map(ProductionFailurePresenter.displayReason)
    }
}

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
    ///
    /// A partly-successful batch is retried *partly*: candidates that already
    /// produced a video are carried forward as recorded outcomes and are not
    /// rendered again. Re-running them would duplicate their History entries and
    /// charge the user a second time for work that succeeded.
    /// Whether `job` offers Retry / Restart now: it is failed, cancelled or
    /// interrupted, and it is the latest attempt of its lineage.
    ///
    /// Retry copies a job — the same request ids, or the same run ids, at the
    /// next attempt — and leaves the original in the queue. Judged by its own
    /// state alone, the original kept offering Retry after its retry had run,
    /// and a second Retry built from its snapshot produced the same attempt
    /// again: two jobs held one request at one attempt, a settlement matched
    /// both, and its result was never recorded. Only the newest job of a
    /// lineage retries, so attempts stay one straight line. Derived from the
    /// persisted snapshots, it holds after a relaunch too.
    static func isRetryEligible(_ job: ProductionJob, in jobs: [ProductionJob]) -> Bool {
        (job.canRetry || job.canRestart) && supersedingJob(of: job, in: jobs) == nil
    }

    /// A later attempt of the same work than `job`, if the queue holds one.
    ///
    /// Jobs share a lineage when they share a request id (Generate / One Shot)
    /// or a run id (Storyboard / Auto Movie). The later one is the one further
    /// along — a higher request attempt, or more shot and assembly attempts on
    /// the run — and, only when equal, the one queued after.
    static func supersedingJob(of job: ProductionJob, in jobs: [ProductionJob]) -> ProductionJob? {
        let mine = lineageProgress(of: job)
        guard !mine.isEmpty else { return nil }
        let myIndex = jobs.firstIndex { $0.id == job.id } ?? jobs.count
        for (index, other) in jobs.enumerated() where other.id != job.id {
            let theirs = lineageProgress(of: other)
            for (key, progress) in mine {
                guard let otherProgress = theirs[key] else { continue }
                if otherProgress > progress || (otherProgress == progress && index > myIndex) {
                    return other
                }
            }
        }
        return nil
    }

    private static func lineageProgress(of job: ProductionJob) -> [String: Int] {
        var progress: [String: Int] = [:]
        for request in job.snapshot.pendingRequests {
            progress["request:\(request.id)"] = request.attemptNumber ?? 1
        }
        for run in job.snapshot.storyboardRuns {
            progress["run:\(run.id)"] = run.shotStates.reduce(0) { $0 + $1.attemptNumber }
        }
        for run in job.snapshot.movieRuns {
            progress["run:\(run.id)"] = run.shotStates.reduce(0) { $0 + $1.attemptNumber }
                + run.assembly.attemptNumber
        }
        return progress
    }

    func isRetryEligible(jobID: UUID) -> Bool {
        guard let job = job(id: jobID) else { return false }
        return Self.isRetryEligible(job, in: jobs)
    }

    @discardableResult
    func retry(jobID: UUID) -> ProductionJob? {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }),
              Self.isRetryEligible(jobs[index], in: jobs) else { return nil }
        var retried = jobs[index]

        if !retried.snapshot.pendingRequests.isEmpty {
            let plan = RunRetryPlanner.plan(
                requests: retried.snapshot.pendingRequests,
                outcomes: retried.snapshot.runOutcomes)
            // Nothing left to do: every run already succeeded. Leave the
            // original job alone rather than queueing an empty render.
            if plan.isEmpty { return nil }
            // Never an attempt some job in the queue already holds.
            retried.snapshot.pendingRequests = plan.requestsToRun.map { request in
                var request = request
                let held = jobs.flatMap(\.snapshot.pendingRequests)
                    .filter { $0.id == request.id }.map { $0.attemptNumber ?? 1 }.max() ?? 0
                request.attemptNumber = max(request.attemptNumber ?? 1, held + 1)
                return request
            }
            retried.snapshot.runOutcomes = plan.preservedOutcomes
        }
        // Run-scoped jobs carry per-shot execution state in the snapshot, so a
        // verbatim copy also copies a shot left `running` with an in-flight
        // request id (the app quit mid-render) or a `failed` one. The scheduler
        // will not dispatch past the first or re-dispatch the second on its
        // own, and nothing else would settle the job: it would sit "running"
        // with nothing running, holding every job behind it.
        retried.snapshot.storyboardRuns = retried.snapshot.storyboardRuns.map {
            Self.resumable($0)
        }
        retried.snapshot.movieRuns = retried.snapshot.movieRuns.map { run in
            var run = Self.resumable(run)
            // An assembly the app quit during is as unfinished as a shot.
            if run.assembly.state == .running { run.assembly.state = .interrupted }
            MovieAssemblyDriver.retryAssembly(in: &run)
            return run
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

    /// Reopens exactly the shots a Retry or Restart is for: ones that failed,
    /// were blocked, interrupted or cancelled, or were still running when
    /// execution stopped. Each becomes a new attempt through the scheduler's own
    /// Retry, which keeps seeds and frozen inputs and clears the stale
    /// reservation so a late settlement for the old attempt cannot be applied.
    /// Completed shots and shots that never started are left exactly as they
    /// were.
    ///
    /// A run stopped by `StoryboardRunScheduler.cancel` is reopened too. Every
    /// consumer reads a cancelled run as settled, so carrying it forward gave
    /// the new attempt unfinished work it could never dispatch: the job ended
    /// at once without rendering anything, however often Retry was pressed.
    private static func resumable<Run: RunScopedShotExecution>(_ run: Run) -> Run {
        var run = run
        run.clearCancelled()
        for shot in run.orderedShots {
            guard let state = run.state(of: shot.id)?.state,
                  state.isRetryable || state == .running || state == .cancelled else { continue }
            StoryboardRunScheduler.retry(in: &run, shotID: shot.id)
        }
        return run
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

    /// Whether this exact assembly attempt is still the one its job is waiting
    /// on: the job running, the run with that id, its assembly running at that
    /// attempt. Checked before an attempt launches ffmpeg and before its movie
    /// is adopted, as well as by `applyAssemblyResult`.
    func acceptsAssemblyResult(jobID: UUID, runID: UUID, attempt: Int) -> Bool {
        guard let job = job(id: jobID), job.state == .running,
              let run = job.snapshot.movieRuns.first(where: { $0.id == runID }) else { return false }
        return run.assembly.state == .running && run.assembly.attemptNumber == attempt
    }

    /// The result of one Auto Movie final assembly.
    enum AssemblyResult: Equatable {
        case completed(outputPath: String)
        case failed(reason: String)
    }

    /// Records a finished final assembly. Returns whether it was applied; the
    /// caller settles the job only when it was.
    ///
    /// Assembly runs ffmpeg in a detached task, so a result can still arrive
    /// after the user cancelled — ffmpeg finishing before its termination, or
    /// a cancelled attempt reporting that it stopped. It used to be
    /// written by run index with no other check and the job then settled —
    /// turning a cancelled job completed or failed, attaching the late film,
    /// or handing the cancelled job back to dispatch its unfinished works.
    ///
    /// A result now applies only to the exact execution that produced it: a job
    /// still running, the run with that id, and an assembly still running at
    /// that attempt. Anything else — a cancelled or already-settled job, a
    /// Retry's newer attempt, a duplicate, an assembly never dispatched — is
    /// ignored, and the file that attempt wrote is its caller's to remove
    /// (`MovieAssemblyDriver.discardCandidate`).
    @discardableResult
    func applyAssemblyResult(
        jobID: UUID, runID: UUID, attempt: Int, result: AssemblyResult
    ) -> Bool {
        guard acceptsAssemblyResult(jobID: jobID, runID: runID, attempt: attempt),
              let job = job(id: jobID) else { return false }
        var runs = job.snapshot.movieRuns
        guard let runIndex = runs.firstIndex(where: { $0.id == runID }) else { return false }
        switch result {
        case .completed(let outputPath):
            runs[runIndex].assembly.state = .completed
            runs[runIndex].assembly.outputPath = outputPath
        case .failed(let reason):
            runs[runIndex].assembly.state = .failed
            runs[runIndex].assembly.failureReason = reason
        }
        updateMovieRuns(jobID: jobID, runs: runs)
        return true
    }

    /// Records one settlement published by the renderer into the job that
    /// dispatched it.
    ///
    /// The queue receives settlements a main-queue turn after they are
    /// published, and this used to write into whichever job was active at that
    /// moment. When a job's last run finished, the queue could close that job
    /// and start the next before the settlement arrived — so the run's real
    /// outcome was recorded into the *next* job, and its own job was left with a
    /// close-out "interrupted" that a Retry would render again. Real data shows
    /// exactly that pair.
    ///
    /// A settlement is therefore matched to its owner by identity, never by
    /// timing: a request the job submitted with that id at that attempt, or a
    /// run-scoped shot that dispatched that request. A settlement nobody owns —
    /// the job was dismissed, or it is stale — is dropped rather than handed to
    /// someone else. Only outcomes are recorded; a job's own state is untouched.
    func recordSettlement(_ settlement: RunOutcomeRecord) {
        guard let jobID = Self.owner(of: settlement, in: jobs) else { return }
        recordRunOutcomes(jobID: jobID, outcomes: [settlement])
    }

    /// The job whose execution produced `settlement`, or nil when no job — or
    /// more than one — can be shown to own it.
    static func owner(of settlement: RunOutcomeRecord, in jobs: [ProductionJob]) -> UUID? {
        let owners = jobs.filter { job in
            // Retry keeps a request's id and raises its attempt, so the id
            // alone would match both the original and the retry.
            job.snapshot.pendingRequests.contains {
                $0.id == settlement.runID && ($0.attemptNumber ?? 1) == settlement.attemptNumber
            }
            // Run-scoped requests are minted per dispatch; the shot that
            // dispatched one records its id.
            || job.snapshot.storyboardRuns.contains { run in
                run.shotStates.contains { $0.dispatchedRequestID == settlement.runID }
            }
            || job.snapshot.movieRuns.contains { run in
                run.shotStates.contains { $0.dispatchedRequestID == settlement.runID }
            }
        }
        return owners.count == 1 ? owners[0].id : nil
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
        // Failures only: an interrupted job is not a failure, and the button
        // says "Failed".
        jobs.removeAll { $0.state == .failed }
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
    /// The exceptions are a failure, and an interrupted job Restart could
    /// still finish; each stays until dismissed — see
    /// `ProductionJob.staysVisibleWhenTerminal`. Without that, a job's failure reason
    /// was set and hidden in the same state transition, so the queue row's
    /// reason text could never render for the case it was written for.
    var activeDisplayJobs: [ProductionJob] {
        Self.activeDisplayJobs(from: jobs)
    }

    static func activeDisplayJobs(from jobs: [ProductionJob]) -> [ProductionJob] {
        jobs.enumerated()
            .filter { !$0.element.state.isTerminal
                || $0.element.staysVisibleWhenTerminal }
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
