import Foundation
@testable import LTXVideoGeneratorCore

func runLTXContinuityV1Tests(_ t: TestKit) {

    func shot(
        index: Int = 1,
        mode: ShotContinuityMode? = .continueFromPrevious,
        explicit: UUID? = nil,
        refresh: String? = nil,
        inherited: String? = nil
    ) -> Shot {
        var s = Shot(index: index, title: "S\(index)")
        s.continuityMode = mode
        s.startingImageReferenceAssetID = explicit
        s.identityRefreshAnchorRelativePath = refresh
        s.continuityImageRelativePath = inherited
        return s
    }

    t.suite("LTX Continuity v1 — source precedence") {
        // The order this asserts is the order in TakeGenerationCoordinator.
        // Stating it once in a testable place is what stops it drifting.
        let everything = shot(
            explicit: UUID(), refresh: "Assets/IdentityRefresh/r.png",
            inherited: "Assets/Continuity/c.png")
        t.checkEqual(
            LTXContinuityResolver.resolve(shot: everything, shotIndex: 1,
                                          hasOpeningReference: true, hasCharacterAnchor: true).source,
            .explicitStartingImage,
            "an image the user chose for this shot outranks everything else")

        let refreshWins = shot(refresh: "Assets/IdentityRefresh/r.png",
                               inherited: "Assets/Continuity/c.png")
        t.checkEqual(
            LTXContinuityResolver.resolve(shot: refreshWins, shotIndex: 1,
                                          hasOpeningReference: true, hasCharacterAnchor: true).source,
            .identityRefreshAnchor,
            "a refresh anchor replaces the inherited frame it was made to fix")

        let inherited = shot(inherited: "Assets/Continuity/c.png")
        t.checkEqual(
            LTXContinuityResolver.resolve(shot: inherited, shotIndex: 1,
                                          hasOpeningReference: true, hasCharacterAnchor: true).source,
            .inheritedLastFrame,
            "otherwise a continuing shot inherits the previous last frame")

        // Opening-shot-only sources.
        t.checkEqual(
            LTXContinuityResolver.resolve(shot: shot(index: 0, mode: .cut), shotIndex: 0,
                                          hasOpeningReference: true, hasCharacterAnchor: true).source,
            .openingReference,
            "the opening reference outranks the character anchor on shot 1")
        t.checkEqual(
            LTXContinuityResolver.resolve(shot: shot(index: 0, mode: .cut), shotIndex: 0,
                                          hasOpeningReference: false, hasCharacterAnchor: true).source,
            .characterAnchor,
            "the character anchor applies when there is no opening reference")
        t.checkEqual(
            LTXContinuityResolver.resolve(shot: shot(index: 2, mode: .cut), shotIndex: 2,
                                          hasOpeningReference: true, hasCharacterAnchor: true).source,
            .none,
            "neither opening-shot source is re-injected into a later shot")

        t.checkEqual(
            LTXContinuityResolver.resolve(shot: shot(index: 0, mode: .cut), shotIndex: 0,
                                          hasOpeningReference: false, hasCharacterAnchor: false).source,
            .none,
            "with no applicable source the shot is text-to-video")
    }

    t.suite("LTX Continuity v1 — CUT inherits nothing") {
        // A cut must not pick up a previous refresh or continuity asset. The
        // run coordinator does not write those onto a cut shot; this pins the
        // classification so a future change cannot leak one across.
        let cleanCut = shot(index: 2, mode: .cut)
        let resolution = LTXContinuityResolver.resolve(
            shot: cleanCut, shotIndex: 2, hasOpeningReference: true, hasCharacterAnchor: true)
        t.checkEqual(resolution.source, .none, "a mid-movie cut starts from nothing")
        t.checkEqual(resolution.effectiveStrategy, .none, "and performs no continuation")
        t.check(resolution.actualRelativePath == nil, "and hands LTX no image")

        let continuing = LTXContinuityResolver.resolve(
            shot: shot(inherited: "Assets/Continuity/c.png"), shotIndex: 1,
            hasOpeningReference: false, hasCharacterAnchor: false)
        t.checkEqual(continuing.effectiveStrategy, .lastFrame,
                     "a continuing shot performs a last-frame continuation")
    }

    t.suite("LTX Continuity v1 — requested, effective, actual") {
        var s = shot(mode: .auto, inherited: "Assets/Continuity/shot-002-from-abc.png")
        let takeID = UUID()
        s.continuitySourceTakeID = takeID
        let resolution = LTXContinuityResolver.resolve(
            shot: s, shotIndex: 1, hasOpeningReference: false, hasCharacterAnchor: false)
        t.checkEqual(resolution.requestedMode, .auto, "the plan's request is preserved verbatim")
        t.checkEqual(resolution.effectiveStrategy, .lastFrame,
                     "auto resolved to a last-frame continuation")
        t.checkEqual(resolution.actualRelativePath, "Assets/Continuity/shot-002-from-abc.png",
                     "the actual managed asset is named")
        t.checkEqual(resolution.previousTakeID, takeID,
                     "and so is the take it came from")
        let text = resolution.provenance
        for expected in ["Requested", "Effective", "Source", "Actual"] {
            t.check(text.contains(expected), "provenance states \(expected)")
        }
    }

    t.suite("LTX Continuity v1 — retake makes downstream state stale") {
        var project = FilmProject(title: "M")
        project.workflowMode = AutoMovieRunCoordinator.autoMovieWorkflowMode
        var first = Shot(index: 0, title: "One")
        let original = Take(shotID: first.id, modelID: "m", seed: 1,
                            promptSnapshot: "p", settingsSnapshot: .default,
                            requestedWidth: 768, requestedHeight: 512,
                            fps: 24, requestedDuration: 5, status: .completed)
        first.takes = [original]
        first.selectedTakeID = original.id

        var second = Shot(index: 1, title: "Two")
        second.continuityMode = .continueFromPrevious
        second.continuityImageRelativePath = "Assets/Continuity/shot-002-from-\(original.id).png"
        second.continuitySourceTakeID = original.id
        second.identityRefreshAnchorRelativePath = "Assets/IdentityRefresh/shot-002-x.png"
        second.identityRefreshSourceTakeID = original.id
        project.shots = [first, second]

        t.check(!AutoMovieRunCoordinator.shared.continuityIsStale(shotIndex: 1, in: project),
                "an untouched chain is not stale")

        // Retake shot 1: the selected take changes.
        var retaken = project
        let replacement = Take(shotID: first.id, modelID: "m", seed: 2,
                               promptSnapshot: "p", settingsSnapshot: .default,
                               requestedWidth: 768, requestedHeight: 512,
                               fps: 24, requestedDuration: 5, status: .completed)
        retaken.shots[0].takes = [original, replacement]
        retaken.shots[0].selectedTakeID = replacement.id

        t.check(AutoMovieRunCoordinator.shared.continuityIsStale(shotIndex: 1, in: retaken),
                "a retake upstream makes the inherited frame stale")
        IdentityRefreshService.invalidateStaleAnchor(shotIndex: 1, in: &retaken)
        t.check(retaken.shots[1].identityRefreshAnchorRelativePath == nil,
                "and the refresh anchor derived from the old take is dropped too")
    }

    t.suite("LTX Continuity v1 — aspect preparation boundary") {
        // The Opening Reference Aspect Fix is production accepted; this pins the
        // contract the continuity system depends on rather than re-testing it.
        let exact = try! ImageConditioningGeometry.scaleToFill(
            sourceWidth: 768, sourceHeight: 512, targetWidth: 768, targetHeight: 512)
        t.check(exact.isExactCanvas,
                "a continuity frame already at the target size needs no preparation")

        let wide = try! ImageConditioningGeometry.scaleToFill(
            sourceWidth: 1672, sourceHeight: 941, targetWidth: 768, targetHeight: 512)
        t.check(!wide.isExactCanvas, "a differently shaped source is prepared")
        t.checkEqual(wide.targetWidth, 768, "the prepared image lands on the target width")
        t.checkEqual(wide.targetHeight, 512, "and the target height")
        // Scale-to-fill then centre crop: the crop must stay inside the source
        // and keep the target's aspect, which is what stops the stretch the
        // Aspect Fix removed.
        t.check(wide.cropWidth <= 1672 && wide.cropHeight <= 941,
                "the crop stays inside the source image")
        let cropAspect = Double(wide.cropWidth) / Double(wide.cropHeight)
        t.check(abs(cropAspect - 768.0 / 512.0) < 0.02,
                "and matches the target aspect, so nothing is stretched")
    }
}
