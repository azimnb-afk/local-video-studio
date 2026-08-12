import Foundation

/// Drives an Auto Movie run from planned shots to a finished movie:
/// sequential shot generation, continuity inheritance between consecutive
/// shots, and exactly one automatic Final Assembly at the end of the run.
///
/// Deliberate invariants:
/// - one generation at a time (shots are enqueued one after another, never in
///   a single upfront batch, because shot N+1's starting image only exists
///   after shot N has finished rendering)
/// - a `continue` shot never silently degrades to plain text-to-video; if its
///   inherited frame is unavailable the shot is blocked with a reason
/// - assembly runs once per completed run, guarded by a take-identity
///   signature so re-entry cannot produce duplicate movies
final class AutoMovieRunCoordinator {
    static let shared = AutoMovieRunCoordinator()

    /// Projects whose workflowMode marks them as automatic (Auto Movie).
    static let autoMovieWorkflowMode = "hybrid"

    /// Conditioning strength applied to a frame inherited from the previous
    /// shot. This is the ONLY place the value is defined.
    ///
    /// Backend semantics (verified in `mlx_video/conditioning/latent.py`, whose
    /// own docstring is inverted relative to its implementation):
    ///
    ///     denoise_mask = 1.0 - strength
    ///     output       = denoised * mask + clean_image_latent * (1 - mask)
    ///
    /// so 1.0 pins the conditioned frame to the source image exactly and lower
    /// values give the model room to recompose.
    ///
    /// Calibrated on a single real transition (same source frame, prompt, seed
    /// and render settings; only the strength varied), measuring SSIM against
    /// the inherited frame:
    ///
    ///     strength  SSIM(source, first)   SSIM(source, last)
    ///     1.0       0.966                 0.931   ← shot barely evolves
    ///     0.8       0.952                 0.827
    ///     0.7       0.943                 0.835
    ///     0.6       0.930                 0.819
    ///     0.4       0.891                 0.806   ← appearance starts drifting
    ///
    /// Dropping from 1.0 to 0.8 captures most of the available progression
    /// (0.105 of the 0.125 total) for 0.014 of anchor. Below 0.8 the shot does
    /// not progress further — 0.7 actually moved less than 0.8 — while the
    /// anchor keeps weakening, so 0.8 is the knee of the curve.
    ///
    /// This is a visual anchor, not identity conditioning; it improves
    /// continuity without guaranteeing the same person.
    static let continuityImageStrength: Double = 0.8

    /// Conditioning strength for a continuation that also asks for a large
    /// framing change, such as a full-figure shot followed by a detail insert.
    ///
    /// Measured on the real failing case (a medium-wide full figure inherited
    /// into a planned close-up of a key entering a lock; same source frame,
    /// prompt, seed and settings, only the strength varied):
    ///
    ///     strength  SSIM vs inherited   reframed?   coherent?
    ///     0.80      0.935               no          yes
    ///     0.65      0.909               no          yes
    ///     0.50      0.871               no          yes
    ///     0.35      —                   no          yes
    ///     0.20      —                   partly      no (a hand pasted over the old frame)
    ///
    /// No value in the usable range released the framing, and a text-to-video
    /// control with no inherited image at all did not produce the insert either
    /// — so the detail insert is a model/duration limit at this profile, not a
    /// strength-tuning problem. Loosening degrades coherence before it frees
    /// composition.
    ///
    /// 0.5 is therefore chosen as the loosest setting that still preserved the
    /// person, wardrobe and set in every sample, giving the renderer the most
    /// room where the plan asks for a big framing change. It is honest about
    /// what it buys: measurably more freedom, not a guaranteed reframe.
    static let reframeContinuityImageStrength: Double = 0.5

    enum RunStep: Equatable {
        /// Not an automatic project, or nothing left to do.
        case idle
        /// A generation is still in flight; the run resumes on completion.
        case waiting
        case enqueued(shotID: UUID)
        case blocked(shotID: UUID, reason: ContinuityBlockReason)
        case shotFailed(shotID: UUID)
        /// Every shot rendered, but take selection is ambiguous.
        case needsTakeSelection
        case assembling
        case assembled(path: String)
        case assemblyFailed(String)
        /// Already assembled for the current take selection.
        case completed
    }

    private let store: FilmProjectStore
    /// Guards against two assemblies for the same project overlapping.
    private var assemblingProjectIDs: Set<UUID> = []
    private let lock = NSLock()

    init(store: FilmProjectStore = .shared) {
        self.store = store
    }

    // MARK: - Continuity decisions

    /// Resolves a shot's declared mode into a concrete decision.
    /// The first shot never continues from anything, and `auto`/absent resolves
    /// conservatively to `cut` — "if unsure, cut" — because forcing every shot
    /// to inherit the previous frame drags composition and camera position
    /// across intentional scene changes.
    func resolvedContinuityMode(forShotAt index: Int, in project: FilmProject) -> ShotContinuityMode {
        guard index > 0, index < project.shots.count else { return .cut }
        guard project.continuityChainEnabled != false else { return .cut }
        switch project.shots[index].continuityMode {
        case .continueFromPrevious: return .continueFromPrevious
        case .cut, .none: return .cut
        case .auto: return inferContinuity(forShotAt: index, in: project)
        }
    }

    /// Deterministic fallback used when the planner said `auto` (or a Basic
    /// Director produced no continuity field at all). Only a clearly continuous
    /// beat continues; any location, time or character change cuts.
    func inferContinuity(forShotAt index: Int, in project: FilmProject) -> ShotContinuityMode {
        guard index > 0, index < project.shots.count else { return .cut }
        let previous = project.shots[index - 1]
        let current = project.shots[index]

        // An explicit continuity change between the shots means a new scene.
        let sceneChangeDirectives = ["location=", "timeOfDay=", "weather="]
        if current.explicitChanges.contains(where: { change in
            sceneChangeDirectives.contains { change.hasPrefix($0) }
        }) {
            return .cut
        }
        // Different location in the deterministic continuity state = cut.
        if let before = previous.continuityBefore, let now = current.continuityBefore {
            if !before.location.isEmpty, !now.location.isEmpty, before.location != now.location {
                return .cut
            }
            if !before.timeOfDay.isEmpty, !now.timeOfDay.isEmpty, before.timeOfDay != now.timeOfDay {
                return .cut
            }
        }
        // A different cast means we are not continuing the same action.
        if !previous.characterIDs.isEmpty, !current.characterIDs.isEmpty,
           Set(previous.characterIDs) != Set(current.characterIDs) {
            return .cut
        }
        // Establishing-style widening usually reads as a new setup.
        if current.camera.shotScale.contains("wide"), !previous.camera.shotScale.contains("wide") {
            return .cut
        }
        // Positive evidence of the same scene is required; absence of evidence
        // is not evidence of continuity, so anything unproven stays a cut.
        let sameLocation = !(previous.continuityBefore?.location ?? "").isEmpty
            && previous.continuityBefore?.location == current.continuityBefore?.location
        let sameCast = !previous.characterIDs.isEmpty
            && Set(previous.characterIDs) == Set(current.characterIDs)
        return (sameLocation || sameCast) ? .continueFromPrevious : .cut
    }

    // MARK: - Continuity asset preparation

    /// Extracts the previous shot's final frame into the project's continuity
    /// asset directory and records where it came from. Returns the failure
    /// reason instead of throwing so callers can persist it as shot state.
    @discardableResult
    func prepareContinuityAsset(projectID: UUID, shotIndex: Int) -> Result<String, ContinuityBlockReason> {
        guard var project = store.project(id: projectID),
              shotIndex > 0, shotIndex < project.shots.count else {
            return .failure(.previousShotIncomplete)
        }
        let previous = project.shots[shotIndex - 1]
        let candidates = continuitySourceCandidates(in: previous)
        guard !candidates.isEmpty else {
            return .failure(.previousShotIncomplete)
        }
        var foundExistingOutput = false

        // A completed Take is only usable for future continuity when its media
        // still exists and yields a valid frame. The explicit selection gets
        // first refusal; an invalid selection falls through to completed Takes
        // in newest-first order without changing the user's selection itself.
        for sourceTake in candidates {
            // Reuse an already-extracted frame when it still comes from this
            // exact Take. This also remains a usable fallback if the original
            // completed video was moved after its managed final frame existed.
            let shot = project.shots[shotIndex]
            if let existing = shot.continuityImageRelativePath,
               shot.continuitySourceTakeID == sourceTake.id,
               let url = store.managedProjectAssetURL(projectID: projectID, relativePath: existing),
               ContinuityFrameExtractor.isUsableImage(atPath: url.path) {
                project.shots[shotIndex].continuityBlockedReason = nil
                store.save(project)
                return .success(existing)
            }

            guard let videoPath = sourceTake.outputPath,
                  FileManager.default.fileExists(atPath: videoPath) else { continue }
            foundExistingOutput = true

            let relativePath = "Assets/Continuity/shot-\(String(format: "%03d", shotIndex + 1))-from-\(sourceTake.id.uuidString).png"
            guard let destination = store.managedProjectAssetURL(
                projectID: projectID, relativePath: relativePath
            ) else { continue }
            do {
                try ContinuityFrameExtractor.extractLastFrame(
                    videoPath: videoPath,
                    outputPath: destination.path
                )
            } catch {
                try? FileManager.default.removeItem(at: destination)
                continue
            }
            guard ContinuityFrameExtractor.isUsableImage(atPath: destination.path) else {
                try? FileManager.default.removeItem(at: destination)
                continue
            }

            let previousSourceTakeID = project.shots[shotIndex].continuitySourceTakeID
            project.shots[shotIndex].continuityImageRelativePath = relativePath
            project.shots[shotIndex].continuitySourceTakeID = sourceTake.id
            project.shots[shotIndex].continuityBlockedReason = nil
            IdentityRefreshService.invalidateAnchorForContinuitySourceChange(
                shotIndex: shotIndex,
                previousSourceTakeID: previousSourceTakeID,
                currentSourceTakeID: sourceTake.id,
                in: &project
            )
            store.save(project)
            return .success(relativePath)
        }

        return .failure(foundExistingOutput ? .frameExtractionFailed : .previousOutputMissing)
    }

    /// True when a shot inherited its frame from a take that is no longer the
    /// shot's continuity source (for example after a Retake upstream).
    func continuityIsStale(shotIndex: Int, in project: FilmProject) -> Bool {
        guard shotIndex > 0, shotIndex < project.shots.count else { return false }
        let shot = project.shots[shotIndex]
        guard shot.continuitySourceTakeID != nil else { return false }
        let currentSource = continuitySourceCandidates(in: project.shots[shotIndex - 1]).first
        return shot.continuitySourceTakeID != currentSource?.id
    }

    /// Future continuity source order. This deliberately does not change
    /// assembly selection: it only resolves the pixels used to start a newly
    /// planned continuation Take.
    private func continuitySourceCandidates(in shot: Shot) -> [Take] {
        let selected = shot.selectedTake.flatMap { take in
            take.status == .completed ? take : nil
        }
        let indices = Dictionary(uniqueKeysWithValues: shot.takes.enumerated().map { ($0.element.id, $0.offset) })
        let remaining = shot.takes
            .filter { $0.status == .completed && $0.id != selected?.id }
            .sorted { lhs, rhs in
                let lhsDate = lhs.generationCompletedAt ?? .distantPast
                let rhsDate = rhs.generationCompletedAt ?? .distantPast
                if lhsDate != rhsDate { return lhsDate > rhsDate }
                return (indices[lhs.id] ?? 0) > (indices[rhs.id] ?? 0)
            }
        return selected.map { [$0] + remaining } ?? remaining
    }

    // MARK: - Run advancement

    /// Index of the next shot that still needs a rendered take.
    func nextShotIndexNeedingGeneration(in project: FilmProject) -> Int? {
        project.shots
            .sorted { $0.index < $1.index }
            .first { shot in shot.takes.allSatisfy { $0.status != .completed } }
            .flatMap { shot in project.shots.firstIndex { $0.id == shot.id } }
    }

    func hasGenerationInFlight(in project: FilmProject) -> Bool {
        project.shots.contains { shot in
            shot.takes.contains { $0.status == .queued || $0.status == .generating }
        }
    }

    /// The shot `advance` would generate next, with its inherited frame already
    /// extracted, or nil when there is nothing to prepare.
    ///
    /// Exists so Adaptive Identity Refresh can look at the frame a shot is
    /// about to inherit *before* the take is planned — the take is where the
    /// starting image is chosen, so afterwards would be too late. Extraction is
    /// cached by source take, so calling this and then `advance` does the work
    /// once.
    func prepareNextShotContinuity(projectID: UUID) -> Int? {
        guard let project = store.project(id: projectID),
              project.workflowMode == Self.autoMovieWorkflowMode,
              !project.shots.isEmpty,
              !hasGenerationInFlight(in: project),
              let index = nextShotIndexNeedingGeneration(in: project), index > 0 else {
            return nil
        }
        let shot = project.shots[index]
        guard shot.startingImageReferenceAssetID == nil,
              resolvedContinuityMode(forShotAt: index, in: project) == .continueFromPrevious,
              case .success = prepareContinuityAsset(projectID: projectID, shotIndex: index) else {
            return nil
        }
        return index
    }

    /// Advances an automatic run by at most one step. Safe to call after every
    /// take completion; it is a no-op for manual storyboards.
    @discardableResult
    func advance(projectID: UUID, enqueue: ([GenerationRequest]) -> Void) -> RunStep {
        guard let project = store.project(id: projectID),
              project.workflowMode == Self.autoMovieWorkflowMode else {
            return .idle
        }
        guard !project.shots.isEmpty else { return .idle }
        if hasGenerationInFlight(in: project) { return .waiting }

        if let index = nextShotIndexNeedingGeneration(in: project) {
            let shot = project.shots[index]
            // A shot whose only attempts failed must not silently restart; the
            // user retries explicitly, which keeps failures visible.
            if shot.takes.contains(where: { $0.status == .failed || $0.status == .cancelled }) {
                return .shotFailed(shotID: shot.id)
            }
            let mode = resolvedContinuityMode(forShotAt: index, in: project)
            if mode == .continueFromPrevious, shot.startingImageReferenceAssetID == nil {
                switch prepareContinuityAsset(projectID: projectID, shotIndex: index) {
                case .failure(let reason):
                    markBlocked(projectID: projectID, shotID: shot.id, reason: reason)
                    return .blocked(shotID: shot.id, reason: reason)
                case .success:
                    break
                }
            }
            do {
                let coordinator = TakeGenerationCoordinator(store: store)
                let requests = try coordinator.planTakes(projectID: projectID, shotID: shot.id, count: 1)
                enqueue(requests)
                return .enqueued(shotID: shot.id)
            } catch {
                markBlocked(projectID: projectID, shotID: shot.id, reason: .continuityAssetMissing)
                return .blocked(shotID: shot.id, reason: .continuityAssetMissing)
            }
        }

        // Every shot has a rendered take: finish the run.
        autoSelectUnambiguousTakes(projectID: projectID)
        guard let refreshed = store.project(id: projectID) else { return .idle }
        return finishRun(project: refreshed)
    }

    private func markBlocked(projectID: UUID, shotID: UUID, reason: ContinuityBlockReason) {
        guard var project = store.project(id: projectID),
              let index = project.shots.firstIndex(where: { $0.id == shotID }) else { return }
        project.shots[index].continuityBlockedReason = reason
        store.save(project)
    }

    // MARK: - Take selection and assembly

    /// Promotes a lone completed take to the selected take. Shots with several
    /// completed takes and no selection are left alone: the app does not rank
    /// takes for the user.
    func autoSelectUnambiguousTakes(projectID: UUID) {
        guard var project = store.project(id: projectID) else { return }
        var changed = false
        for index in project.shots.indices {
            let shot = project.shots[index]
            guard shot.selectedTakeID == nil else { continue }
            let completed = shot.takes.filter { $0.status == .completed }
            if completed.count == 1 {
                project.shots[index].selectedTakeID = completed[0].id
                changed = true
            }
        }
        if changed { store.save(project) }
    }

    /// Identity of the takes an assembly would be built from. Assembly is
    /// skipped when this matches the last successful assembly.
    func assemblySignature(for project: FilmProject) -> String? {
        let ordered = project.shots.sorted { $0.index < $1.index }
        var parts: [String] = []
        for shot in ordered {
            guard let take = shot.assemblyCandidateTake, take.status == .completed,
                  let path = take.outputPath else {
                return nil
            }
            parts.append("\(take.id.uuidString):\(path)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "|")
    }

    /// Automatic assembly requires every shot rendered, nothing in flight, no
    /// blocked continuity, and a selection that is not ambiguous.
    func shouldAutoAssemble(project: FilmProject) -> Bool {
        guard !project.shots.isEmpty else { return false }
        guard !hasGenerationInFlight(in: project) else { return false }
        guard !project.shots.contains(where: { $0.continuityBlockedReason != nil }) else { return false }
        guard let signature = assemblySignature(for: project) else { return false }
        return signature != project.lastAssemblySignature
    }

    private func finishRun(project: FilmProject) -> RunStep {
        guard assemblySignature(for: project) != nil else { return .needsTakeSelection }
        if !shouldAutoAssemble(project: project) { return .completed }
        return .assembling
    }

    /// Runs Final Assembly once for the project. Blocking (FFmpeg); call from a
    /// background context.
    @discardableResult
    func performAutoAssembly(projectID: UUID) -> RunStep {
        guard let project = store.project(id: projectID) else { return .idle }
        guard shouldAutoAssemble(project: project) else { return .completed }
        guard let signature = assemblySignature(for: project) else { return .needsTakeSelection }

        lock.lock()
        if assemblingProjectIDs.contains(projectID) {
            lock.unlock()
            return .assembling
        }
        assemblingProjectIDs.insert(projectID)
        lock.unlock()
        defer {
            lock.lock()
            assemblingProjectIDs.remove(projectID)
            lock.unlock()
        }

        let outputPath = assemblyOutputPath(projectID: projectID)
        do {
            try Self.assembleBlocking(project: project, outputPath: outputPath)
        } catch {
            return .assemblyFailed(error.localizedDescription)
        }
        recordAssemblySuccess(projectID: projectID, signature: signature, outputPath: outputPath)
        return .assembled(path: outputPath)
    }

    func assemblyOutputPath(projectID: UUID) -> String {
        store.projectsDirectory
            .appendingPathComponent("\(projectID.uuidString)_final.mp4").path
    }

    /// Pure FFmpeg work on an immutable snapshot, so callers can run it off the
    /// main actor without touching the project store from another thread.
    static func assembleBlocking(project: FilmProject, outputPath: String) throws {
        _ = try FinalAssemblyService.assemble(project: project, outputPath: outputPath)
    }

    /// Records a finished assembly. Must run wherever the store is owned.
    func recordAssemblySuccess(projectID: UUID, signature: String, outputPath: String) {
        guard var saved = store.project(id: projectID) else { return }
        saved.lastAssemblySignature = signature
        saved.assembledMoviePath = outputPath
        saved.assembledAt = Date()
        store.save(saved)
    }

    /// Storyboard projects keep manual generation, but still get one automatic
    /// assembly when the last shot lands.
    @discardableResult
    func autoAssembleIfComplete(projectID: UUID) -> RunStep {
        guard let project = store.project(id: projectID) else { return .idle }
        guard !project.shots.isEmpty else { return .idle }
        autoSelectUnambiguousTakes(projectID: projectID)
        guard let refreshed = store.project(id: projectID) else { return .idle }
        guard shouldAutoAssemble(project: refreshed) else { return .completed }
        return performAutoAssembly(projectID: projectID)
    }
}
