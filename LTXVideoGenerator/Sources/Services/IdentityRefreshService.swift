import Foundation

/// Injectable boundary around the existing local-Vision assessment path. Tests
/// can supply deterministic visibility evidence without networking; production
/// still uses the same loopback-only provider as Character Sheet analysis.
protocol IdentitySourceAssessmentProviding {
    func assess(imageData: Data, sourceRelativePath: String) async -> IdentitySourceAssessment
}

struct LocalIdentitySourceAssessmentProvider: IdentitySourceAssessmentProviding {
    let environment: CharacterSheetVisionEnvironmentService

    init(environment: CharacterSheetVisionEnvironmentService = CharacterSheetVisionEnvironmentService()) {
        self.environment = environment
    }

    func assess(imageData: Data, sourceRelativePath: String) async -> IdentitySourceAssessment {
        let snapshot = await environment.refresh()
        guard snapshot.effectiveMode == .localVision, let model = snapshot.effectiveModel else {
            return IdentitySourceAssessor.unavailable(sourceRelativePath: sourceRelativePath)
        }
        return await IdentitySourceAssessor.assess(
            imageData: imageData,
            sourceRelativePath: sourceRelativePath,
            provider: OllamaCharacterSheetVisionProvider(model: model)
        )
    }
}

/// Runs Adaptive Identity Refresh for one upcoming shot.
///
/// Sequence: assess the frame the shot would inherit, ask the policy, and only
/// if it says so, transform the strongest existing anchor into a starting image
/// the shot can actually use. Everything is persisted as a managed project
/// asset so it survives a restart or a wait in the queue.
///
/// This is one stage *inside* the Auto Movie job. It does not create a second
/// global job and it does not render concurrently: it is awaited before the
/// next shot is enqueued, so the single-render guarantee is unchanged.
@MainActor
enum IdentityRefreshService {

    enum Outcome: Equatable {
        case notNeeded(reason: String)
        /// Policy asked for a refresh and one was produced.
        case refreshed(relativePath: String, reason: String)
        /// Policy asked for a refresh and it could not be produced. The shot
        /// continues on its inherited frame, and the reason is recorded rather
        /// than being silently dropped.
        case failed(reason: String)
    }

    /// Clears a refresh anchor that was derived from a take which is no longer
    /// the shot's continuity source — a Retake upstream must not leave the next
    /// shot pinned to an anchor built from the old visual state.
    nonisolated static func invalidateStaleAnchor(shotIndex: Int, in project: inout FilmProject) {
        guard shotIndex > 0, shotIndex < project.shots.count else { return }
        guard project.shots[shotIndex].identityRefreshAnchorRelativePath != nil,
              anchorIsStale(shotIndex: shotIndex, in: project) else { return }
        clearAnchor(shotIndex: shotIndex, in: &project)
    }

    /// Replace/Clear invalidates only refresh decisions that directly reused
    /// the superseded Opening Reference. Generated anchors remain independent
    /// managed pixels and retain their take-based staleness rule.
    nonisolated static func invalidateOpeningReferenceAnchors(in project: inout FilmProject) {
        let currentPath = project.openingReferenceImage?.projectRelativePath
        for index in project.shots.indices
        where project.shots[index].identityRefreshAnchorOrigin == .reusedOpeningReference
            && project.shots[index].identityRefreshAnchorRelativePath != currentPath {
            clearAnchor(shotIndex: index, in: &project)
        }
    }

    /// Evaluates and, if needed, produces the anchor for `shotIndex`.
    ///
    /// Never throws. A refresh that cannot be made degrades to normal
    /// continuity with a recorded reason: a movie must still finish.
    static func prepareIfNeeded(
        projectID: UUID,
        shotIndex: Int,
        store: FilmProjectStore = .shared,
        generator: IdentityAnchorGenerator = LTXTemporalRefreshGenerator(),
        assessor: IdentitySourceAssessmentProviding = LocalIdentitySourceAssessmentProvider()
    ) async -> Outcome {
        guard var project = store.project(id: projectID),
              shotIndex > 0, shotIndex < project.shots.count else {
            return .notNeeded(reason: "No shot to prepare.")
        }
        guard AutoMovieRunCoordinator(store: store)
            .resolvedContinuityMode(forShotAt: shotIndex, in: project)
            == .continueFromPrevious else {
            return .notNeeded(reason: "This shot is a Cut and inherits no previous-shot identity source.")
        }
        invalidateStaleAnchor(shotIndex: shotIndex, in: &project)
        store.save(project)

        var shot = project.shots[shotIndex]
        if let existing = shot.identityRefreshAnchorRelativePath, !existing.isEmpty,
           let existingURL = store.managedProjectAssetURL(projectID: projectID, relativePath: existing),
           ContinuityFrameExtractor.isUsableImage(atPath: existingURL.path) {
            return .refreshed(
                relativePath: existing,
                reason: shot.identityRefreshNote ?? "Reused the anchor already prepared for this shot.")
        } else if shot.identityRefreshAnchorRelativePath != nil {
            clearAnchor(shotIndex: shotIndex, in: &project)
            store.save(project)
            shot = project.shots[shotIndex]
        }

        let requirement = IdentityDetailRequirement.from(shotScale: shot.camera.shotScale)
        // Cheap deterministic exit first: most shots never need an assessment,
        // and running vision on all of them would add latency for nothing.
        let quickDecision = IdentityRefreshPolicy.decide(
            requirement: requirement, assessment: nil,
            hasExplicitStartingImage: shot.startingImageReferenceAssetID != nil)
        if case .useNormalContinuity(let reason) = quickDecision,
           !IdentityRefreshThresholds.requirementsNeedingFace.contains(requirement)
            || shot.startingImageReferenceAssetID != nil {
            return .notNeeded(reason: reason)
        }

        guard let continuityPath = shot.continuityImageRelativePath,
              let sourceURL = store.managedProjectAssetURL(
                  projectID: projectID, relativePath: continuityPath),
              let imageData = try? Data(contentsOf: sourceURL) else {
            return .notNeeded(reason: "This shot has no inherited frame to assess.")
        }

        let assessment = await assessor.assess(
            imageData: imageData, sourceRelativePath: continuityPath)

        let decision = IdentityRefreshPolicy.decide(
            requirement: requirement, assessment: assessment,
            hasExplicitStartingImage: shot.startingImageReferenceAssetID != nil)
        guard case .refresh(let reason) = decision else {
            if case .useNormalContinuity(let why) = decision { return .notNeeded(reason: why) }
            return .notNeeded(reason: "Normal continuity.")
        }

        // Before spending an LTX generation, search the scene-like images this
        // project already owns. Most-recent generated anchors are tried first;
        // the Opening Reference follows. Character Sheet plates are never
        // candidates here.
        let candidates = await reusableCandidates(
            project: project, projectID: projectID, targetShotIndex: shotIndex,
            store: store, assessor: assessor)
        let reuseDecision = SceneCompatibleIdentityAnchorResolver.resolve(
            targetShotIndex: shotIndex, shots: project.shots, candidates: candidates)
        if case .reuse(let candidate, let reuseReason) = reuseDecision {
            guard var saved = store.project(id: projectID), shotIndex < saved.shots.count else {
                return .failed(reason: "The project could not be read.")
            }
            saved.shots[shotIndex].identityRefreshAnchorRelativePath = candidate.relativePath
            saved.shots[shotIndex].identityRefreshAnchorOrigin = candidate.kind == .openingReference
                ? .reusedOpeningReference : .reusedPriorRefresh
            saved.shots[shotIndex].identityRefreshAnchorSourceShotID = candidate.sourceShotID
            saved.shots[shotIndex].identityRefreshSourceTakeID = candidate.sourceTakeID
            saved.shots[shotIndex].identityRefreshNote =
                "Identity Refresh: required — \(reason) \(reuseReason)"
            store.save(saved)
            return .refreshed(relativePath: candidate.relativePath, reason: reuseReason)
        }

        // Which existing image should the anchor be built from.
        let previousRefreshes = project.shots.prefix(shotIndex)
            .compactMap { $0.identityRefreshAnchorRelativePath }
        let anchor = IdentityAnchorSelector.select(
            previousRefreshPaths: Array(previousRefreshes),
            openingReferenceRelativePath: project.openingReferenceImage?.projectRelativePath)
        guard let anchorPath = anchor.relativePath,
              let anchorURL = store.managedProjectAssetURL(
                  projectID: projectID, relativePath: anchorPath),
              FileManager.default.fileExists(atPath: anchorURL.path) else {
            return record(
                .failed(reason: "Identity Refresh was needed but this movie has no identity anchor to build from."),
                projectID: projectID, shotIndex: shotIndex, store: store)
        }

        guard let produced = await generator.generateAnchor(
            fromAnchorImage: anchorURL, targetShot: shot, settings: project.settings) else {
            return record(
                .failed(reason: "Identity Refresh failed — continuing with normal continuity."),
                projectID: projectID, shotIndex: shotIndex, store: store)
        }

        let relativePath = "Assets/IdentityRefresh/shot-\(String(format: "%03d", shotIndex + 1))-\(UUID().uuidString).png"
        guard let destination = store.managedProjectAssetURL(
                  projectID: projectID, relativePath: relativePath) else {
            return record(
                .failed(reason: "Identity Refresh could not be stored — continuing with normal continuity."),
                projectID: projectID, shotIndex: shotIndex, store: store)
        }
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try produced.imageData.write(to: destination)
        } catch {
            return record(
                .failed(reason: "Identity Refresh could not be stored — continuing with normal continuity."),
                projectID: projectID, shotIndex: shotIndex, store: store)
        }
        guard ContinuityFrameExtractor.isUsableImage(atPath: destination.path) else {
            try? FileManager.default.removeItem(at: destination)
            return record(
                .failed(reason: "Identity Refresh produced an unusable image — continuing with normal continuity."),
                projectID: projectID, shotIndex: shotIndex, store: store)
        }

        guard var saved = store.project(id: projectID), shotIndex < saved.shots.count else {
            return .failed(reason: "The project could not be read.")
        }
        saved.shots[shotIndex].identityRefreshAnchorRelativePath = relativePath
        saved.shots[shotIndex].identityRefreshAnchorOrigin = .generated
        saved.shots[shotIndex].identityRefreshAnchorSourceShotID = nil
        saved.shots[shotIndex].identityRefreshSourceTakeID =
            saved.shots[shotIndex - 1].continuitySourceTake?.id
        let resolverReason: String
        if case .generate(let why) = reuseDecision { resolverReason = why }
        else { resolverReason = "No reusable anchor was selected." }
        saved.shots[shotIndex].identityRefreshNote =
            "Identity Refresh: generated — \(reason) \(resolverReason)"
        store.save(saved)
        return .refreshed(relativePath: relativePath, reason: reason)
    }

    private static func reusableCandidates(
        project: FilmProject,
        projectID: UUID,
        targetShotIndex: Int,
        store: FilmProjectStore,
        assessor: IdentitySourceAssessmentProviding
    ) async -> [SceneCompatibleIdentityAnchorResolver.Candidate] {
        var result: [SceneCompatibleIdentityAnchorResolver.Candidate] = []
        var seenPaths = Set<String>()

        for index in project.shots.indices.reversed() where index < targetShotIndex {
            let sourceShot = project.shots[index]
            guard let path = sourceShot.identityRefreshAnchorRelativePath,
                  !path.isEmpty,
                  sourceShot.identityRefreshAnchorOrigin != .reusedOpeningReference,
                  !seenPaths.contains(path),
                  let url = store.managedProjectAssetURL(projectID: projectID, relativePath: path),
                  ContinuityFrameExtractor.isUsableImage(atPath: url.path) else { continue }
            seenPaths.insert(path)
            var candidate = SceneCompatibleIdentityAnchorResolver.Candidate(
                kind: .previousRefresh,
                relativePath: path,
                assessment: nil,
                referenceShotIndex: index,
                sourceShotID: sourceShot.id,
                sourceTakeID: sourceShot.identityRefreshSourceTakeID,
                isStale: anchorIsStale(shotIndex: index, in: project)
            )
            // Metadata can reject a candidate without loading Vision again.
            if SceneCompatibleIdentityAnchorResolver.sceneIncompatibility(
                candidate: candidate, targetShotIndex: targetShotIndex, shots: project.shots
            ) == nil, let data = try? Data(contentsOf: url) {
                candidate.assessment = await assessor.assess(
                    imageData: data, sourceRelativePath: path)
            }
            result.append(candidate)
        }

        if let opening = project.openingReferenceImage?.projectRelativePath,
           !opening.isEmpty,
           !seenPaths.contains(opening),
           let url = store.managedProjectAssetURL(projectID: projectID, relativePath: opening),
           ContinuityFrameExtractor.isUsableImage(atPath: url.path) {
            var candidate = SceneCompatibleIdentityAnchorResolver.Candidate(
                kind: .openingReference,
                relativePath: opening,
                assessment: nil,
                referenceShotIndex: 0,
                sourceShotID: nil,
                sourceTakeID: nil,
                isStale: false
            )
            if SceneCompatibleIdentityAnchorResolver.sceneIncompatibility(
                candidate: candidate, targetShotIndex: targetShotIndex, shots: project.shots
            ) == nil, let data = try? Data(contentsOf: url) {
                if let cached = IdentitySourceAssessor.assessment(
                    fromOpeningReference: project.openingReferenceAppearance,
                    sourceRelativePath: opening
                ) {
                    candidate.assessment = cached
                } else {
                    candidate.assessment = await assessor.assess(
                        imageData: data, sourceRelativePath: opening)
                }
            }
            result.append(candidate)
        }
        return result
    }

    private nonisolated static func anchorIsStale(
        shotIndex: Int,
        in project: FilmProject,
        visited: Set<UUID> = []
    ) -> Bool {
        guard project.shots.indices.contains(shotIndex) else { return true }
        let shot = project.shots[shotIndex]
        guard let path = shot.identityRefreshAnchorRelativePath, !path.isEmpty else { return true }
        switch shot.identityRefreshAnchorOrigin {
        case .reusedOpeningReference:
            return project.openingReferenceImage?.projectRelativePath != path
        case .reusedPriorRefresh:
            guard let sourceID = shot.identityRefreshAnchorSourceShotID,
                  !visited.contains(sourceID),
                  let sourceIndex = project.shots.firstIndex(where: { $0.id == sourceID }),
                  project.shots[sourceIndex].identityRefreshAnchorRelativePath == path else {
                return true
            }
            var nextVisited = visited
            nextVisited.insert(sourceID)
            return anchorIsStale(shotIndex: sourceIndex, in: project, visited: nextVisited)
        case .generated, .none:
            guard shotIndex > 0 else { return true }
            return shot.identityRefreshSourceTakeID
                != project.shots[shotIndex - 1].continuitySourceTake?.id
        }
    }

    private nonisolated static func clearAnchor(shotIndex: Int, in project: inout FilmProject) {
        guard project.shots.indices.contains(shotIndex) else { return }
        project.shots[shotIndex].identityRefreshAnchorRelativePath = nil
        project.shots[shotIndex].identityRefreshAnchorOrigin = nil
        project.shots[shotIndex].identityRefreshAnchorSourceShotID = nil
        project.shots[shotIndex].identityRefreshSourceTakeID = nil
        project.shots[shotIndex].identityRefreshNote = nil
    }

    private static func record(
        _ outcome: Outcome, projectID: UUID, shotIndex: Int, store: FilmProjectStore
    ) -> Outcome {
        guard case .failed(let reason) = outcome,
              var project = store.project(id: projectID),
              shotIndex < project.shots.count else { return outcome }
        project.shots[shotIndex].identityRefreshNote = reason
        store.save(project)
        return outcome
    }
}
