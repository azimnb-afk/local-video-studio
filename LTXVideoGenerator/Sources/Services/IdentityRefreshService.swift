import Foundation

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
        let shot = project.shots[shotIndex]
        guard shot.identityRefreshAnchorRelativePath != nil else { return }
        let currentSourceTakeID = project.shots[shotIndex - 1].continuitySourceTake?.id
        if shot.identityRefreshSourceTakeID != currentSourceTakeID {
            project.shots[shotIndex].identityRefreshAnchorRelativePath = nil
            project.shots[shotIndex].identityRefreshSourceTakeID = nil
            project.shots[shotIndex].identityRefreshNote = nil
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
        environment: CharacterSheetVisionEnvironmentService = CharacterSheetVisionEnvironmentService()
    ) async -> Outcome {
        guard var project = store.project(id: projectID),
              shotIndex > 0, shotIndex < project.shots.count else {
            return .notNeeded(reason: "No shot to prepare.")
        }
        invalidateStaleAnchor(shotIndex: shotIndex, in: &project)
        store.save(project)

        let shot = project.shots[shotIndex]
        if let existing = shot.identityRefreshAnchorRelativePath, !existing.isEmpty {
            return .refreshed(relativePath: existing, reason: "Reused the anchor already prepared for this shot.")
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

        let snapshot = await environment.refresh()
        let assessment: IdentitySourceAssessment
        if snapshot.effectiveMode == .localVision, let model = snapshot.effectiveModel {
            assessment = await IdentitySourceAssessor.assess(
                imageData: imageData, sourceRelativePath: continuityPath,
                provider: OllamaCharacterSheetVisionProvider(model: model))
        } else {
            assessment = IdentitySourceAssessor.unavailable(sourceRelativePath: continuityPath)
        }

        let decision = IdentityRefreshPolicy.decide(
            requirement: requirement, assessment: assessment,
            hasExplicitStartingImage: shot.startingImageReferenceAssetID != nil)
        guard case .refresh(let reason) = decision else {
            if case .useNormalContinuity(let why) = decision { return .notNeeded(reason: why) }
            return .notNeeded(reason: "Normal continuity.")
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
        saved.shots[shotIndex].identityRefreshSourceTakeID =
            saved.shots[shotIndex - 1].continuitySourceTake?.id
        saved.shots[shotIndex].identityRefreshNote = "Identity Refresh: applied — \(reason)"
        store.save(saved)
        return .refreshed(relativePath: relativePath, reason: reason)
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
