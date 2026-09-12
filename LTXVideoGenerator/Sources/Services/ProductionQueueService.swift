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
    public var storageChecker: StorageHealthService
    /// True between admitting a job and observing it finish. Guards against the
    /// idle-looking moment before the renderer has picked the work up.
    private var isAwaitingCompletion = false
    /// Last run-level outcome reported by the generation service. Only a
    /// terminal outcome for the *active job's own project* is ever acted on.
    private var lastFilmRunEvent: FilmRunEvent?
    /// The settlement already applied to a run-scoped Storyboard job, so the
    /// latched value cannot be consumed twice.
    private var consumedStoryboardSettlementID: UUID?

    init(
        coordinator: ProductionQueueCoordinator = .shared,
        storageChecker: StorageHealthService = .shared
    ) {
        self.coordinator = coordinator
        self.storageChecker = storageChecker
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
        // Per-run execution state, persisted the moment a candidate settles and
        // before the next one starts. This is the authority for partial retry
        // and restart recovery — History is provenance and may be deleted.
        generationService.$lastRunSettlement
            .receive(on: RunLoop.main)
            .sink { [weak self] settlement in
                guard let self, let settlement,
                      let jobID = self.coordinator.activeJob?.id else { return }
                self.coordinator.recordRunOutcomes(jobID: jobID, outcomes: [settlement])
            }
            .store(in: &cancellables)
        coordinator.startNextIfIdle()
    }

    // MARK: - Enqueue

    @discardableResult
    func enqueue(_ job: ProductionJob) -> ProductionJob {
        let resolved = FeatureFlags.isEnabled(.autoQualityV1)
            ? Self.freezingPresetResolution(in: job)
            : job
        // Every submission path funnels through here, so run identity and a
        // concrete seed are stamped once, centrally, rather than depending on
        // each caller to remember.
        let frozen = RunProvenanceStamper.stamp(resolved)
        let queued = coordinator.enqueue(frozen)
        refresh()
        return queued
    }

    /// "Generate Now": ahead of the other waiting jobs, but still behind the
    /// single render slot — a running job is never preempted.
    @discardableResult
    func enqueueNext(_ job: ProductionJob) -> ProductionJob {
        let resolved = FeatureFlags.isEnabled(.autoQualityV1)
            ? Self.freezingPresetResolution(in: job)
            : job
        let frozen = RunProvenanceStamper.stamp(resolved)
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

    /// The compact renderer row belongs to the active production job. Routing
    /// its stop action through this boundary cancels the current HTTP request
    /// and drops the remaining requests from the same batch; cancelling only
    /// `GenerationService.currentRequest` previously let later batch items run
    /// and could leave the outer job falsely marked completed with no output.
    func cancelActiveRenderer() {
        if let activeJobID {
            cancel(jobID: activeJobID)
        } else {
            generationService?.cancelCurrent()
        }
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

        // Authoritative execution-time disk space preflight on output volume
        let userOutputDir = UserDefaults.standard.string(forKey: "outputDirectory") ?? ""
        let outputDir = userOutputDir.isEmpty ? AppStorageDirectory.videosDirectory : URL(fileURLWithPath: userOutputDir)
        let expectedTakes: Int
        switch job.kind {
        case .generate, .oneShot:
            expectedTakes = max(1, job.snapshot.pendingRequests.count)
        case .storyboard where job.snapshot.isRunScopedStoryboard:
            expectedTakes = max(1, job.snapshot.storyboardRuns
                .reduce(0) { $0 + $1.plan.shotCount })
        case .autoMovie where job.snapshot.isRunScopedMovie:
            expectedTakes = max(1, job.snapshot.movieRuns
                .reduce(0) { $0 + $1.plan.shotCount })
        case .storyboard, .autoMovie:
            let project = job.snapshot.projectID.flatMap { store.project(id: $0) }
            expectedTakes = max(1, project?.shots.count ?? 1)
        }
        let storageStatus = storageChecker.check(url: outputDir, for: .videoGeneration(expectedTakes: expectedTakes))
        if storageStatus.isBlocked {
            return .failed(storageStatus.message ?? "Not enough disk space for generation")
        }

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

        case .storyboard where job.snapshot.isRunScopedStoryboard:
            // New whole-Storyboard submissions. The discriminator is explicit
            // and lives on the immutable snapshot — never inferred from mutable
            // project state, which is what a run must be independent of.
            return startRunScopedStoryboard(job, generationService: generationService)

        case .autoMovie where job.snapshot.isRunScopedMovie:
            // New run-scoped Auto Movie. The discriminator lives on the
            // immutable snapshot; it is never inferred from project state.
            return startRunScopedMovie(job, generationService: generationService)

        case .storyboard, .autoMovie:
            // Legacy Storyboard jobs and legacy Auto Movie jobs keep the
            // existing project-driven path unchanged.
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
        case .storyboard where job.snapshot.isRunScopedStoryboard:
            advanceRunScopedStoryboard(job, generationService: generationService)

        case .autoMovie where job.snapshot.isRunScopedMovie:
            advanceRunScopedMovie(job, generationService: generationService)

        case .generate, .oneShot:
            // Every request was enqueued together, so an empty renderer really
            // does mean this job is terminal. Preserve backend failure as a
            // failed ProductionJob instead of reporting a missing video as a
            // successful queue completion.
            isAwaitingCompletion = false
            // The renderer publishes its queue and each run's settlement on two
            // separate subscriptions. This branch runs from the queue one and
            // reads live state, so when the LAST run finishes it can observe the
            // drained queue while that run's settlement is still in flight —
            // and the settlement is dropped afterwards because the job is no
            // longer active. Hand it to the close-out so a finished run is
            // never recorded as interrupted.
            closeOutUnsettledRuns(
                for: job,
                pendingSettlement: generationService.lastRunSettlement,
                failureReason: generationService.error?.localizedDescription)
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
    /// Applies one settlement to the run that produced it, then lets the job
    /// schedule its next shot.
    ///
    /// Both halves go through `StoryboardRunDriver`, which is the same code the
    /// tests drive — the duplicate-enqueue defect lived in this decision, not in
    /// the pure scheduler underneath it.
    private func advanceRunScopedStoryboard(
        _ job: ProductionJob,
        generationService: GenerationService
    ) {
        // `lastRunSettlement` is latched: once a shot settles it stays set for
        // the rest of the session. Consuming it on every poll is what let the
        // scheduler re-enter and re-dispatch the same attempt indefinitely.
        guard let settlement = generationService.lastRunSettlement,
              settlement.runID != consumedStoryboardSettlementID
        else { return }

        guard let updated = StoryboardRunDriver.applySettlement(
            settlement, to: job.snapshot.storyboardRuns) else {
            // Belongs to no in-flight attempt of this job: stale, or another
            // job's. Not consumed, so the job it does belong to can still see it.
            return
        }
        consumedStoryboardSettlementID = settlement.runID
        // Terminal state is persisted before anything else is scheduled.
        coordinator.updateStoryboardRuns(jobID: job.id, runs: updated)

        if StoryboardRunDriver.allSettled(updated) {
            isAwaitingCompletion = false
            if updated.allSatisfy({ $0.derivedState == .completed }) {
                coordinator.markCompleted(jobID: job.id)
            } else {
                coordinator.markFailed(
                    jobID: job.id,
                    reason: "One or more works did not finish. Retry to resume the unfinished ones.")
            }
            return
        }
        isAwaitingCompletion = false
        _ = startRunScopedStoryboard(
            coordinator.job(id: job.id) ?? job, generationService: generationService)
    }

    /// Starts the next piece of work for a run-scoped Auto Movie job: either the
    /// next shot of a run, or a run's final assembly once its shots are done.
    private func startRunScopedMovie(
        _ job: ProductionJob,
        generationService: GenerationService
    ) -> ProductionQueueCoordinator.StartOutcome {
        var runs = job.snapshot.movieRuns
        guard !runs.isEmpty else { return .failed("This job has no movie runs") }

        // Shots first, using the same run-local scheduler Storyboard proved.
        if let dispatch = StoryboardRunDriver.nextDispatch(in: runs) {
            let takeID = UUID()
            guard let request = MovieRunRequestBuilder.makeRequest(
                run: runs[dispatch.runIndex], shotID: dispatch.shotID, takeID: takeID,
                parameters: storyboardParameters(for: job)) else {
                var blocked = runs
                blocked[dispatch.runIndex].update(dispatch.shotID) {
                    $0.state = .dependencyBlocked
                    $0.failureReason = $0.failureReason
                        ?? "This shot's starting frame is unavailable, so it was not generated."
                }
                coordinator.updateMovieRuns(jobID: job.id, runs: blocked)
                return .failed("A shot's starting frame is unavailable.")
            }
            runs[dispatch.runIndex].update(dispatch.shotID) {
                $0.state = .running
                $0.dispatchedRequestID = request.id
                $0.dispatchedTakeID = takeID
            }
            // Persisted as running before the renderer is called.
            coordinator.updateMovieRuns(jobID: job.id, runs: runs)

            generationService.clearError()
            isAwaitingCompletion = true
            let done = runs.reduce(0) { total, run in
                total + run.shotStates.filter { $0.state == .completed }.count
            }
            let total = runs.reduce(0) { $0 + $1.plan.shotCount }
            coordinator.updateProgress(
                jobID: job.id, current: done + 1, total: total,
                stage: "作品 \(runs[dispatch.runIndex].batchIndex + 1) — Shot \(done + 1) / \(total)")
            generationService.addBatch([request])
            return .started
        }

        // No shot to run: a run whose shots are all done may now assemble.
        for index in runs.indices where !runs[index].isCancelled {
            guard runs[index].allShotsCompleted,
                  runs[index].assembly.state == .waiting || runs[index].assembly.state == .ready
            else { continue }
            // Freeze this run's own clips — never the project's global take
            // selection, which two runs would share.
            guard MovieAssemblyDriver.freezeClips(in: &runs[index]) else {
                coordinator.updateMovieRuns(jobID: job.id, runs: runs)
                continue
            }
            runs[index].assembly.state = .running
            runs[index].assembly.outputPath =
                MovieAssemblyDriver.outputURL(runID: runs[index].id).path
            // Persisted before assembly begins, so a crash cannot lose which
            // clips were chosen.
            coordinator.updateMovieRuns(jobID: job.id, runs: runs)
            coordinator.updateProgress(
                jobID: job.id,
                stage: "作品 \(runs[index].batchIndex + 1) — Assembling")
            runAssembly(jobID: job.id, runIndex: index)
            return .started
        }
        return .started
    }

    /// Assembles one run's frozen clips into its own film.
    private func runAssembly(jobID: UUID, runIndex: Int) {
        Task { [weak self] in
            guard let self else { return }
            guard var runs = self.coordinator.job(id: jobID)?.snapshot.movieRuns,
                  runs.indices.contains(runIndex) else { return }
            let run = runs[runIndex]
            let clips = run.assembly.clips.sorted { $0.order < $1.order }
            let output = run.assembly.outputPath
                ?? MovieAssemblyDriver.outputURL(runID: run.id).path
            let paths = clips.map(\.videoPath)

            // Wholly frozen inputs: the clips came from this run, the canvas and
            // audio policy from the spec frozen at submission. The source
            // project is never read here, so editing or deleting it cannot
            // change or break a queued work.
            guard let spec = run.plan.assemblySpec else {
                var latest = runs
                latest[runIndex].assembly.state = .failed
                latest[runIndex].assembly.failureReason =
                    "This work was queued without its assembly settings and cannot be assembled."
                self.coordinator.updateMovieRuns(jobID: jobID, runs: latest)
                self.settleRunScopedMovieIfDone(jobID: jobID)
                return
            }
            let result: Result<Void, Error> = await Task.detached(priority: .utility) {
                do {
                    try FileManager.default.createDirectory(
                        at: URL(fileURLWithPath: output).deletingLastPathComponent(),
                        withIntermediateDirectories: true)
                    _ = try FinalAssemblyService.assembleFrozen(
                        clipPaths: paths, spec: spec, outputPath: output)
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }.value

            guard var latest = self.coordinator.job(id: jobID)?.snapshot.movieRuns,
                  latest.indices.contains(runIndex) else { return }
            switch result {
            case .success:
                latest[runIndex].assembly.state = .completed
                latest[runIndex].assembly.outputPath = output
            case .failure(let error):
                latest[runIndex].assembly.state = .failed
                latest[runIndex].assembly.failureReason = error.localizedDescription
            }
            self.coordinator.updateMovieRuns(jobID: jobID, runs: latest)
            runs = latest
            self.settleRunScopedMovieIfDone(jobID: jobID)
        }
    }

    /// Applies one settlement to the movie run that produced it, then schedules
    /// that job's next piece of work.
    private func advanceRunScopedMovie(
        _ job: ProductionJob,
        generationService: GenerationService
    ) {
        guard let settlement = generationService.lastRunSettlement,
              settlement.runID != consumedStoryboardSettlementID
        else { return }
        guard let updated = StoryboardRunDriver.applySettlement(
            settlement, to: job.snapshot.movieRuns) else { return }
        consumedStoryboardSettlementID = settlement.runID
        coordinator.updateMovieRuns(jobID: job.id, runs: updated)

        isAwaitingCompletion = false
        if updated.allSatisfy({ $0.isSettled }) {
            settleRunScopedMovieIfDone(jobID: job.id)
            return
        }
        _ = startRunScopedMovie(
            coordinator.job(id: job.id) ?? job, generationService: generationService)
    }

    /// Marks the parent job terminal once every run has produced its film or
    /// definitively failed.
    private func settleRunScopedMovieIfDone(jobID: UUID) {
        guard let job = coordinator.job(id: jobID) else { return }
        let runs = job.snapshot.movieRuns
        guard !runs.isEmpty, runs.allSatisfy({ $0.isSettled }) else {
            if let service = generationService {
                _ = startRunScopedMovie(job, generationService: service)
            }
            return
        }
        isAwaitingCompletion = false
        let completed = runs.filter { $0.assembly.state == .completed }
        if completed.count == runs.count {
            coordinator.markCompleted(jobID: jobID, outputPath: completed.first?.assembly.outputPath)
        } else {
            coordinator.markFailed(
                jobID: jobID,
                reason: "One or more works did not finish. Retry to resume the unfinished ones.")
        }
    }

    /// Starts the next shot of a run-scoped Storyboard job.
    ///
    /// Deliberately never calls `AutoMovieRunCoordinator.advance`: that
    /// scheduler is project-global, so once one run finished a shot every other
    /// run would skip it. Scheduling here is decided per run, from that run's
    /// own `ShotRunState`.
    private func startRunScopedStoryboard(
        _ job: ProductionJob,
        generationService: GenerationService
    ) -> ProductionQueueCoordinator.StartOutcome {
        var runs = job.snapshot.storyboardRuns
        guard !runs.isEmpty else { return .failed("This job has no Storyboard runs") }

        guard let dispatch = StoryboardRunDriver.nextDispatch(in: runs) else {
            // Either an attempt is already in flight, or nothing is dispatchable
            // yet. Both are normal; neither may enqueue anything.
            return .started
        }

        let takeID = UUID()
        guard let request = StoryboardRunRequestBuilder.makeRequest(
            run: runs[dispatch.runIndex], shotID: dispatch.shotID, takeID: takeID,
            parameters: storyboardParameters(for: job)) else {
            // Fail closed: most often a continuation whose frozen starting frame
            // is missing or changed. Never fall back to the video, and never
            // quietly render this shot without its conditioning.
            var blocked = runs
            blocked[dispatch.runIndex].update(dispatch.shotID) {
                $0.state = .dependencyBlocked
                $0.failureReason = $0.failureReason
                    ?? "This shot's starting frame is unavailable, so it was not generated."
            }
            coordinator.updateStoryboardRuns(jobID: job.id, runs: blocked)
            return .failed("A shot's starting frame is unavailable.")
        }
        runs[dispatch.runIndex].update(dispatch.shotID) {
            $0.state = .running
            $0.dispatchedRequestID = request.id
            $0.dispatchedTakeID = takeID
        }
        // Persisted as running BEFORE the renderer is called, so a poll that
        // lands immediately after submission sees `running` rather than a state
        // that would make this same attempt dispatchable again.
        coordinator.updateStoryboardRuns(jobID: job.id, runs: runs)

        generationService.clearError()
        isAwaitingCompletion = true
        let done = runs.reduce(0) { total, run in
            total + run.shotStates.filter { $0.state == .completed }.count
        }
        let total = runs.reduce(0) { $0 + $1.plan.shotCount }
        coordinator.updateProgress(
            jobID: job.id, current: done + 1, total: total,
            stage: "作品 \(runs[dispatch.runIndex].batchIndex + 1) — Shot \(done + 1) / \(total)")
        generationService.addBatch([request])
        return .started
    }

    /// Render settings for a run-scoped Storyboard shot, taken from the frozen
    /// snapshot rather than from live project settings.
    private func storyboardParameters(for job: ProductionJob) -> GenerationParameters {
        job.snapshot.settings ?? GenerationParameters(
            numInferenceSteps: 15, guidanceScale: 3,
            width: 768, height: 512, numFrames: 121, fps: 24,
            seed: nil, vaeTilingMode: "auto", imageStrength: 1)
    }

    /// Closes out any run that never reported a settlement.
    ///
    /// Each candidate persists its own state as it finishes (see the
    /// `$lastRunSettlement` subscription). This only fills in runs the renderer
    /// never reached — a batch abandoned mid-flight — so that every run in a
    /// terminal job has a recorded state rather than an absent one.
    ///
    /// Deliberately does **not** consult History: a completed run whose History
    /// write was lost to a crash must still count as completed, and a user
    /// deleting History must not cause finished work to be rendered again.
    private func closeOutUnsettledRuns(
        for job: ProductionJob,
        pendingSettlement: RunOutcomeRecord?,
        failureReason: String?
    ) {
        let outcomes = TerminalRunOutcomeResolver.resolve(
            requests: job.snapshot.pendingRequests,
            recorded: coordinator.job(id: job.id)?.snapshot.runOutcomes ?? [],
            pendingSettlement: pendingSettlement,
            failureReason: failureReason)
        guard !outcomes.isEmpty else { return }
        coordinator.recordRunOutcomes(jobID: job.id, outcomes: outcomes)
    }

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

/// Decides what every logical run of a terminal Generate/One Shot job did.
///
/// Execution truth is the run's settlement; History is provenance and is never
/// consulted here. A run that never received a terminal settlement is closed
/// out (interrupted, or failed when the job failed), but a settlement that the
/// renderer already produced and that has not been recorded yet is adopted
/// first: the queue subscription can reach this point before the settlement
/// subscription delivers, which previously recorded a finished run as
/// interrupted and then dropped its settlement.
///
/// A settlement is adopted only when it belongs to one of this job's runs, that
/// run has no outcome yet, and it is for the run's current attempt — so a stale
/// settlement from an earlier attempt, a duplicate, or one from another run
/// cannot resurrect or overwrite anything.
enum TerminalRunOutcomeResolver {
    static func resolve(
        requests: [GenerationRequest],
        recorded: [RunOutcomeRecord],
        pendingSettlement: RunOutcomeRecord?,
        failureReason: String?
    ) -> [RunOutcomeRecord] {
        guard !requests.isEmpty else { return [] }
        var settled = Set(recorded.map(\.runID))
        var outcomes: [RunOutcomeRecord] = []

        if let settlement = pendingSettlement,
           !settled.contains(settlement.runID),
           let request = requests.first(where: { $0.id == settlement.runID }),
           settlement.attemptNumber == (request.attemptNumber ?? 1) {
            outcomes.append(settlement)
            settled.insert(settlement.runID)
        }

        for request in requests where !settled.contains(request.id) {
            outcomes.append(RunOutcomeRecord(
                runID: request.id,
                outcome: failureReason == nil ? .interrupted : .failed,
                attemptNumber: request.attemptNumber ?? 1,
                failureReason: failureReason))
        }
        return outcomes
    }
}
