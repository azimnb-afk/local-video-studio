import Foundation
import AppKit
@testable import LTXVideoGeneratorCore

func runIdentityAnchorFoundationTests(_ t: TestKit) {
    t.suite("Identity Anchor & Re-anchor Engine (Phase 1.1 + Phase 2)") {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("anchor-engine-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = FilmProjectStore(projectsDirectory: tmpDir.appendingPathComponent("Projects"))
        let service = PreparedIdentityAnchorService.shared

        // 1. GENERIC_NEW_PROJECT_DEFAULT_OFF & NEW_AUTOMOVIE_DEFAULT_AUTO
        let genericProject = FilmProject(title: "Generic Project")
        t.checkEqual(genericProject.reanchorPolicy, .off, "GENERIC_NEW_PROJECT_DEFAULT_OFF: generic init defaults to .off")
        t.checkEqual(genericProject.maxContinueChainLength, 3, "generic init default maxContinueChainLength is 3")

        var settings = ProjectSettings()
        settings.targetDurationSeconds = 5.0
        let sem = DispatchSemaphore(value: 0)
        var autoMovieProject: FilmProject? = nil
        Task {
            do {
                let res = try await HybridProjectCoordinator().makeProject(
                    title: "Auto Movie",
                    brief: "Hero walks across snowy mountains",
                    settings: settings,
                    directorEnabled: false
                )
                autoMovieProject = res.project
            } catch {
                print("AutoMovie planning error: \(error)")
            }
            sem.signal()
        }
        sem.wait()

        t.check(autoMovieProject != nil, "Auto Movie project planned")
        t.checkEqual(autoMovieProject?.reanchorPolicy, .automatic, "NEW_AUTOMOVIE_DEFAULT_AUTO: Auto Movie creation sets policy to .automatic")

        // 2. OLD_PROJECT_DEFAULT_OFF (Legacy project backward compatibility)
        let legacyJSON = """
        {"id":"\(UUID().uuidString)","title":"Legacy Project"}
        """.data(using: .utf8)!
        do {
            let decodedLegacy = try JSONDecoder().decode(FilmProject.self, from: legacyJSON)
            t.check(decodedLegacy.identityAnchor == nil, "OLD_PROJECT: identityAnchor is nil")
            t.checkEqual(decodedLegacy.reanchorPolicy, .off, "OLD_PROJECT_DEFAULT_OFF: decodes as .off")
            t.checkEqual(decodedLegacy.maxContinueChainLength, 3, "OLD_PROJECT: maxContinueChainLength is 3")
        } catch {
            t.check(false, "Legacy project decode failed: \(error)")
        }

        // 3. Create sample anchor image in storage
        let sampleImageURL = tmpDir.appendingPathComponent("sample_character.png")
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 500,
            pixelsHigh: 400,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 500 * 4,
            bitsPerPixel: 32
        )!
        let pngData = rep.representation(using: .png, properties: [:])!
        try? pngData.write(to: sampleImageURL)

        var project = FilmProject(title: "Engine Test Project")
        store.save(project)
        let anchor = try! service.importAnchor(
            sourceURL: sampleImageURL,
            projectID: project.id,
            characterName: "Hero",
            store: store
        )
        project.identityAnchor = anchor
        store.save(project)

        // 4. AUTO_WITHOUT_ANCHOR_NOOP
        let noAnchorDecision = IdentityReanchorEngine.decide(
            reanchorPolicy: .automatic,
            identityAnchor: nil,
            shotIndex: 0,
            transitionIntent: .cut,
            previousContinueChainIndex: 0,
            hasExplicitShotSource: false,
            hasIdentityRefreshAsset: false
        )
        t.checkEqual(noAnchorDecision.shouldApplyAnchor, false, "AUTO_WITHOUT_ANCHOR: shouldApplyAnchor is false")
        t.checkEqual(noAnchorDecision.reason, .noAnchor, "AUTO_WITHOUT_ANCHOR: reason is .noAnchor")

        // 5. OFF_WITH_ANCHOR_NOOP
        let offPolicyDecision = IdentityReanchorEngine.decide(
            reanchorPolicy: .off,
            identityAnchor: anchor,
            shotIndex: 0,
            transitionIntent: .cut,
            previousContinueChainIndex: 0,
            hasExplicitShotSource: false,
            hasIdentityRefreshAsset: false
        )
        t.checkEqual(offPolicyDecision.shouldApplyAnchor, false, "OFF_WITH_ANCHOR: shouldApplyAnchor is false")
        t.checkEqual(offPolicyDecision.reason, .disabled, "OFF_WITH_ANCHOR: reason is .disabled")

        // 6. EXPLICIT_SOURCE_BEATS_REANCHOR
        let explicitSourceDecision = IdentityReanchorEngine.decide(
            reanchorPolicy: .automatic,
            identityAnchor: anchor,
            shotIndex: 0,
            transitionIntent: .cut,
            previousContinueChainIndex: 0,
            hasExplicitShotSource: true,
            hasIdentityRefreshAsset: false
        )
        t.checkEqual(explicitSourceDecision.shouldApplyAnchor, false, "EXPLICIT_SOURCE: shouldApplyAnchor is false")
        t.checkEqual(explicitSourceDecision.reason, .explicitShotSource, "EXPLICIT_SOURCE: reason is .explicitShotSource")
        t.checkEqual(explicitSourceDecision.conditioningStrategy, .explicitSource, "EXPLICIT_SOURCE: strategy is .explicitSource")

        // 7. IDENTITY_REFRESH_PRIORITY_DETERMINISTIC
        let refreshDecision = IdentityReanchorEngine.decide(
            reanchorPolicy: .automatic,
            identityAnchor: anchor,
            shotIndex: 1,
            transitionIntent: .continueFromPrevious,
            previousContinueChainIndex: 0,
            hasExplicitShotSource: false,
            hasIdentityRefreshAsset: true
        )
        t.checkEqual(refreshDecision.shouldApplyAnchor, false, "IDENTITY_REFRESH: shouldApplyAnchor is false")
        t.checkEqual(refreshDecision.reason, .identityRefreshAsset, "IDENTITY_REFRESH: reason is .identityRefreshAsset")
        t.checkEqual(refreshDecision.conditioningStrategy, .identityRefresh, "IDENTITY_REFRESH: strategy is .identityRefresh")

        // 8. AUTO_CUT_USES_IDENTITY_ANCHOR & NATURAL_CUT_RESETS_CHAIN_INDEX
        let cutDecision = IdentityReanchorEngine.decide(
            reanchorPolicy: .automatic,
            identityAnchor: anchor,
            shotIndex: 3,
            transitionIntent: .cut,
            previousContinueChainIndex: 2,
            hasExplicitShotSource: false,
            hasIdentityRefreshAsset: false
        )
        t.checkEqual(cutDecision.shouldApplyAnchor, true, "AUTO_CUT: shouldApplyAnchor is true")
        t.checkEqual(cutDecision.reason, .naturalCut, "AUTO_CUT: reason is .naturalCut")
        t.checkEqual(cutDecision.conditioningStrategy, .identityAnchor, "AUTO_CUT: strategy is .identityAnchor")
        t.checkEqual(cutDecision.resultingContinueChainIndex, 0, "NATURAL_CUT_RESETS_CHAIN_INDEX: chain index reset to 0")
        t.checkEqual(cutDecision.reanchorApplied, true, "AUTO_CUT: reanchorApplied is true")

        // 9. AUTO_CONTINUE_USES_PREVIOUS_FINAL & CONTINUE_CHAIN_INDEX_INCREMENTS
        let continueDecision = IdentityReanchorEngine.decide(
            reanchorPolicy: .automatic,
            identityAnchor: anchor,
            shotIndex: 1,
            transitionIntent: .continueFromPrevious,
            previousContinueChainIndex: 0,
            hasExplicitShotSource: false,
            hasIdentityRefreshAsset: false
        )
        t.checkEqual(continueDecision.shouldApplyAnchor, false, "AUTO_CONTINUE: shouldApplyAnchor is false")
        t.checkEqual(continueDecision.reason, .chainWithinLimit, "AUTO_CONTINUE: reason is .chainWithinLimit")
        t.checkEqual(continueDecision.conditioningStrategy, .previousFinalFrame, "AUTO_CONTINUE: strategy is .previousFinalFrame")
        t.checkEqual(continueDecision.resultingContinueChainIndex, 1, "CONTINUE_CHAIN_INDEX_INCREMENTS: chain index incremented to 1")
        t.checkEqual(continueDecision.reanchorApplied, false, "AUTO_CONTINUE: reanchorApplied is false")

        // 10. LONG_CHAIN_DOES_NOT_FORCE_CUT & LONG_CHAIN_SETS_REANCHOR_RECOMMENDED
        let longChainDecision = IdentityReanchorEngine.decide(
            reanchorPolicy: .automatic,
            identityAnchor: anchor,
            shotIndex: 4,
            transitionIntent: .continueFromPrevious,
            previousContinueChainIndex: 3,
            maxContinueChainLength: 3,
            hasExplicitShotSource: false,
            hasIdentityRefreshAsset: false
        )
        t.checkEqual(longChainDecision.shouldApplyAnchor, false, "LONG_CHAIN: does NOT apply anchor (preserves temporal frame)")
        t.checkEqual(longChainDecision.conditioningStrategy, .previousFinalFrame, "LONG_CHAIN: strategy remains .previousFinalFrame")
        t.checkEqual(longChainDecision.resultingContinueChainIndex, 4, "LONG_CHAIN: chain index becomes 4")
        t.checkEqual(longChainDecision.shouldRecommendReanchor, true, "LONG_CHAIN_SETS_REANCHOR_RECOMMENDED: shouldRecommendReanchor is true")
        t.checkEqual(longChainDecision.reason, .longContinueChain, "LONG_CHAIN: reason is .longContinueChain")

        // 11. H3_ANCHOR_RESOLUTION_MATCHES_GENERATION
        let h3PreparedURL = try! service.prepareAnchor(
            anchor: anchor,
            projectID: project.id,
            requestedWidth: 512,
            requestedHeight: 288,
            modelID: MiniMaxH3Configuration.modelID,
            store: store
        )
        let h3Probe = MediaProbe.probe(path: h3PreparedURL.path)
        t.checkEqual(h3Probe?.width, 512, "H3_ANCHOR_RESOLUTION: width matches generation (512)")
        t.checkEqual(h3Probe?.height, 288, "H3_ANCHOR_RESOLUTION: height matches generation (288)")

        // 12. LTX_ANCHOR_RESOLUTION_MATCHES_GENERATION
        let ltxPreparedURL = try! service.prepareAnchor(
            anchor: anchor,
            projectID: project.id,
            requestedWidth: 512,
            requestedHeight: 300,
            modelID: LTXModelCatalog.defaultModelID,
            store: store
        )
        let ltxProbe = MediaProbe.probe(path: ltxPreparedURL.path)
        t.checkEqual(ltxProbe?.width, 512, "LTX_ANCHOR_RESOLUTION: width matches generation (512)")
        t.checkEqual(ltxProbe?.height, 320, "LTX_ANCHOR_RESOLUTION: height matches 64-aligned generation (320)")

        // 13. DRY-RUN PROVENANCE MATRIX (5-Shot Plan: CUT -> CONTINUE -> CONTINUE -> CUT -> CONTINUE)
        let shotSequence: [ShotContinuityMode] = [.cut, .continueFromPrevious, .continueFromPrevious, .cut, .continueFromPrevious]
        var currentChainIndex = 0
        var recordedDecisions: [IdentityReanchorDecision] = []

        for (idx, mode) in shotSequence.enumerated() {
            let dec = IdentityReanchorEngine.decide(
                reanchorPolicy: .automatic,
                identityAnchor: anchor,
                shotIndex: idx,
                transitionIntent: mode,
                previousContinueChainIndex: currentChainIndex,
                maxContinueChainLength: 3,
                hasExplicitShotSource: false,
                hasIdentityRefreshAsset: false
            )
            recordedDecisions.append(dec)
            currentChainIndex = dec.resultingContinueChainIndex
        }

        // Validate Shot 1: CUT -> ANCHOR / chain 0 / reanchorApplied true
        t.checkEqual(recordedDecisions[0].conditioningStrategy, .identityAnchor, "Dry-Run Shot 1: identityAnchor")
        t.checkEqual(recordedDecisions[0].resultingContinueChainIndex, 0, "Dry-Run Shot 1: chainIndex 0")
        t.checkEqual(recordedDecisions[0].reanchorApplied, true, "Dry-Run Shot 1: reanchorApplied true")

        // Validate Shot 2: CONTINUE -> PREVIOUS / chain 1 / reanchorApplied false
        t.checkEqual(recordedDecisions[1].conditioningStrategy, .previousFinalFrame, "Dry-Run Shot 2: previousFinalFrame")
        t.checkEqual(recordedDecisions[1].resultingContinueChainIndex, 1, "Dry-Run Shot 2: chainIndex 1")
        t.checkEqual(recordedDecisions[1].reanchorApplied, false, "Dry-Run Shot 2: reanchorApplied false")

        // Validate Shot 3: CONTINUE -> PREVIOUS / chain 2 / reanchorApplied false
        t.checkEqual(recordedDecisions[2].conditioningStrategy, .previousFinalFrame, "Dry-Run Shot 3: previousFinalFrame")
        t.checkEqual(recordedDecisions[2].resultingContinueChainIndex, 2, "Dry-Run Shot 3: chainIndex 2")
        t.checkEqual(recordedDecisions[2].reanchorApplied, false, "Dry-Run Shot 3: reanchorApplied false")

        // Validate Shot 4: CUT -> RE-ANCHOR / chain 0 / reanchorApplied true
        t.checkEqual(recordedDecisions[3].conditioningStrategy, .identityAnchor, "Dry-Run Shot 4: identityAnchor (RE-ANCHOR)")
        t.checkEqual(recordedDecisions[3].resultingContinueChainIndex, 0, "Dry-Run Shot 4: chainIndex 0 (RESET)")
        t.checkEqual(recordedDecisions[3].reanchorApplied, true, "Dry-Run Shot 4: reanchorApplied true")

        // Validate Shot 5: CONTINUE -> PREVIOUS / chain 1 / reanchorApplied false
        t.checkEqual(recordedDecisions[4].conditioningStrategy, .previousFinalFrame, "Dry-Run Shot 5: previousFinalFrame")
        t.checkEqual(recordedDecisions[4].resultingContinueChainIndex, 1, "Dry-Run Shot 5: chainIndex 1")
        t.checkEqual(recordedDecisions[4].reanchorApplied, false, "Dry-Run Shot 5: reanchorApplied false")
    }
}
