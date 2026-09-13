import Foundation

/// Run-scoped execution state for Storyboard.
///
/// `FilmProject` stays what it is: the editable authoring document. A
/// `StoryboardRun` is the frozen thing that was actually submitted, and it owns
/// everything execution needs — the composition, per-shot state, the run-local
/// take map and the resolved dependencies. It is persisted inside the production
/// queue snapshot, so recovery reads it rather than re-deriving anything from
/// the project the user has meanwhile kept editing.
///
/// ## Why a separate scheduler exists
///
/// The existing `AutoMovieRunCoordinator.advance` is project-scoped in two ways
/// that make concurrent runs of one Storyboard impossible, not merely leaky:
///
/// - `nextShotIndexNeedingGeneration` picks the first shot with no **completed
///   take**, looking at `shot.takes` across the whole project. Once run A
///   finishes shot 1, run B skips shot 1 entirely and continues from A's output.
/// - `hasGenerationInFlight` is likewise project-wide, so run A rendering makes
///   run B report "waiting" forever.
///
/// Run-local take *selection* alone does not fix either. Scheduling has to be
/// run-local too, which is what `StoryboardRunScheduler` below provides. Auto
/// Movie keeps using the old coordinator untouched.

// MARK: - Frozen composition

/// One shot of a submitted Storyboard, frozen at submission.
///
/// Deliberately narrow: only what execution needs. Authoring fields the renderer
/// never reads are not copied, because copying them would invite the frozen plan
/// and the project to drift into two half-truths.
struct FrozenShotPlan: Codable, Equatable, Identifiable {
    /// The logical shot this plan came from. Stable across runs, so two runs of
    /// the same Storyboard share shot ids while owning separate takes.
    var id: UUID
    var index: Int
    var title: String
    var compiledPrompt: String
    var durationSeconds: Double

    /// Where this shot's first frame comes from. Mutually exclusive by
    /// construction — see `StartSource`.
    var startSource: StartSource
    /// Managed, project-relative path of an explicitly chosen starting image.
    var explicitStartImageRelativePath: String?
    /// Submission-time content hash of that image, so a file edited while the
    /// run waited is detected instead of silently rendered.
    var explicitStartImageContentHash: String?
    /// Optional ending image (H3 Standard only — see `H3EndingImageCapability`).
    var endingImagePath: String?
    var endingImageContentHash: String?

    /// Frozen per-shot seed. AUTO mode allocates a distinct one per run.
    var seed: Int

    var characterIDs: [UUID]
    var startingImageReferenceAssetID: UUID?

    /// Mutually exclusive origin of the first frame.
    ///
    /// Kept separate from Ending Image and from character/reference
    /// conditioning: those are different axes and collapsing them into one enum
    /// would make "continue from the previous shot with a character anchor"
    /// unrepresentable.
    enum StartSource: String, Codable, Equatable {
        case none
        case explicitImage
        case previousShotOutput
    }
}

/// The whole submitted composition, frozen once per submit and copied verbatim
/// into every run of the batch.
struct FrozenStoryboardPlan: Codable, Equatable {
    var projectID: UUID
    var title: String
    var shots: [FrozenShotPlan]
    var modelID: String
    var preset: String?
    var audioEnabled: Bool
    var textEncoderID: String?
    /// Director/planner output, produced once before expansion. N runs never
    /// mean N planning invocations.
    var directorMode: String?
    var openingReferenceRelativePath: String?
    var characterAnchorCharacterID: UUID?
    var characterAnchorAssetID: UUID?

    var shotCount: Int { shots.count }
}

// MARK: - Per-shot execution state

/// Execution state of one shot inside one run.
struct ShotRunState: Codable, Equatable, Identifiable {
    enum State: String, Codable, Equatable {
        case queued
        case waitingForDependency
        case running
        case completed
        case failed
        case cancelled
        case interrupted
        case dependencyBlocked

        /// Work the scheduler may still dispatch on its own.
        ///
        /// `failed` and `interrupted` are deliberately excluded: re-running them
        /// is Retry, which is an explicit user or recovery action that raises
        /// `attemptNumber`. Treating them as dispatchable let ordinary polling
        /// silently re-render a failed shot forever.
        var needsExecution: Bool {
            switch self {
            case .completed, .cancelled, .dependencyBlocked, .failed, .interrupted:
                return false
            case .queued, .waitingForDependency, .running:
                return true
            }
        }

        /// States an explicit Retry may revive.
        var isRetryable: Bool {
            switch self {
            case .failed, .interrupted, .dependencyBlocked: return true
            case .completed, .cancelled, .queued, .waitingForDependency, .running: return false
            }
        }

        var isTerminal: Bool {
            switch self {
            case .completed, .failed, .cancelled, .dependencyBlocked: return true
            case .queued, .waitingForDependency, .running, .interrupted: return false
            }
        }
    }

    var id: UUID { shotID }
    var shotID: UUID
    var state: State = .queued
    /// The take this run produced for this shot.
    var takeID: UUID?
    var outputPath: String?
    var failureReason: String?
    var attemptNumber: Int = 1
    /// Frozen at submission, resolved once immediately before execution.
    var dependency: ResolvedShotDependency?
    /// The render request this shot was dispatched with, and the take it will
    /// become.
    ///
    /// Completion arrives as a single "last settled run" signal, which says
    /// nothing about *which* shot it belongs to. Without recording what was
    /// dispatched, a stale settlement gets applied to whichever shot happens to
    /// be running — which is exactly how a completed upstream was once read as
    /// a failure and blocked the shots below it.
    var dispatchedRequestID: UUID?
    var dispatchedTakeID: UUID?

    init(shotID: UUID, dependency: ResolvedShotDependency? = nil) {
        self.shotID = shotID
        self.dependency = dependency
    }
}

// MARK: - The run

/// One independent Storyboard run.
struct StoryboardRun: Codable, Equatable, Identifiable {
    var id: UUID
    var batchID: UUID
    var batchIndex: Int
    var plan: FrozenStoryboardPlan
    var shotStates: [ShotRunState]
    /// runID -> shotID -> takeID. Held per run, so there is no key by which one
    /// run could reach another's output.
    var takeMap: RunLocalTakeMap
    var isCancelled: Bool = false
    var createdAt: Date

    init(
        id: UUID = UUID(),
        batchID: UUID,
        batchIndex: Int,
        plan: FrozenStoryboardPlan,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.batchID = batchID
        self.batchIndex = batchIndex
        self.plan = plan
        self.createdAt = createdAt
        self.takeMap = RunLocalTakeMap()
        self.shotStates = plan.shots
            .sorted { $0.index < $1.index }
            .map { shot in
                var state = ShotRunState(shotID: shot.id)
                if shot.startSource == .previousShotOutput,
                   let upstream = plan.shots.first(where: { $0.index == shot.index - 1 }) {
                    // A descriptor, not a path: the output does not exist yet.
                    state.dependency = ResolvedShotDependency(
                        runID: id, upstreamShotID: upstream.id)
                    state.state = .waitingForDependency
                }
                return state
            }
    }

    func state(of shotID: UUID) -> ShotRunState? {
        shotStates.first { $0.shotID == shotID }
    }

    mutating func update(_ shotID: UUID, _ mutate: (inout ShotRunState) -> Void) {
        guard let index = shotStates.firstIndex(where: { $0.shotID == shotID }) else { return }
        mutate(&shotStates[index])
    }

    /// Parent state derived from the children, never tracked separately.
    var derivedState: ShotRunState.State {
        if isCancelled { return .cancelled }
        if shotStates.contains(where: { $0.state == .running }) { return .running }
        if shotStates.allSatisfy({ $0.state == .completed }) { return .completed }
        if shotStates.contains(where: { $0.state == .failed }) { return .failed }
        if shotStates.contains(where: { $0.state == .dependencyBlocked }) { return .dependencyBlocked }
        if shotStates.contains(where: { $0.state == .interrupted }) { return .interrupted }
        if shotStates.contains(where: { $0.state == .waitingForDependency }) {
            return .waitingForDependency
        }
        return .queued
    }
}

// MARK: - Shared run shape

/// What the run-local scheduler needs from a run, so Storyboard and Auto Movie
/// share one tested implementation instead of two drifting copies.
///
/// Deliberately narrow: shot order, per-shot state, and the run's own take map.
/// Nothing here can reach a FilmProject, a global selection, or another run.
protocol RunScopedShotExecution {
    var id: UUID { get }
    var isCancelled: Bool { get }
    /// Shots in execution order, with the start-source that decides dependency.
    var orderedShots: [FrozenShotPlan] { get }
    var shotStates: [ShotRunState] { get }
    var takeMap: RunLocalTakeMap { get set }

    func state(of shotID: UUID) -> ShotRunState?
    mutating func update(_ shotID: UUID, _ mutate: (inout ShotRunState) -> Void)
    /// Cancellation is a run-level fact, so the scheduler sets it through the
    /// protocol rather than reaching into a concrete type.
    mutating func markCancelled()
}

extension RunScopedShotExecution {
    /// Parent state derived from children, never tracked separately.
    var derivedShotState: ShotRunState.State {
        if isCancelled { return .cancelled }
        if shotStates.contains(where: { $0.state == .running }) { return .running }
        if shotStates.allSatisfy({ $0.state == .completed }) { return .completed }
        if shotStates.contains(where: { $0.state == .failed }) { return .failed }
        if shotStates.contains(where: { $0.state == .dependencyBlocked }) { return .dependencyBlocked }
        if shotStates.contains(where: { $0.state == .interrupted }) { return .interrupted }
        if shotStates.contains(where: { $0.state == .waitingForDependency }) {
            return .waitingForDependency
        }
        return .queued
    }
}

extension StoryboardRun: RunScopedShotExecution {
    var orderedShots: [FrozenShotPlan] { plan.shots.sorted { $0.index < $1.index } }
    mutating func markCancelled() { isCancelled = true }
}

// MARK: - Run-local scheduling

/// Decides what one run does next, using only that run's own state.
///
/// Pure and run-scoped: it is handed a single `StoryboardRun` and cannot consult
/// the project, another run, or `shot.selectedTakeID`. Cross-run resolution is
/// therefore not a rule that could be forgotten — the scheduler has no way to
/// express it.
enum StoryboardRunScheduler {

    enum Step: Equatable {
        /// Render this shot next. Its dependency, if any, is already resolved.
        case render(shotID: UUID)
        /// Nothing can start: an upstream shot has not produced its output yet.
        case waiting(shotID: UUID)
        /// An upstream shot failed, so this one can never run as planned.
        case blocked(shotID: UUID, reason: String)
        /// Every shot reached a terminal state.
        case finished
        /// The user cancelled this run.
        case cancelled
    }

    static func next<Run: RunScopedShotExecution>(_ run: Run) -> Step {
        if run.isCancelled { return .cancelled }

        // Sequential by design. Dependent shots must not run in parallel, and
        // this task deliberately does not introduce parallel shot generation.
        for shot in run.orderedShots {
            guard let state = run.state(of: shot.id) else { continue }
            if state.state == .running { return .waiting(shotID: shot.id) }
            guard state.state.needsExecution else { continue }

            guard let dependency = state.dependency else {
                return .render(shotID: shot.id)
            }
            // Already resolved by an earlier attempt: reuse it verbatim. This is
            // what makes a retry render the same input rather than a newer take.
            if dependency.isResolved { return .render(shotID: shot.id) }

            guard let upstream = run.state(of: dependency.upstreamShotID) else {
                return .blocked(shotID: shot.id, reason: "The upstream shot is missing from this run.")
            }
            switch upstream.state {
            case .completed:
                return .render(shotID: shot.id)
            case .failed, .cancelled, .dependencyBlocked:
                return .blocked(
                    shotID: shot.id,
                    reason: "The previous shot in this run did not produce a usable output.")
            case .queued, .waitingForDependency, .running, .interrupted:
                return .waiting(shotID: shot.id)
            }
        }
        return .finished
    }

    /// Resolves a shot's dependency against this run's own take map, exactly
    /// once, and freezes what it resolved to.
    ///
    /// Returns false when the upstream take does not exist *in this run*. It
    /// never falls back to the project's selection or to another run.
    static func resolveDependency<Run: RunScopedShotExecution>(
        in run: inout Run,
        shotID: UUID,
        assetPath: (UUID) -> String?,
        contentHash: (String) -> String?,
        now: Date = Date()
    ) -> Bool {
        guard var state = run.state(of: shotID) else { return false }
        guard var dependency = state.dependency else { return true }
        if dependency.isResolved { return true }

        let resolved = dependency.resolve(
            using: run.takeMap, assetPath: assetPath, contentHash: contentHash, now: now)
        guard resolved else { return false }
        state.dependency = dependency
        run.update(shotID) { $0 = state }
        return true
    }

    /// Records a shot's successful output into this run.
    static func recordCompletion<Run: RunScopedShotExecution>(
        in run: inout Run,
        shotID: UUID,
        takeID: UUID,
        outputPath: String?
    ) {
        run.takeMap.adopt(runID: run.id, shotID: shotID, takeID: takeID)
        run.update(shotID) { state in
            state.state = .completed
            state.takeID = takeID
            state.outputPath = outputPath
            state.failureReason = nil
        }
    }

    static func recordFailure<Run: RunScopedShotExecution>(in run: inout Run, shotID: UUID, reason: String) {
        run.update(shotID) { state in
            state.state = .failed
            state.failureReason = reason
        }
        propagateBlocking(in: &run, from: shotID)
    }

    /// Marks shots that can no longer run because something they need failed.
    /// Only this run is touched; sibling runs are unaffected.
    static func propagateBlocking<Run: RunScopedShotExecution>(in run: inout Run, from shotID: UUID) {
        var blocked: Set<UUID> = [shotID]
        for shot in run.orderedShots {
            guard let state = run.state(of: shot.id),
                  let dependency = state.dependency,
                  blocked.contains(dependency.upstreamShotID),
                  // A dependency already resolved and consumed is history; the
                  // shot may still be retried against that frozen input.
                  !dependency.isResolved,
                  state.state.needsExecution else { continue }
            run.update(shot.id) { $0.state = .dependencyBlocked }
            blocked.insert(shot.id)
        }
    }

    /// Cancels the run: nothing further starts, finished work is kept.
    static func cancel<Run: RunScopedShotExecution>(_ run: inout Run) {
        run.markCancelled()
        for shot in run.orderedShots {
            guard let state = run.state(of: shot.id) else { continue }
            // Completed output is preserved; a running shot is left to the
            // backend's own cancellation, which reports its own terminal state.
            guard state.state != .completed, state.state != .running else { continue }
            run.update(shot.id) { $0.state = .cancelled }
        }
    }

    /// Prepares one shot for another execution attempt.
    ///
    /// Seed, frozen inputs and any already-resolved dependency are untouched —
    /// that is exactly what separates Retry from Retake.
    static func retry<Run: RunScopedShotExecution>(in run: inout Run, shotID: UUID) {
        run.update(shotID) { state in
            guard state.state.isRetryable || state.state.needsExecution else { return }
            state.attemptNumber += 1
            state.state = state.dependency?.isResolved == false
                ? .waitingForDependency : .queued
            state.failureReason = nil
            // A fresh attempt needs a fresh reservation.
            state.dispatchedRequestID = nil
            state.dispatchedTakeID = nil
        }
    }
}

// MARK: - Submission

/// Freezes the edited Storyboard once and expands it into N independent runs.
///
/// Both halves matter. Freezing once means the Director/planner is not asked to
/// reinterpret the movie per candidate, and editing the project afterwards
/// cannot reach the queued work. Expanding means each run owns its own shot
/// states, take map and seeds.
enum StoryboardRunBuilder {

    /// - Parameter explicitSeed: the user's pinned seed, or nil for AUTO. The
    ///   policy matches every other surface: AUTO gives each run's each shot its
    ///   own seed; an explicit seed is honoured everywhere.
    static func build(
        plan: FrozenStoryboardPlan,
        count: Int,
        batchID: UUID = UUID(),
        explicitSeed: Int? = nil
    ) -> [StoryboardRun] {
        let runCount = max(1, count)
        // count == 1 and count == N take exactly this path: there is no
        // second, simpler code path that could develop different semantics.
        return (0..<runCount).map { index in
            var runPlan = plan
            runPlan.shots = seededShots(plan.shots, explicitSeed: explicitSeed)
            return StoryboardRun(
                batchID: batchID, batchIndex: index, plan: runPlan)
        }
    }

    private static func seededShots(
        _ shots: [FrozenShotPlan], explicitSeed: Int?
    ) -> [FrozenShotPlan] {
        if let explicitSeed {
            return shots.map { shot in
                var seeded = shot
                seeded.seed = explicitSeed
                return seeded
            }
        }
        // One independent draw per shot per run: no base+index, which would
        // collide across run and shot indices.
        let seeds = SeedAllocator.allocate(count: shots.count)
        return zip(shots, seeds).map { shot, seed in
            var seeded = shot
            seeded.seed = seed
            return seeded
        }
    }
}

// MARK: - Freezing an edited project

/// Builds the frozen plan from the Storyboard the user is editing.
///
/// Runs once per submit, before expansion, so the composition every run shares
/// is captured at one instant rather than re-read per candidate.
enum FrozenStoryboardPlanBuilder {

    enum FreezeError: Error, Equatable, LocalizedError {
        /// A shot claims both an explicit starting image and "continue from the
        /// previous shot". Rejected at submission rather than resolved by a
        /// silent precedence rule that the UI and the backend could read
        /// differently.
        case ambiguousStartSource(shotIndex: Int)

        var errorDescription: String? {
            switch self {
            case .ambiguousStartSource(let index):
                return "Shot \(index + 1) has both a starting image and “continue from the "
                    + "previous shot”. Choose one before generating."
            }
        }
    }

    static func freeze(
        project: FilmProject,
        modelID: String,
        preset: String?,
        audioEnabled: Bool,
        textEncoderID: String?,
        directorMode: String?,
        store: FilmProjectStore = .shared,
        contentHash: (String) -> String? = { _ in nil }
    ) throws -> FrozenStoryboardPlan {
        let ordered = project.shots.sorted { $0.index < $1.index }
        let shots: [FrozenShotPlan] = try ordered.enumerated().map { position, shot in
            let continues = shot.continuityMode == .continueFromPrevious && position > 0
            let explicitPath = shot.continuityImageRelativePath
            let hasExplicit = shot.startingImageReferenceAssetID != nil

            if continues && hasExplicit {
                throw FreezeError.ambiguousStartSource(shotIndex: position)
            }
            let startSource: FrozenShotPlan.StartSource =
                continues ? .previousShotOutput : (hasExplicit ? .explicitImage : .none)

            return FrozenShotPlan(
                id: shot.id,
                index: position,
                title: shot.title,
                compiledPrompt: shot.compiledPrompt,
                durationSeconds: shot.durationSeconds,
                startSource: startSource,
                explicitStartImageRelativePath: startSource == .explicitImage ? explicitPath : nil,
                // A path does not freeze bytes. The hash lets execution detect a
                // file edited while the run waited, the same way the accepted
                // Ending Image path does.
                //
                // Hashing needs the resolved location: the frozen path is
                // project-relative and `FileManager.contents(atPath:)` cannot
                // open one, so hashing it directly always produced nil. Only
                // the hash comes from the resolved path — the stored path stays
                // relative so it survives a moved library.
                explicitStartImageContentHash: startSource == .explicitImage
                    ? explicitPath
                        .flatMap { MovieRunRequestBuilder.resolveFrozenAssetPath(
                            $0, projectID: project.id, store: store) }
                        .flatMap(contentHash)
                    : nil,
                endingImagePath: nil,
                endingImageContentHash: nil,
                seed: 0,
                characterIDs: shot.characterIDs,
                startingImageReferenceAssetID: shot.startingImageReferenceAssetID)
        }

        return FrozenStoryboardPlan(
            projectID: project.id,
            title: project.title,
            shots: shots,
            modelID: modelID,
            preset: preset,
            audioEnabled: audioEnabled,
            textEncoderID: textEncoderID,
            directorMode: directorMode,
            openingReferenceRelativePath: project.openingReferenceImage?.projectRelativePath,
            characterAnchorCharacterID: project.characterAnchor.characterID,
            characterAnchorAssetID: project.characterAnchor.referenceAssetID)
    }
}

// MARK: - Submitting a whole Storyboard

/// Turns the edited Storyboard into a queued, run-scoped `ProductionJob`.
///
/// This is the **new** whole-Storyboard action. The existing editor actions —
/// Generate Missing Takes and Regenerate Selected Shots — keep their direct
/// `planTakes` path untouched: they operate on editable Shot/Take state, which
/// is a different product operation from freezing the whole composition and
/// queueing it as independent works.
enum StoryboardRunSubmission {

    /// Builds the job. The composition is frozen **once**, then copied into
    /// every run: reading the project per candidate would let an edit between
    /// reads produce runs that are not actually the same work.
    static func makeJob(
        project: FilmProject,
        workCount: Int,
        directorMode: String?,
        explicitSeed: Int? = nil,
        store: FilmProjectStore = .shared,
        contentHash: (String) -> String? = { _ in nil }
    ) throws -> ProductionJob {
        let settings = project.settings
        let plan = try FrozenStoryboardPlanBuilder.freeze(
            project: project,
            modelID: settings.modelID,
            preset: settings.preset,
            audioEnabled: settings.audioEnabled ?? true,
            textEncoderID: settings.textEncoderID,
            directorMode: directorMode,
            store: store,
            contentHash: contentHash)

        let batchID = UUID()
        let runs = StoryboardRunBuilder.build(
            plan: plan, count: workCount, batchID: batchID, explicitSeed: explicitSeed)

        var snapshot = ProductionJobSnapshot()
        snapshot.snapshotVersion = RunProvenanceStamper.currentSnapshotVersion
        snapshot.batchID = batchID
        // Deliberately NOT set: a run-scoped job must not be resolvable back to
        // live project state at execution time. `projectID` is what the legacy
        // path uses to re-read the editable project, and leaving it nil is what
        // makes that impossible here.
        snapshot.prompt = plan.shots.first?.compiledPrompt ?? ""
        snapshot.brief = project.title
        snapshot.modelID = plan.modelID
        snapshot.textEncoderID = plan.textEncoderID
        snapshot.preset = plan.preset
        snapshot.audioEnabled = plan.audioEnabled
        snapshot.directorMode = plan.directorMode
        snapshot.openingReferenceRelativePath = plan.openingReferenceRelativePath
        snapshot.characterAnchorCharacterID = plan.characterAnchorCharacterID
        snapshot.characterAnchorAssetID = plan.characterAnchorAssetID
        snapshot.batchCount = runs.count
        snapshot.storyboardRuns = runs

        return ProductionJob(
            kind: .storyboard,
            title: title(project.title, works: runs.count, shots: plan.shotCount),
            snapshot: snapshot)
    }

    static func title(_ projectTitle: String, works: Int, shots: Int) -> String {
        let name = projectTitle.isEmpty ? "Storyboard" : projectTitle
        return works > 1 ? "\(name) × \(works)作品 (\(shots) Shot)" : "\(name) (\(shots) Shot)"
    }
}

// MARK: - Turning a frozen shot into a render request

/// Builds the backend request for one shot of one run.
///
/// Everything comes from the frozen plan and the run's own state. The live
/// project is never consulted, so an edit made after submission — including a
/// change of `selectedTakeID` — cannot reach a queued run.
enum StoryboardRunRequestBuilder {

    static func makeRequest(
        run: StoryboardRun,
        shotID: UUID,
        takeID: UUID = UUID(),
        parameters: GenerationParameters,
        resolveAsset: (String, UUID) -> String? = {
            MovieRunRequestBuilder.resolveFrozenAssetPath($0, projectID: $1)
        },
        contentHash: (String) -> String? = { H3EndingImageCapability.contentHash(ofFileAt: $0) }
    ) -> GenerationRequest? {
        guard let shot = run.plan.shots.first(where: { $0.id == shotID }),
              let state = run.state(of: shotID) else { return nil }

        var params = parameters
        // The seed was frozen at submission; the backend never picks one.
        params.seed = shot.seed

        // Start image. Resolved once, then never re-read.
        let sourceImagePath: String?
        switch shot.startSource {
        case .previousShotOutput:
            // The frozen final-frame PNG, never the upstream MP4 — a video
            // handed over as a starting image cannot be decoded, which is
            // exactly how this failed in the real app. Verified rather than
            // trusted: a frame that vanished or changed fails the request
            // instead of silently rendering something else.
            guard let dependency = state.dependency,
                  StoryboardContinuityFrame.verifyFrozen(dependency) == nil,
                  let frame = dependency.extractedImagePath else { return nil }
            sourceImagePath = frame
        case .explicitImage:
            // The frozen path is project-relative and the renderer cannot open
            // one, so resolve it — and block rather than fall back to
            // text-to-video when it cannot be resolved. The frozen hash is a
            // promise about bytes and is checked before they are used: a file
            // edited or deleted while the work waited in the queue is refused.
            // A missing file needs no separate check, because the hasher reads
            // the file and so returns nil. A plan frozen before hashing existed
            // has no promise to check and still renders.
            guard let relative = shot.explicitStartImageRelativePath,
                  let resolved = resolveAsset(relative, run.plan.projectID) else { return nil }
            if let expected = shot.explicitStartImageContentHash {
                guard contentHash(resolved) == expected else { return nil }
            }
            sourceImagePath = resolved
        case .none:
            sourceImagePath = nil
        }

        var request = GenerationRequest(
            prompt: shot.compiledPrompt,
            brief: run.plan.title,
            sourceImagePath: sourceImagePath,
            endingImagePath: shot.endingImagePath,
            endingImageContentHash: shot.endingImageContentHash,
            disableAudio: !run.plan.audioEnabled,
            modelId: run.plan.modelID,
            textEncoderId: run.plan.textEncoderID ?? LTXTextEncoderCatalog.defaultTextEncoderID,
            parameters: params,
            preset: run.plan.preset,
            generationSource: "storyboardRun")
        // Deliberately NOT set. `filmProjectID` is the legacy project-advance
        // trigger: GenerationService feeds it to
        // `AutoMovieRunCoordinator.advance`, which would start a second,
        // project-global render of the same movie alongside this run. The
        // source project id lives on the frozen plan as provenance instead.
        request.shotID = shot.id
        request.takeID = takeID
        // Run identity travels with the request, so a completed render can be
        // attributed back to the run that asked for it rather than to whichever
        // run happens to own the project.
        request.batchID = run.batchID
        request.batchIndex = run.batchIndex
        request.attemptNumber = state.attemptNumber
        return request
    }
}

// MARK: - Dispatch decisions

/// The scheduling decisions the production queue makes for a run-scoped
/// Storyboard job, separated from the queue plumbing so the real logic can be
/// driven by tests.
///
/// This exists because the duplicate-enqueue defect lived here, not in
/// `StoryboardRunScheduler.next` — which was already pure and already correct.
/// Testing `next()` alone proved nothing; what needed testing was *when the
/// caller is allowed to act on it*.
enum StoryboardRunDriver {

    /// A shot to hand to the renderer.
    struct Dispatch: Equatable {
        var runIndex: Int
        var runID: UUID
        var shotID: UUID
        var attemptNumber: Int
    }

    /// What should happen right now, given only durable state.
    ///
    /// Returns nil when nothing may be dispatched: an attempt is already in
    /// flight, every run has settled, or the next shot is still waiting on its
    /// own upstream.
    static func nextDispatch<Run: RunScopedShotExecution>(in runs: [Run]) -> Dispatch? {
        // Attempt-level in-flight guard. Deliberately not "some shot is
        // running anywhere": that would let run A's work mask run B's.
        if runs.contains(where: { run in
            run.shotStates.contains { $0.state == .running && $0.dispatchedRequestID != nil }
        }) { return nil }

        for (index, run) in runs.enumerated() {
            switch StoryboardRunScheduler.next(run) {
            case .render(let shotID):
                return Dispatch(
                    runIndex: index, runID: run.id, shotID: shotID,
                    attemptNumber: run.state(of: shotID)?.attemptNumber ?? 1)
            case .waiting, .blocked, .finished, .cancelled:
                // Asking must not mutate. A shot waiting on its own upstream is
                // simply not dispatchable yet; the next run is considered
                // instead.
                continue
            }
        }
        return nil
    }

    /// Applies one settlement to the run that dispatched it.
    ///
    /// Returns nil when the settlement belongs to no in-flight attempt — a
    /// stale value, or one from another job — so the caller does nothing.
    static func applySettlement<Run: RunScopedShotExecution>(
        _ settlement: RunOutcomeRecord,
        to runs: [Run]
    ) -> [Run]? {
        var updated = runs
        for index in updated.indices {
            guard let state = updated[index].shotStates.first(where: {
                $0.state == .running && $0.dispatchedRequestID == settlement.runID
            }) else { continue }

            // Release the reservation first: an attempt is only re-dispatchable
            // after it has settled, and then only through an explicit retry.
            updated[index].update(state.shotID) { $0.dispatchedRequestID = nil }

            switch settlement.outcome {
            case .completed:
                StoryboardRunScheduler.recordCompletion(
                    in: &updated[index], shotID: state.shotID,
                    takeID: state.dispatchedTakeID ?? settlement.runID,
                    outputPath: settlement.outputPath)
                resolveNextDependency(in: &updated[index])
            case .failed, .cancelled, .interrupted, .queued, .running:
                StoryboardRunScheduler.recordFailure(
                    in: &updated[index], shotID: state.shotID,
                    reason: settlement.failureReason ?? "The shot failed to render.")
            }
            return updated
        }
        return nil
    }

    /// Freezes the next dependent shot's input, once, right after its upstream
    /// succeeded and before that shot can be dispatched.
    ///
    /// A continuation starts from the **last frame** of the upstream video, not
    /// from the video file. Passing the MP4 through as a starting image is what
    /// produced "the selected conditioning image could not be decoded" in the
    /// real app.
    static func resolveNextDependency<Run: RunScopedShotExecution>(in run: inout Run) {
        for shot in run.orderedShots {
            guard let state = run.state(of: shot.id),
                  let dependency = state.dependency,
                  !dependency.hasFrozenFrame,
                  state.state.needsExecution else { continue }

            // Same-run provenance only: the upstream take is read from this
            // run's own state, never from the project or its selected take.
            guard let upstream = run.state(of: dependency.upstreamShotID),
                  let takeID = upstream.takeID,
                  let videoPath = upstream.outputPath else { return }

            switch StoryboardContinuityFrame.freeze(
                runID: run.id, shotID: shot.id, upstreamTakeID: takeID, videoPath: videoPath) {
            case .success(let frozen):
                run.update(shot.id) { st in
                    var dep = st.dependency
                    dep?.resolvedTakeID = takeID
                    dep?.sourceVideoPath = frozen.sourceVideoPath
                    dep?.sourceVideoContentHash = frozen.sourceVideoContentHash
                    dep?.extractedImagePath = frozen.imagePath
                    dep?.extractedImageContentHash = frozen.imageContentHash
                    dep?.frameReference = frozen.frameReference
                    // Kept in step with the frame actually used, so anything
                    // reading the generic fields sees the image, not the video.
                    dep?.resolvedAssetPath = frozen.imagePath
                    dep?.resolvedContentHash = frozen.imageContentHash
                    dep?.resolvedAt = Date()
                    st.dependency = dep
                    st.state = .queued
                }
            case .failure(let reason):
                // Fail closed. Never hand the renderer the video, never quietly
                // degrade the shot to text-to-video, never reach for another
                // take.
                run.update(shot.id) { st in
                    st.state = .dependencyBlocked
                    st.failureReason = reason
                }
            }
            return
        }
    }

    /// True when no run has anything left to do.
    static func allSettled<Run: RunScopedShotExecution>(_ runs: [Run]) -> Bool {
        runs.allSatisfy { run in
            switch run.derivedShotState {
            case .completed, .failed, .cancelled, .dependencyBlocked: return true
            default: return false
            }
        }
    }
}

// MARK: - Continuity frame freezing

/// Turns a run's upstream video into the frozen starting image its next shot
/// renders from.
///
/// Reuses `ContinuityFrameExtractor` — the project-independent half of the
/// existing continuity machinery. It deliberately does **not** call
/// `AutoMovieRunCoordinator.prepareContinuityAsset`: that wrapper reads the
/// FilmProject, prefers `shot.selectedTake`, and writes continuity state back
/// into `project.shots[]`, all of which would reintroduce exactly the
/// project-global coupling run scoping exists to remove.
enum StoryboardContinuityFrame {

    struct Frozen: Equatable {
        var sourceVideoPath: String
        var sourceVideoContentHash: String?
        var imagePath: String
        var imageContentHash: String
        var frameReference: String
    }

    enum Outcome: Equatable {
        case success(Frozen)
        case failure(String)
    }

    /// Where a run keeps its extracted frames.
    ///
    /// Under the profile's own Application Support root, so Dev and Personal
    /// stay isolated and the file survives restart — a queued job may resume
    /// hours later. Keyed by run *and* shot *and* take, so two runs of the same
    /// Storyboard cannot collide on one path.
    static func imageURL(runID: UUID, shotID: UUID, upstreamTakeID: UUID) -> URL {
        AppStorageDirectory.root
            .appendingPathComponent("StoryboardRuns", isDirectory: true)
            .appendingPathComponent(runID.uuidString, isDirectory: true)
            .appendingPathComponent("continuity", isDirectory: true)
            .appendingPathComponent("\(shotID.uuidString)-\(upstreamTakeID.uuidString).png")
    }

    /// Extracts and freezes, or explains why it could not.
    static func freeze(
        runID: UUID,
        shotID: UUID,
        upstreamTakeID: UUID,
        videoPath: String,
        fileManager: FileManager = .default
    ) -> Outcome {
        guard fileManager.fileExists(atPath: videoPath) else {
            return .failure("The previous shot's video is missing, so this shot cannot continue from it.")
        }
        let destination = imageURL(
            runID: runID, shotID: shotID, upstreamTakeID: upstreamTakeID)
        do {
            try ContinuityFrameExtractor.extractLastFrame(
                videoPath: videoPath, outputPath: destination.path)
        } catch let error as ContinuityFrameExtractor.ExtractionError {
            return .failure(error.userMessage)
        } catch {
            return .failure("Extracting the previous shot's final frame failed: \(error.localizedDescription)")
        }
        guard ContinuityFrameExtractor.isUsableImage(atPath: destination.path) else {
            try? fileManager.removeItem(at: destination)
            return .failure("The previous shot's final frame could not be turned into a usable image.")
        }
        guard let imageHash = H3EndingImageCapability.contentHash(ofFileAt: destination.path) else {
            return .failure("The extracted final frame could not be read back for verification.")
        }
        let duration = MediaProbe.probe(path: videoPath)?.durationSeconds
        return .success(Frozen(
            sourceVideoPath: videoPath,
            sourceVideoContentHash: H3EndingImageCapability.contentHash(ofFileAt: videoPath),
            imagePath: destination.path,
            imageContentHash: imageHash,
            // Not a fabricated frame index: the extractor tries several seek
            // strategies and does not report which one landed.
            frameReference: duration.map { "final-frame@duration=\(String(format: "%.3f", $0))" }
                ?? "final-frame"))
    }

    /// Verifies a already-frozen frame is still exactly the bytes that were
    /// frozen. Never re-extracts: the frozen PNG *is* the execution input.
    static func verifyFrozen(
        _ dependency: ResolvedShotDependency,
        fileManager: FileManager = .default
    ) -> String? {
        guard let path = dependency.extractedImagePath,
              let expected = dependency.extractedImageContentHash else {
            return "This shot has no frozen starting frame to continue from."
        }
        guard fileManager.fileExists(atPath: path) else {
            return "The frozen starting frame for this shot is missing."
        }
        guard let actual = H3EndingImageCapability.contentHash(ofFileAt: path) else {
            return "The frozen starting frame for this shot could not be read."
        }
        guard actual == expected else {
            return "The frozen starting frame for this shot has changed since it was prepared."
        }
        return nil
    }
}
