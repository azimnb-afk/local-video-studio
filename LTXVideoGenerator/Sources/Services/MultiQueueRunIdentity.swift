import Foundation

/// Shared foundation for multi-candidate submission across Generate, One Shot,
/// Storyboard and Auto Movie.
///
/// The design principle this implements: *create independent runs from one
/// frozen composition, use seeds to create candidate variation, and resolve
/// result-dependent inputs once inside each run, recording the exact material
/// actually used.*
///
/// Identity layers, and which of them already existed:
///
/// | layer   | type                                    | status |
/// |---------|-----------------------------------------|--------|
/// | Batch   | `GenerationRequest.batchID` + index      | new    |
/// | Run     | `GenerationRequest.id`                   | reused |
/// | Shot    | `GenerationRequest.shotID`               | reused |
/// | Take    | `GenerationRequest.takeID`               | reused |
/// | Attempt | `GenerationRequest.attemptNumber`        | new    |
///
/// A Run id is stable across attempts: Retry raises `attemptNumber` and keeps
/// `id`, so provenance stays attached to the same logical candidate. Retake is a
/// different operation — it mints a new Take with a new seed and is never
/// produced by this file.

// MARK: - Seeds

/// Concrete seed allocation, performed at submission and never at execution.
///
/// Seeds are drawn independently rather than as `base + index`. The additive
/// form silently collides across nested indices — run 1 shot 3 and run 3 shot 1
/// both land on `base + 4` — which would make two candidates that are supposed
/// to be independent render the same thing.
enum SeedAllocator {
    /// Matches the range every existing call site already used.
    static let upperBound = Int(Int32.max)

    static func allocate() -> Int {
        Int.random(in: 0..<upperBound)
    }

    /// `count` distinct seeds. Distinctness is enforced, not assumed: two equal
    /// draws would collapse two candidates into one result.
    static func allocate(count: Int) -> [Int] {
        guard count > 0 else { return [] }
        var seen = Set<Int>()
        var seeds: [Int] = []
        seeds.reserveCapacity(count)
        while seeds.count < count {
            let seed = allocate()
            if seen.insert(seed).inserted { seeds.append(seed) }
        }
        return seeds
    }
}

// MARK: - Per-run outcome ledger

/// The terminal outcome of one logical run inside a parent job.
///
/// Persisted on the job snapshot so it survives app restart. Without it a retry
/// of a partly-successful batch re-renders the candidates that already
/// succeeded, duplicating their History entries and their cost.
struct RunOutcomeRecord: Codable, Equatable {
    /// Execution state of one logical run, mirroring `GenerationStatus` so the
    /// two never drift.
    ///
    /// This — not History — is the authority on whether a candidate has to be
    /// rendered. History is provenance the user can delete; deleting it must
    /// never cause completed work to run again, and a crash between finishing a
    /// render and writing History must never do so either.
    enum Outcome: String, Codable, Equatable {
        case queued
        case running
        case completed
        case failed
        case cancelled
        case interrupted

        /// States that must not be executed again.
        var isSettledSuccessfully: Bool { self == .completed }

        /// A run left mid-flight by a crash. Recorded rather than assumed
        /// complete, so recovery can decide instead of guessing.
        var needsExecution: Bool {
            switch self {
            case .completed: return false
            case .queued, .running, .failed, .cancelled, .interrupted: return true
            }
        }

        init(_ status: GenerationStatus) {
            switch status {
            case .pending: self = .queued
            case .processing: self = .running
            case .completed: self = .completed
            case .failed: self = .failed
            case .cancelled: self = .cancelled
            }
        }
    }

    var runID: UUID
    var outcome: Outcome
    var attemptNumber: Int
    var outputPath: String?
    var failureReason: String?
    /// True when this run never reached the renderer because a sibling hit a
    /// failure that applies to the whole batch (see `BatchFailurePolicy`). The
    /// outcome is `failed` — it did not succeed and Retry must run it — but it
    /// was not attempted, which is what the queue shows. Optional so records
    /// written before this field existed still decode.
    var notAttempted: Bool?

    init(
        runID: UUID,
        outcome: Outcome,
        attemptNumber: Int = 1,
        outputPath: String? = nil,
        failureReason: String? = nil,
        notAttempted: Bool? = nil
    ) {
        self.runID = runID
        self.outcome = outcome
        self.attemptNumber = attemptNumber
        self.outputPath = outputPath
        self.failureReason = failureReason
        self.notAttempted = notAttempted
    }
}

/// Whether a failure dooms the works that have not run yet.
///
/// The default is to keep going: one work failing is usually about that work,
/// and stopping its siblings would throw away outputs that would have
/// succeeded. A batch is stopped only on a typed failure that is decided before
/// rendering and depends solely on inputs every remaining sibling shares:
///
/// - the renderer's readiness checks (`LTXError.modelLoadFailed`: model or text
///   encoder not prepared locally, model unsupported, LTX-2-MLX runtime/model
///   not ready) and a missing Python environment (`pythonNotConfigured`);
/// - a frozen explicit starting image that is missing or changed, when the
///   sibling froze the very same file and bytes.
///
/// Everything else — backend exits, GPU/Metal out-of-memory (detected only by
/// matching process output), export and assembly failures, a missing
/// continuation frame, cancellation — is treated as possibly work-local or
/// transient, and siblings continue.
enum FailureScope: Equatable {
    case batchDeterministic
    case workLocalOrUnknown
}

enum BatchFailurePolicy {

    /// Shown on each work that was stopped rather than attempted. Short: the
    /// real cause is on the work that failed.
    static let notAttemptedReason = "同じ条件では成功しないため、残りの生成を停止しました。"

    static func scope(of error: LTXError?) -> FailureScope {
        switch error {
        case .modelLoadFailed?, .pythonNotConfigured?: return .batchDeterministic
        case .generationFailed?, .exportFailed?, .cancelled?, nil: return .workLocalOrUnknown
        }
    }

    /// Generate / One Shot: the still-pending requests of the failed request's
    /// batch that depend on the same model prerequisites. Film-project takes
    /// (which carry a take id) are never swept up.
    static func siblingsSharingPrerequisite(
        of failed: GenerationRequest, in queue: [GenerationRequest]
    ) -> [GenerationRequest] {
        guard let batch = failed.batchID, failed.takeID == nil else { return [] }
        return queue.filter {
            $0.id != failed.id
                && $0.status == .pending
                && $0.takeID == nil
                && $0.batchID == batch
                && $0.modelId == failed.modelId
                && $0.textEncoderId == failed.textEncoderId
                && $0.customModelLocalPath == failed.customModelLocalPath
                && $0.customModelSourceMode == failed.customModelSourceMode
        }
    }

    /// Run-scoped: marks every run that has not started and shares the failed
    /// prerequisite as not attempted. A run that has already rendered or is
    /// rendering keeps going — its work is under way.
    static func skipUnstartedRuns<Run: RunScopedShotExecution>(
        _ runs: inout [Run], except failingIndex: Int, sharesPrerequisite: (Run) -> Bool
    ) {
        for index in runs.indices where index != failingIndex {
            let run = runs[index]
            let unstarted = !run.isCancelled && run.shotStates.allSatisfy {
                ($0.state == .queued || $0.state == .waitingForDependency) && $0.dispatchedRequestID == nil
            }
            guard unstarted, sharesPrerequisite(run) else { continue }
            for shot in run.orderedShots {
                runs[index].update(shot.id) {
                    $0.state = .dependencyBlocked
                    $0.failureReason = notAttemptedReason
                    $0.notAttempted = true
                }
            }
        }
    }
}

// MARK: - Submission stamping

/// Stamps run identity and frozen seeds onto a job as it enters the queue.
///
/// Applied at the single enqueue boundary rather than at each call site, so
/// every producer — Generate, One Shot, Storyboard, Auto Movie, History
/// re-queue — gets the same guarantees without having to remember to ask.
enum RunProvenanceStamper {

    /// Current snapshot shape. Bump when a field changes meaning, not merely
    /// when one is added — additive fields decode as nil on older records.
    static let currentSnapshotVersion = 2

    static func stamp(_ job: ProductionJob) -> ProductionJob {
        var stamped = job
        let batchID = stamped.snapshot.batchID ?? UUID()
        stamped.snapshot.batchID = batchID
        stamped.snapshot.snapshotVersion = max(
            stamped.snapshot.snapshotVersion, currentSnapshotVersion)

        stamped.snapshot.pendingRequests = stamped.snapshot.pendingRequests
            .enumerated()
            .map { index, request in
                stampRequest(request, batchID: batchID, batchIndex: index)
            }
        // A run-scoped job's work lives in its runs, not in `pendingRequests`,
        // so counting requests reports 1 work for a two-work batch. Observed in
        // the real app as a 2-work Auto Movie job recording batchCount 1.
        if !stamped.snapshot.storyboardRuns.isEmpty {
            stamped.snapshot.batchCount = stamped.snapshot.storyboardRuns.count
        } else if !stamped.snapshot.movieRuns.isEmpty {
            stamped.snapshot.batchCount = stamped.snapshot.movieRuns.count
        } else {
            stamped.snapshot.batchCount = max(1, stamped.snapshot.pendingRequests.count)
        }
        return stamped
    }

    /// Idempotent per request: a job that is re-stamped (re-queue, retry) keeps
    /// the identity and the seed it was first given.
    static func stampRequest(
        _ request: GenerationRequest,
        batchID: UUID,
        batchIndex: Int
    ) -> GenerationRequest {
        var stamped = request
        if stamped.batchID == nil { stamped.batchID = batchID }
        if stamped.batchIndex == nil { stamped.batchIndex = batchIndex }
        if stamped.attemptNumber == nil { stamped.attemptNumber = 1 }
        // The whole point of the exercise: a submitted run carries a concrete
        // seed, so a retry renders the same candidate rather than a new one.
        if stamped.parameters.seed == nil {
            stamped.parameters.seed = SeedAllocator.allocate()
        }
        return stamped
    }
}

// MARK: - Retry planning

/// Decides what a retry of a parent job should actually re-run.
///
/// Pure so it can be tested without a queue, a renderer or a filesystem.
enum RunRetryPlanner {

    struct Plan: Equatable {
        /// Runs to execute on the retry, with `attemptNumber` already raised.
        var requestsToRun: [GenerationRequest]
        /// Outcomes carried forward untouched, so a second retry still knows
        /// which candidates are done and History keeps their provenance.
        var preservedOutcomes: [RunOutcomeRecord]
        /// Runs skipped because they already succeeded.
        var skippedRunIDs: [UUID]

        var isEmpty: Bool { requestsToRun.isEmpty }
    }

    /// - Parameters:
    ///   - requests: the parent job's frozen pending requests.
    ///   - outcomes: per-run outcomes recorded when the job went terminal.
    static func plan(
        requests: [GenerationRequest],
        outcomes: [RunOutcomeRecord]
    ) -> Plan {
        // Queue state only. History is deliberately not consulted: it is
        // presentation, the user may delete it, and it can lag a crash.
        let completed = Set(
            outcomes.filter { $0.outcome.isSettledSuccessfully }.map(\.runID))

        var toRun: [GenerationRequest] = []
        var skipped: [UUID] = []

        for request in requests {
            if completed.contains(request.id) {
                skipped.append(request.id)
                continue
            }
            var retried = request
            // Same logical run, next attempt. Seed and frozen inputs are
            // deliberately untouched — that is what makes this a Retry rather
            // than a Retake.
            retried.attemptNumber = (retried.attemptNumber ?? 1) + 1
            retried.status = .pending
            // A job persisted before multi-queue has no seed. Freeze one here,
            // once, so it lands in the retried snapshot and every later attempt
            // reuses it. Leaving it nil would hand each attempt a different
            // random seed at the backend, which is not a retry of anything.
            if retried.parameters.seed == nil {
                retried.parameters.seed = SeedAllocator.allocate()
            }
            if retried.batchID == nil { retried.batchID = UUID() }
            if retried.batchIndex == nil { retried.batchIndex = toRun.count }
            toRun.append(retried)
        }

        return Plan(
            requestsToRun: toRun,
            preservedOutcomes: outcomes.filter { $0.outcome.isSettledSuccessfully },
            skippedRunIDs: skipped)
    }
}

// MARK: - Execution boundary

/// Resolves the seed a backend actually renders with.
///
/// Every production job is stamped with a concrete seed at enqueue, so reaching
/// this with `nil` means one of two things, both worth seeing in the log rather
/// than silently papering over: a request persisted before multi-queue existed,
/// or a non-production caller that bypassed the queue. Either way the run cannot
/// be reproduced by a later Retry, and saying so is more useful than a silent
/// `?? Int.random(...)`.
enum ExecutionSeedResolver {
    static func resolve(_ request: GenerationRequest, backend: String) -> Int {
        if let seed = request.parameters.seed { return seed }
        let allocated = SeedAllocator.allocate()
        print("[seed] \(backend): run \(request.id) reached execution without a "
            + "frozen seed (legacy or non-queue caller); allocated \(allocated). "
            + "Retry cannot reproduce this run.")
        return allocated
    }

    /// Parameter-only variant for backends that never see the request.
    static func resolve(_ parameters: GenerationParameters, backend: String) -> Int {
        if let seed = parameters.seed { return seed }
        let allocated = SeedAllocator.allocate()
        print("[seed] \(backend): execution without a frozen seed "
            + "(legacy or non-queue caller); allocated \(allocated).")
        return allocated
    }
}

// MARK: - Candidate expansion

/// Turns one frozen request into N independent candidates.
///
/// Everything that defines *what* is being made is shared verbatim — prompt,
/// composition, model, preset, audio policy, Starting Image, Ending Image and
/// its submission-time content hash. Only identity and seed differ, which is
/// exactly what makes these candidates of the same thing rather than N
/// different things.
///
/// Expansion happens *after* any Director/planner call, never before: N
/// candidates must not mean N planning invocations.
enum CandidateExpander {

    static func expand(_ request: GenerationRequest, count: Int) -> [GenerationRequest] {
        let n = max(1, count)
        // A single candidate still goes through here, so count == 1 and count > 1
        // produce the same run semantics rather than two different code paths.
        let seeds = seedsFor(request, count: n)
        let batchID = request.batchID ?? UUID()

        return (0..<n).map { index in
            var candidate = request
            if index > 0 {
                // A new logical run, and a new Take of the same logical Shot.
                candidate.id = UUID()
                if candidate.takeID != nil { candidate.takeID = UUID() }
            }
            candidate.parameters.seed = seeds[index]
            candidate.batchID = batchID
            candidate.batchIndex = index
            candidate.attemptNumber = 1
            candidate.status = .pending
            return candidate
        }
    }

    /// Seed policy, frozen deliberately rather than inherited.
    ///
    /// - **Auto** (`parameters.seed == nil`): every candidate gets its own
    ///   concrete seed. This is normal multi-Take variation.
    /// - **Explicit** (`parameters.seed != nil`): every candidate uses that
    ///   exact seed. Asking for a specific seed is a request to reproduce a
    ///   condition, so honouring it for one candidate and quietly varying the
    ///   rest would answer a question the user did not ask.
    ///
    /// Generate previously discarded an explicit seed for batches entirely.
    /// That was a defect, not a behaviour worth preserving.
    private static func seedsFor(_ request: GenerationRequest, count: Int) -> [Int] {
        if let explicit = request.parameters.seed {
            return Array(repeating: explicit, count: count)
        }
        return SeedAllocator.allocate(count: count)
    }
}

// MARK: - Run-local dependency resolution

/// Which Take each logical Shot actually produced **inside one run**.
///
/// Storyboard and Auto Movie resolve "continue from the previous shot" through
/// this map and never through `shot.selectedTakeID`. The global selection is
/// authoring state: the user changes it while editing, an auto-adoption pass can
/// change it on its own (`AutoMovieRunCoordinator.autoSelectUnambiguousTakes`
/// promotes a lone completed take), and with two runs in flight both runs would
/// otherwise read whichever one happened to finish first.
///
/// Keyed by run, so cross-run resolution is not merely discouraged — there is no
/// key by which run B could reach run A's output.
struct RunLocalTakeMap: Codable, Equatable {
    /// runID -> shotID -> takeID adopted by that run.
    private var adopted: [UUID: [UUID: UUID]] = [:]

    init() {}

    /// Records the Take a run produced for a Shot. First write wins: once a
    /// downstream Shot may have consumed it, the mapping is history.
    mutating func adopt(runID: UUID, shotID: UUID, takeID: UUID) {
        var perShot = adopted[runID] ?? [:]
        guard perShot[shotID] == nil else { return }
        perShot[shotID] = takeID
        adopted[runID] = perShot
    }

    /// The Take this run adopted for this Shot, or nil if the run has not
    /// produced one yet. Never falls back to another run, and never falls back
    /// to the project's global selection.
    func take(runID: UUID, shotID: UUID) -> UUID? {
        adopted[runID]?[shotID]
    }

    /// Replaces a run's adoption for a Shot. Used by an explicit Retake that
    /// the user has chosen to adopt; it does not rewrite dependencies already
    /// frozen into downstream execution records.
    mutating func readopt(runID: UUID, shotID: UUID, takeID: UUID) {
        var perShot = adopted[runID] ?? [:]
        perShot[shotID] = takeID
        adopted[runID] = perShot
    }

    var runIDs: Set<UUID> { Set(adopted.keys) }
}

/// A dependency that did not exist at submission time, resolved exactly once.
///
/// The descriptor is frozen at submission; `resolved` is filled in immediately
/// before the dependent Shot executes and is never re-read afterwards. An
/// upstream Retake later changes the run's adoption but not this record — the
/// downstream output keeps the provenance it was actually made from.
struct ResolvedShotDependency: Codable, Equatable {
    /// Frozen at submission: *which* upstream shot this run depends on.
    var runID: UUID
    var upstreamShotID: UUID
    /// Filled in once, at the moment the dependent shot starts.
    var resolvedTakeID: UUID?
    var resolvedAssetPath: String?
    /// SHA-256 of the resolved asset, so a later mutation is detectable rather
    /// than silently rendered.
    var resolvedContentHash: String?
    var resolvedAt: Date?

    // MARK: Final-frame conditioning

    /// The upstream shot's rendered video, and its bytes at resolution time.
    ///
    /// A continuation does not start from the video — it starts from the
    /// video's last frame. Both are recorded: the video says *where the frame
    /// came from*, the extracted image is *what was actually rendered with*.
    var sourceVideoPath: String?
    var sourceVideoContentHash: String?

    /// The extracted final frame. This — never the video — is what reaches the
    /// backend as a starting image.
    var extractedImagePath: String?
    var extractedImageContentHash: String?

    /// How the frame was chosen, described deterministically rather than as a
    /// fabricated index: `ContinuityFrameExtractor` tries several seek
    /// strategies and does not report which one landed.
    var frameReference: String?

    /// A dependency is resolved once it names an upstream take.
    var isResolved: Bool { resolvedTakeID != nil }

    /// Resolved *and* carrying a usable frozen frame. A continuation may only
    /// execute in this state.
    var hasFrozenFrame: Bool {
        guard let path = extractedImagePath, !path.isEmpty else { return false }
        return extractedImageContentHash?.isEmpty == false
    }

    init(runID: UUID, upstreamShotID: UUID) {
        self.runID = runID
        self.upstreamShotID = upstreamShotID
    }

    /// Lenient decoding.
    ///
    /// The synthesised decoder demands a key even for a defaulted property, so
    /// adding these fields would otherwise make every dependency written by an
    /// earlier build undecodable — and with it the whole queue snapshot.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        runID = try c.decode(UUID.self, forKey: .runID)
        upstreamShotID = try c.decode(UUID.self, forKey: .upstreamShotID)
        resolvedTakeID = try c.decodeIfPresent(UUID.self, forKey: .resolvedTakeID)
        resolvedAssetPath = try c.decodeIfPresent(String.self, forKey: .resolvedAssetPath)
        resolvedContentHash = try c.decodeIfPresent(String.self, forKey: .resolvedContentHash)
        resolvedAt = try c.decodeIfPresent(Date.self, forKey: .resolvedAt)
        sourceVideoPath = try c.decodeIfPresent(String.self, forKey: .sourceVideoPath)
        sourceVideoContentHash = try c.decodeIfPresent(
            String.self, forKey: .sourceVideoContentHash)
        extractedImagePath = try c.decodeIfPresent(String.self, forKey: .extractedImagePath)
        extractedImageContentHash = try c.decodeIfPresent(
            String.self, forKey: .extractedImageContentHash)
        frameReference = try c.decodeIfPresent(String.self, forKey: .frameReference)
    }

    /// Resolves against the run-local map only. Returns false when the upstream
    /// shot has not produced a take *in this run* — the dependent shot then
    /// waits or blocks rather than borrowing another run's output.
    @discardableResult
    mutating func resolve(
        using map: RunLocalTakeMap,
        assetPath: (UUID) -> String?,
        contentHash: (String) -> String?,
        now: Date = Date()
    ) -> Bool {
        guard !isResolved else { return true }
        guard let takeID = map.take(runID: runID, shotID: upstreamShotID) else { return false }
        resolvedTakeID = takeID
        resolvedAssetPath = assetPath(takeID)
        resolvedContentHash = resolvedAssetPath.flatMap(contentHash)
        resolvedAt = now
        return true
    }
}
