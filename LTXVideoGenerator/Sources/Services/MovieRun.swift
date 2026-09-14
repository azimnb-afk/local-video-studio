import Foundation

/// Run-scoped execution for Auto Movie.
///
/// Deliberately thin. Everything Auto Movie shares with Storyboard — shot
/// state, the run-local take map, one-time dependency resolution, the frozen
/// continuity frame, seed allocation, the scheduler itself — is reused through
/// `RunScopedShotExecution` rather than copied. What is genuinely new here is
/// the phase Storyboard does not have: **final assembly**.
///
/// Assembly is why Auto Movie needs its own type at all. The existing
/// `FinalAssemblyService.plan(for: FilmProject)` chooses clips from
/// `project.shots.compactMap(\.selectedTake)` — a project-global selection. With
/// two runs of one movie in flight that would splice run A's shot into run B's
/// film. A run therefore freezes its own clip list and hands it over
/// explicitly.

// MARK: - Frozen plan

/// The movie composition, produced by one planner pass and copied verbatim into
/// every run of the batch.
struct FrozenMoviePlan: Codable, Equatable {
    /// Provenance only. Never used to re-read prompts, takes, continuity
    /// sources or assembly candidates after submission.
    var sourceProjectID: UUID
    var title: String
    var shots: [FrozenShotPlan]
    /// One engine for the whole movie. Auto Movie does not route per shot.
    var modelID: String
    var preset: String?
    var audioEnabled: Bool
    var textEncoderID: String?
    var directorMode: String?
    var openingReferenceRelativePath: String?
    var characterAnchorCharacterID: UUID?
    var characterAnchorAssetID: UUID?
    /// Global background music applied at assembly, frozen with the plan.
    var globalBGMGenre: String?
    /// Assembly configuration, frozen at the same moment as the plan.
    var assemblySpec: FrozenMovieAssemblySpec?

    var shotCount: Int { shots.count }
}

// MARK: - Assembly

/// One clip in a run's frozen assembly list.
///
/// Frozen identity, not a lookup: the take is named outright so nothing has to
/// consult a selection to rebuild the list later.
struct RunAssemblyClip: Codable, Equatable {
    var shotID: UUID
    var takeID: UUID
    var videoPath: String
    var order: Int
}

/// The assembly phase of one movie run.
struct MovieAssemblyState: Codable, Equatable {
    enum State: String, Codable, Equatable {
        /// Shots are still being generated.
        case waiting
        /// Every required shot succeeded; the clip list is frozen.
        case ready
        case running
        case completed
        case failed
        case cancelled
        case interrupted

        var isTerminal: Bool {
            switch self {
            case .completed, .failed, .cancelled: return true
            case .waiting, .ready, .running, .interrupted: return false
            }
        }
    }

    var state: State = .waiting
    var attemptNumber: Int = 1
    /// Frozen once, before assembly starts. Retrying assembly reuses it exactly
    /// rather than re-deriving it from whatever is selected now.
    var clips: [RunAssemblyClip] = []
    var outputPath: String?
    var failureReason: String?

    var hasFrozenClips: Bool { !clips.isEmpty }

    /// Stable identity of what would be assembled, for skip/compare logic.
    var signature: String? {
        guard hasFrozenClips else { return nil }
        return clips.sorted { $0.order < $1.order }
            .map { "\($0.takeID.uuidString):\($0.videoPath)" }
            .joined(separator: "|")
    }
}

// MARK: - The run

/// One independent Auto Movie run.
struct MovieRun: Codable, Equatable, Identifiable {
    var id: UUID
    var batchID: UUID
    var batchIndex: Int
    var plan: FrozenMoviePlan
    var shotStates: [ShotRunState]
    var takeMap: RunLocalTakeMap
    var assembly: MovieAssemblyState
    var isCancelled: Bool = false
    var createdAt: Date

    init(
        id: UUID = UUID(),
        batchID: UUID,
        batchIndex: Int,
        plan: FrozenMoviePlan,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.batchID = batchID
        self.batchIndex = batchIndex
        self.plan = plan
        self.createdAt = createdAt
        self.takeMap = RunLocalTakeMap()
        self.assembly = MovieAssemblyState()
        self.shotStates = plan.shots
            .sorted { $0.index < $1.index }
            .map { shot in
                var state = ShotRunState(shotID: shot.id)
                if shot.startSource == .previousShotOutput,
                   let upstream = plan.shots.first(where: { $0.index == shot.index - 1 }) {
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

    /// Every shot has produced a take in *this* run.
    var allShotsCompleted: Bool {
        !shotStates.isEmpty && shotStates.allSatisfy { $0.state == .completed }
    }

    /// A movie run is finished only once its film exists, not merely once its
    /// shots do.
    var isSettled: Bool {
        if isCancelled { return true }
        if assembly.state == .completed || assembly.state == .failed { return true }
        switch derivedShotState {
        case .failed, .dependencyBlocked, .cancelled: return true
        default: return false
        }
    }

    /// Lenient decoding: adding a field must never make an older persisted job
    /// undecodable and silently drop the user's queue.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        batchID = try c.decode(UUID.self, forKey: .batchID)
        batchIndex = try c.decodeIfPresent(Int.self, forKey: .batchIndex) ?? 0
        plan = try c.decode(FrozenMoviePlan.self, forKey: .plan)
        shotStates = try c.decodeIfPresent([ShotRunState].self, forKey: .shotStates) ?? []
        takeMap = try c.decodeIfPresent(RunLocalTakeMap.self, forKey: .takeMap) ?? RunLocalTakeMap()
        assembly = try c.decodeIfPresent(
            MovieAssemblyState.self, forKey: .assembly) ?? MovieAssemblyState()
        isCancelled = try c.decodeIfPresent(Bool.self, forKey: .isCancelled) ?? false
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}

extension MovieRun: RunScopedShotExecution {
    var orderedShots: [FrozenShotPlan] { plan.shots.sorted { $0.index < $1.index } }
    mutating func markCancelled() { isCancelled = true }
}

// MARK: - Submission

/// Freezes one planner result and expands it into N independent movie runs.
enum MovieRunBuilder {

    static func build(
        plan: FrozenMoviePlan,
        count: Int,
        batchID: UUID = UUID(),
        explicitSeed: Int? = nil
    ) -> [MovieRun] {
        let runCount = max(1, count)
        // count == 1 goes through exactly this path too: there is no simpler
        // second route that could develop different semantics.
        return (0..<runCount).map { index in
            var runPlan = plan
            runPlan.shots = seededShots(plan.shots, explicitSeed: explicitSeed)
            return MovieRun(batchID: batchID, batchIndex: index, plan: runPlan)
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
        let seeds = SeedAllocator.allocate(count: shots.count)
        return zip(shots, seeds).map { shot, seed in
            var seeded = shot
            seeded.seed = seed
            return seeded
        }
    }
}

// MARK: - Assembly driving

/// Decides and freezes what a run assembles.
enum MovieAssemblyDriver {

    /// Freezes the clip list from the run's **own** adopted takes.
    ///
    /// Never consults `project.shots.compactMap(\.selectedTake)`: that is a
    /// project-global selection, and with two runs in flight it would let one
    /// run's shot end up in the other run's film.
    static func freezeClips(in run: inout MovieRun, fileManager: FileManager = .default) -> Bool {
        guard run.assembly.clips.isEmpty else { return true }
        guard run.allShotsCompleted else { return false }

        var clips: [RunAssemblyClip] = []
        for shot in run.orderedShots {
            guard let state = run.state(of: shot.id),
                  let takeID = state.takeID,
                  let path = state.outputPath,
                  fileManager.fileExists(atPath: path) else {
                run.assembly.state = .failed
                run.assembly.failureReason =
                    "A shot's video is missing, so this work could not be assembled."
                return false
            }
            clips.append(RunAssemblyClip(
                shotID: shot.id, takeID: takeID, videoPath: path, order: shot.index))
        }
        run.assembly.clips = clips
        run.assembly.state = .ready
        return true
    }

    /// Where this run's finished film goes. Per run, so two candidates cannot
    /// overwrite one another.
    static func outputURL(runID: UUID) -> URL {
        AppStorageDirectory.root
            .appendingPathComponent("MovieRuns", isDirectory: true)
            .appendingPathComponent(runID.uuidString, isDirectory: true)
            .appendingPathComponent("final.mp4")
    }

    /// Retry assembles the same clips again; it never re-renders shots.
    static func retryAssembly(in run: inout MovieRun) {
        guard run.assembly.state == .failed || run.assembly.state == .interrupted else { return }
        run.assembly.attemptNumber += 1
        run.assembly.failureReason = nil
        run.assembly.state = run.assembly.hasFrozenClips ? .ready : .waiting
    }
}

// MARK: - Freezing the planner's result

/// Builds the frozen movie plan from the project the planner just produced.
///
/// Called **once** per submission, after the single Director/planner pass and
/// before run expansion. N candidates must never mean N creative plans.
enum FrozenMoviePlanBuilder {

    enum FreezeError: Error, Equatable, LocalizedError {
        /// A shot claims both an explicit starting image and "continue from the
        /// previous shot". Rejected here rather than resolved by a hidden
        /// precedence rule the UI and the backend could read differently.
        case ambiguousStartSource(shotIndex: Int)
        case emptyPlan

        var errorDescription: String? {
            switch self {
            case .ambiguousStartSource(let index):
                return "Shot \(index + 1) has both a starting image and “continue from the "
                    + "previous shot”. Choose one before generating."
            case .emptyPlan:
                return "The planner produced no shots, so there is nothing to generate."
            }
        }
    }

    static func freeze(
        project: FilmProject,
        directorMode: String?,
        store: FilmProjectStore = .shared,
        contentHash: (String) -> String? = { _ in nil }
    ) throws -> FrozenMoviePlan {
        let settings = project.settings
        let ordered = project.shots.sorted { $0.index < $1.index }
        guard !ordered.isEmpty else { throw FreezeError.emptyPlan }

        let shots: [FrozenShotPlan] = try ordered.enumerated().map { position, shot in
            // Auto Movie's own continuity policy, read from the frozen shot
            // rather than recomputed later against a mutable project.
            let continues = shot.continuityMode != .cut && position > 0
            let hasExplicit = shot.startingImageReferenceAssetID != nil
            if continues && hasExplicit {
                throw FreezeError.ambiguousStartSource(shotIndex: position)
            }
            // The Auto Movie sheet's Opening Reference Image *is* Shot 1's
            // starting image. The legacy coordinator resolved it at generation
            // time from the live project (`shotIndex == 0` ->
            // `.openingReference`); a run-local plan never re-reads the
            // project, so it has to be frozen here. Without this the first
            // shot silently rendered text-to-video with the user's chosen
            // first frame ignored. A shot-level starting image and a
            // continuation both still win over it, so this only fills the gap
            // the legacy resolver filled.
            let openingReference = position == 0 && !continues && !hasExplicit
                ? project.openingReferenceImage?.projectRelativePath
                : nil
            let explicitPath = openingReference ?? shot.continuityImageRelativePath
            let usesExplicitImage = hasExplicit || openingReference != nil
            let startSource: FrozenShotPlan.StartSource =
                continues ? .previousShotOutput : (usesExplicitImage ? .explicitImage : .none)

            return FrozenShotPlan(
                id: shot.id,
                index: position,
                title: shot.title,
                compiledPrompt: shot.compiledPrompt,
                durationSeconds: shot.durationSeconds,
                startSource: startSource,
                explicitStartImageRelativePath: startSource == .explicitImage ? explicitPath : nil,
                // Hash the bytes, which means resolving the managed asset
                // first: the path frozen above is project-relative, and
                // `FileManager.contents(atPath:)` cannot open one, so hashing
                // it directly silently produced nil on every real job. Only
                // the hash is taken from the resolved location — the stored
                // path stays relative, because an absolute one would not
                // survive a moved library. Same shape as
                // `FrozenMovieAssemblySpec.freeze`.
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

        return FrozenMoviePlan(
            sourceProjectID: project.id,
            title: project.title,
            shots: shots,
            modelID: settings.modelID,
            preset: settings.preset,
            audioEnabled: settings.audioEnabled ?? true,
            textEncoderID: settings.textEncoderID,
            directorMode: directorMode,
            openingReferenceRelativePath: project.openingReferenceImage?.projectRelativePath,
            characterAnchorCharacterID: project.characterAnchor.characterID,
            characterAnchorAssetID: project.characterAnchor.referenceAssetID,
            globalBGMGenre: settings.globalBGMGenre,
            // Frozen once, here, so every run shares one intended configuration
            // and none of them re-reads the project later.
            assemblySpec: FrozenMovieAssemblySpec.freeze(project: project))
    }
}

/// Turns the frozen movie plan into a queued, run-scoped `ProductionJob`.
enum MovieRunSubmission {

    static func makeJob(
        project: FilmProject,
        workCount: Int,
        directorMode: String?,
        explicitSeed: Int? = nil,
        store: FilmProjectStore = .shared,
        contentHash: (String) -> String? = { _ in nil }
    ) throws -> ProductionJob {
        let plan = try FrozenMoviePlanBuilder.freeze(
            project: project, directorMode: directorMode,
            store: store, contentHash: contentHash)
        let batchID = UUID()
        let runs = MovieRunBuilder.build(
            plan: plan, count: workCount, batchID: batchID, explicitSeed: explicitSeed)

        var snapshot = ProductionJobSnapshot()
        snapshot.snapshotVersion = RunProvenanceStamper.currentSnapshotVersion
        snapshot.batchID = batchID
        // Deliberately nil: a run-scoped job must not be resolvable back to the
        // editable project at execution time. Provenance lives on the frozen
        // plan's `sourceProjectID` instead, which nothing executes from.
        snapshot.projectID = nil
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
        snapshot.movieRuns = runs

        return ProductionJob(
            kind: .autoMovie,
            title: title(project.title, works: runs.count, shots: plan.shotCount),
            snapshot: snapshot)
    }

    static func title(_ projectTitle: String, works: Int, shots: Int) -> String {
        let name = projectTitle.isEmpty ? "Auto Movie" : projectTitle
        return works > 1 ? "\(name) × \(works)作品 (\(shots) Shot)" : "\(name) (\(shots) Shot)"
    }
}

/// Why a frozen explicit start image cannot be used for execution.
///
/// The request builders return `nil` for several different reasons — nothing
/// dispatchable, a continuation whose frame is gone, an unusable start image —
/// and the scheduler cannot tell them apart from `nil` alone. It used to
/// describe every one of them as "this shot's starting frame is unavailable",
/// which is continuation vocabulary: a user whose *own chosen picture* had been
/// moved or edited was told about a frame they had never seen.
///
/// Deliberately shaped like `H3EndingImageValidationError`, which already
/// solved this for the Ending Image: same two real cases, same wording style,
/// and the file is named by its last path component only — never the absolute
/// path, which says nothing to the user and leaks the library layout.
enum FrozenStartImageFailure: Equatable {
    /// The frozen path no longer resolves to anything inside the project.
    case unresolvable
    /// Resolved, but nothing is there to read any more.
    case missing(String)
    /// Still there, but not the bytes that were frozen.
    case changed(String)

    var message: String {
        switch self {
        case .unresolvable:
            return "開始画像の保存場所が見つかりません。"
                + "プロジェクトのファイルが移動された可能性があります。選び直してください。"
        case .missing(let name):
            return "開始画像が見つかりません（\(name)）。"
                + "キュー追加後に移動または削除された可能性があります。選び直してください。"
        case .changed(let name):
            return "開始画像がキュー追加後に変更されています（\(name)）。"
                + "意図しない画像で生成しないよう、生成を中止しました。再度キューに追加してください。"
        }
    }
}

/// Turns "the request builder returned nil" into something the user can act on.
///
/// `makeRequest` returns nil for more than one reason, and the scheduler used
/// to flatten all of them into one sentence about a starting *frame*. Asking
/// the shared verifier which of them actually applies costs one hash and lets
/// the queue say whether the user's own picture went missing, was edited, or
/// whether this was a continuation problem after all.
struct RunDispatchRefusal: Equatable {
    /// `failed` when the frozen input the user chose is invalid — that is not a
    /// dependency problem and should not be described as one.
    /// `dependencyBlocked` stays for the continuation case it was written for.
    var shotState: ShotRunState.State
    var message: String
    /// A frozen explicit image is shared by every run of the job, so its
    /// failure is batch-wide; a missing continuation frame is this run's own.
    var scope: FailureScope = .workLocalOrUnknown

    static let continuationUnavailable = RunDispatchRefusal(
        shotState: .dependencyBlocked,
        message: "前のショットの最終フレームが見つからないため、このショットは生成されませんでした。")

    private static func classify(
        shot: FrozenShotPlan?,
        projectID: UUID,
        resolveAsset: (String, UUID) -> String?,
        contentHash: (String) -> String?
    ) -> RunDispatchRefusal {
        guard let shot,
              let failure = MovieRunRequestBuilder.verifyFrozenStartImage(
                shot, projectID: projectID,
                resolveAsset: resolveAsset, contentHash: contentHash)
        else { return continuationUnavailable }
        return RunDispatchRefusal(shotState: .failed, message: failure.message, scope: .batchDeterministic)
    }

    static func classify(
        run: MovieRun,
        shotID: UUID,
        resolveAsset: (String, UUID) -> String? = {
            MovieRunRequestBuilder.resolveFrozenAssetPath($0, projectID: $1)
        },
        contentHash: (String) -> String? = { H3EndingImageCapability.contentHash(ofFileAt: $0) }
    ) -> RunDispatchRefusal {
        classify(
            shot: run.plan.shots.first { $0.id == shotID },
            projectID: run.plan.sourceProjectID,
            resolveAsset: resolveAsset, contentHash: contentHash)
    }

    static func classify(
        run: StoryboardRun,
        shotID: UUID,
        resolveAsset: (String, UUID) -> String? = {
            MovieRunRequestBuilder.resolveFrozenAssetPath($0, projectID: $1)
        },
        contentHash: (String) -> String? = { H3EndingImageCapability.contentHash(ofFileAt: $0) }
    ) -> RunDispatchRefusal {
        classify(
            shot: run.plan.shots.first { $0.id == shotID },
            projectID: run.plan.projectID,
            resolveAsset: resolveAsset, contentHash: contentHash)
    }
}

/// The reason a finished-but-unsuccessful job shows in the queue.
///
/// The scheduler only reports a dispatch refusal to the coordinator when the
/// job *starts*; mid-run it discards the outcome, because one shot refusing is
/// not a reason to tear down the other runs. That left the parent job saying
/// only "one or more works did not finish" — true, and useless. The shots
/// already recorded exactly what went wrong, so the summary reads it back
/// rather than inventing a second explanation that could disagree.
enum RunFailureSummary {

    static func reason(shotStates: [ShotRunState], fallback: String) -> String {
        // Distinct, order-preserving: three works failing the same way is one
        // thing to tell the user, not three.
        var seen = Set<String>()
        let reasons = shotStates
            .filter { $0.state == .failed || $0.state == .dependencyBlocked }
            .compactMap(\.failureReason)
            .filter { seen.insert($0).inserted }
        guard let first = reasons.first else { return fallback }
        return reasons.count == 1 ? first : first + "（ほか \(reasons.count - 1) 件）"
    }
}

/// Builds the render request for one shot of one movie run.
///
/// Reads only the frozen plan and the run's own state; the live project is
/// never consulted.
enum MovieRunRequestBuilder {

    /// The single place that decides whether a frozen explicit start image may
    /// be used, so the request builders and the scheduler can never disagree
    /// about why a shot was refused.
    ///
    /// Returns nil when the image is fine — or when the shot does not start
    /// from one at all, which is not a failure.
    static func verifyFrozenStartImage(
        _ shot: FrozenShotPlan,
        projectID: UUID,
        resolveAsset: (String, UUID) -> String? = { resolveFrozenAssetPath($0, projectID: $1) },
        contentHash: (String) -> String? = { H3EndingImageCapability.contentHash(ofFileAt: $0) }
    ) -> FrozenStartImageFailure? {
        guard shot.startSource == .explicitImage else { return nil }
        guard let relative = shot.explicitStartImageRelativePath,
              let resolved = resolveAsset(relative, projectID) else { return .unresolvable }
        let name = URL(fileURLWithPath: resolved).lastPathComponent
        // A plan frozen before hashing existed made no promise about bytes, so
        // there is nothing to break; it only has to still be readable.
        guard let expected = shot.explicitStartImageContentHash else {
            return contentHash(resolved) == nil ? .missing(name) : nil
        }
        guard let actual = contentHash(resolved) else { return .missing(name) }
        return actual == expected ? nil : .changed(name)
    }

    /// Turns a frozen project-relative asset path into one the renderer can
    /// actually open. The plan stores paths relative to the project (that is
    /// what survives a moved library); the backend only ever receives absolute
    /// paths. Reading the *directory layout* for a known project id is not the
    /// same as re-reading the editable project document, so the run stays
    /// independent of it.
    static func resolveFrozenAssetPath(
        _ path: String,
        projectID: UUID,
        store: FilmProjectStore = .shared
    ) -> String? {
        guard !path.isEmpty else { return nil }
        if path.hasPrefix("/") { return path }
        return store.managedProjectAssetURL(projectID: projectID, relativePath: path)?.path
    }

    static func makeRequest(
        run: MovieRun,
        shotID: UUID,
        takeID: UUID = UUID(),
        parameters: GenerationParameters,
        resolveAsset: (String, UUID) -> String? = { resolveFrozenAssetPath($0, projectID: $1) },
        contentHash: (String) -> String? = { H3EndingImageCapability.contentHash(ofFileAt: $0) }
    ) -> GenerationRequest? {
        guard let shot = run.plan.shots.first(where: { $0.id == shotID }),
              let state = run.state(of: shotID) else { return nil }

        var params = parameters
        params.seed = shot.seed

        let sourceImagePath: String?
        switch shot.startSource {
        case .previousShotOutput:
            // The frozen final-frame PNG, verified — never the upstream MP4.
            guard let dependency = state.dependency,
                  StoryboardContinuityFrame.verifyFrozen(dependency) == nil,
                  let frame = dependency.extractedImagePath else { return nil }
            sourceImagePath = frame
        case .explicitImage:
            // A frozen relative path is not openable as-is; a shot whose
            // starting image cannot be resolved must block rather than fall
            // back to text-to-video behind the user's back.
            guard let relative = shot.explicitStartImageRelativePath,
                  let resolved = resolveAsset(relative, run.plan.sourceProjectID) else { return nil }
            // The frozen hash is a promise about bytes, so it is checked before
            // those bytes are used. A file deleted or edited while the work sat
            // in the queue is refused outright — rendering different bytes, or
            // quietly dropping to text-to-video, are both ways of ignoring what
            // the user chose. A plan frozen before hashing existed has no
            // promise to check and still renders.
            //
            // Routed through the shared verifier so the reason the scheduler
            // reports to the user is, by construction, the reason this request
            // was refused.
            guard verifyFrozenStartImage(
                shot, projectID: run.plan.sourceProjectID,
                resolveAsset: resolveAsset, contentHash: contentHash) == nil else { return nil }
            sourceImagePath = resolved
        case .none:
            sourceImagePath = nil
        }

        var request = GenerationRequest(
            prompt: shot.compiledPrompt,
            brief: run.plan.title,
            sourceImagePath: sourceImagePath,
            disableAudio: !run.plan.audioEnabled,
            // One engine for the whole movie: taken from the frozen plan, never
            // re-resolved per shot.
            modelId: run.plan.modelID,
            textEncoderId: run.plan.textEncoderID ?? LTXTextEncoderCatalog.defaultTextEncoderID,
            parameters: params,
            preset: run.plan.preset,
            generationSource: "movieRun")
        // Deliberately NOT set. `filmProjectID` is the legacy project-advance
        // trigger: GenerationService feeds it to
        // `AutoMovieRunCoordinator.advance`, which would start a second,
        // project-global render of the same movie alongside this run. The
        // source project id lives on the frozen plan as provenance instead.
        request.shotID = shot.id
        request.takeID = takeID
        request.batchID = run.batchID
        request.batchIndex = run.batchIndex
        request.attemptNumber = state.attemptNumber
        return request
    }
}

// MARK: - Frozen assembly configuration

/// Everything final assembly needs that is *authoring* rather than *run output*.
///
/// Clip selection was already run-local, but assembly still reached back into
/// the live `FilmProject` for the canvas, the audio policy and the BGM /
/// ambience files. Editing the project — or deleting it — after submitting a
/// movie would then change or break the queued render. Freezing these at
/// submission is what makes a queued run genuinely independent of the document
/// it came from.
///
/// Only assembly-effective values live here. Anything already frozen on
/// `FrozenMoviePlan` is not repeated.
struct FrozenMovieAssemblySpec: Codable, Equatable {
    /// Canvas the normalising re-encode targets.
    var width: Int
    var height: Int
    var fps: Int
    /// Recorded on the assembled media's diagnostics.
    var modelID: String

    /// The whole audio policy, frozen as a value rather than re-read.
    var finalAudio: FinalAudioSettings

    /// Absolute paths to the managed audio assets, resolved once at submission,
    /// plus the bytes they had then. A file swapped afterwards is detected
    /// instead of silently mixed in.
    var bgmPath: String?
    var bgmContentHash: String?
    var ambiencePath: String?
    var ambienceContentHash: String?

    var hasFrozenAudio: Bool { bgmPath != nil || ambiencePath != nil }

    /// Freezes from the project the planner just produced. Called once per
    /// submission, never per run.
    static func freeze(
        project: FilmProject,
        store: FilmProjectStore = .shared,
        contentHash: (String) -> String? = { H3EndingImageCapability.contentHash(ofFileAt: $0) }
    ) -> FrozenMovieAssemblySpec {
        func resolve(_ asset: FinalAudioAsset?, active: Bool) -> (String?, String?) {
            guard active, let asset,
                  let url = store.managedProjectAssetURL(
                    projectID: project.id, relativePath: asset.projectRelativePath),
                  FileManager.default.fileExists(atPath: url.path) else { return (nil, nil) }
            return (url.path, contentHash(url.path))
        }
        let bgm = resolve(project.finalAudio.bgmAsset, active: project.finalAudio.isBGMActive)
        let ambience = resolve(
            project.finalAudio.ambienceAsset, active: project.finalAudio.isAmbienceActive)

        return FrozenMovieAssemblySpec(
            width: project.settings.width,
            height: project.settings.height,
            fps: project.settings.fps,
            modelID: project.settings.modelID,
            finalAudio: project.finalAudio,
            bgmPath: bgm.0, bgmContentHash: bgm.1,
            ambiencePath: ambience.0, ambienceContentHash: ambience.1)
    }

    /// Verifies the frozen audio files are still exactly what was frozen.
    /// Fails closed rather than mixing different bytes.
    func verifyFrozenAudio(
        contentHash: (String) -> String? = { H3EndingImageCapability.contentHash(ofFileAt: $0) }
    ) -> String? {
        func check(_ path: String?, _ expected: String?, _ label: String) -> String? {
            guard let path, let expected else { return nil }
            guard FileManager.default.fileExists(atPath: path) else {
                return "The \(label) chosen for this work is missing."
            }
            guard contentHash(path) == expected else {
                return "The \(label) chosen for this work has changed since it was queued."
            }
            return nil
        }
        return check(bgmPath, bgmContentHash, "background music")
            ?? check(ambiencePath, ambienceContentHash, "ambience track")
    }
}
