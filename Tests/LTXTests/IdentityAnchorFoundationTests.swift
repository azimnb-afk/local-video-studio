import Foundation
import AppKit
@testable import LTXVideoGeneratorCore

func runIdentityAnchorFoundationTests(_ t: TestKit) {
    t.suite("Identity Anchor Foundation — Phase 1 Architecture & Storage") {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("anchor-foundation-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = FilmProjectStore(projectsDirectory: tmpDir.appendingPathComponent("Projects"))
        let service = PreparedIdentityAnchorService.shared

        // 1. New Project Default Policy
        let newProject = FilmProject(title: "New Project")
        t.check(newProject.identityAnchor == nil, "New project identityAnchor is nil")
        t.checkEqual(newProject.reanchorPolicy, .automatic, "New project defaults to .automatic reanchor policy")
        t.checkEqual(newProject.maxContinueChainLength, 3, "New project default maxContinueChainLength is 3")

        // 2. Backward Compatibility JSON Decoding of Old Projects
        let legacyJSON = """
        {"id":"\(UUID().uuidString)","title":"Legacy Project"}
        """.data(using: .utf8)!

        do {
            let decodedLegacy = try JSONDecoder().decode(FilmProject.self, from: legacyJSON)
            t.check(decodedLegacy.identityAnchor == nil, "Legacy project decodes with identityAnchor == nil")
            t.checkEqual(decodedLegacy.reanchorPolicy, .off, "CRITICAL: Legacy project missing reanchorPolicy decodes as .off")
            t.checkEqual(decodedLegacy.maxContinueChainLength, 3, "Legacy project decodes safe default maxContinueChainLength 3")
        } catch {
            t.check(false, "Legacy project failed to decode: \(error)")
        }

        // 3. Create dummy source anchor image (500x400)
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

        var project = FilmProject(title: "Anchor Test Project")
        store.save(project)

        // 4. Import anchor to managed storage
        var importedAnchor: ProjectIdentityAnchor?
        do {
            importedAnchor = try service.importAnchor(
                sourceURL: sampleImageURL,
                projectID: project.id,
                characterName: "Hero",
                store: store
            )
        } catch {
            t.check(false, "Anchor import failed: \(error)")
        }

        t.check(importedAnchor != nil, "Anchor imported successfully")
        t.checkEqual(importedAnchor?.characterName, "Hero", "Anchor characterName preserved")
        t.checkEqual(importedAnchor?.originalWidth, 500, "Anchor originalWidth 500")
        t.checkEqual(importedAnchor?.originalHeight, 400, "Anchor originalHeight 400")

        guard let anchor = importedAnchor else { return }
        project.identityAnchor = anchor
        store.save(project)

        let managedOriginalURL = store.managedProjectAssetURL(
            projectID: project.id, relativePath: anchor.projectRelativePath
        )
        t.check(managedOriginalURL != nil, "Managed asset URL resolves")
        t.check(FileManager.default.fileExists(atPath: managedOriginalURL?.path ?? ""), "Managed asset exists on disk")

        // 5. Model-Aware Preparation: LTX 2.3 (512x300 requested -> 512x320 generation)
        var ltxPreparedURL: URL?
        do {
            ltxPreparedURL = try service.prepareAnchor(
                anchor: anchor,
                projectID: project.id,
                requestedWidth: 512,
                requestedHeight: 300,
                modelID: LTXModelCatalog.defaultModelID,
                store: store
            )
        } catch {
            t.check(false, "LTX anchor preparation failed: \(error)")
        }

        t.check(ltxPreparedURL != nil, "LTX prepared URL produced")
        if let ltxURL = ltxPreparedURL {
            let probe = MediaProbe.probe(path: ltxURL.path)
            t.checkEqual(probe?.width, 512, "LTX prepared width 512")
            t.checkEqual(probe?.height, 320, "LTX prepared height 320 (aligned to 64)")
        }

        // 6. Model-Aware Preparation: MiniMax H3 Tier 1 (512x288)
        var h3Tier1URL: URL?
        do {
            h3Tier1URL = try service.prepareAnchor(
                anchor: anchor,
                projectID: project.id,
                requestedWidth: 512,
                requestedHeight: 288,
                modelID: MiniMaxH3Configuration.modelID,
                store: store
            )
        } catch {
            t.check(false, "H3 Tier 1 anchor preparation failed: \(error)")
        }

        t.check(h3Tier1URL != nil, "H3 Tier 1 prepared URL produced")
        if let h3URL = h3Tier1URL {
            let probe = MediaProbe.probe(path: h3URL.path)
            t.checkEqual(probe?.width, 512, "H3 Tier 1 prepared width 512")
            t.checkEqual(probe?.height, 288, "H3 Tier 1 prepared height 288")
        }

        // 7. Model-Aware Preparation: MiniMax H3 Tier 2 (640x384)
        var h3Tier2URL: URL?
        do {
            h3Tier2URL = try service.prepareAnchor(
                anchor: anchor,
                projectID: project.id,
                requestedWidth: 640,
                requestedHeight: 384,
                modelID: MiniMaxH3Configuration.modelID,
                store: store
            )
        } catch {
            t.check(false, "H3 Tier 2 anchor preparation failed: \(error)")
        }

        t.check(h3Tier2URL != nil, "H3 Tier 2 prepared URL produced")
        if let h3URL = h3Tier2URL {
            let probe = MediaProbe.probe(path: h3URL.path)
            t.checkEqual(probe?.width, 640, "H3 Tier 2 prepared width 640")
            t.checkEqual(probe?.height, 384, "H3 Tier 2 prepared height 384")
        }

        // 8. Cache Key and Preparation Cache Invalidation
        let cacheKey = service.cacheKey(
            anchorID: anchor.id,
            modelID: LTXModelCatalog.defaultModelID,
            generationWidth: 512,
            generationHeight: 320
        )
        t.check(cacheKey.contains(anchor.id.uuidString), "Cache key contains anchor ID")
        t.check(cacheKey.contains("512x320"), "Cache key contains generation dimensions")
        t.check(cacheKey.contains("v1"), "Cache key contains policy version")

        // Replace anchor with a new one
        service.invalidatePreparedCache(anchorID: anchor.id, projectID: project.id, store: store)
        let preparedDir = store.managedProjectAssetURL(
            projectID: project.id, relativePath: "Assets/Anchors/Prepared"
        )
        let remainingFiles = (try? FileManager.default.contentsOfDirectory(atPath: preparedDir?.path ?? "")) ?? []
        t.check(!remainingFiles.contains { $0.contains(anchor.id.uuidString) }, "Prepared cache invalidated for old anchor ID")

        // 9. Conditioning Model Plan Integrity
        let condAsset = ConditioningAsset(
            role: .identityReference,
            sourceKind: .identityAnchor,
            originalPath: managedOriginalURL?.path ?? "",
            preparedPath: ltxPreparedURL?.path,
            conditioningStrength: 0.8
        )
        let plan = ShotConditioningPlan(identityReference: condAsset)
        t.check(plan.isConditioned, "Plan is marked conditioned")
        t.checkEqual(plan.effectivePrimaryImagePath, ltxPreparedURL?.path, "Plan effectivePrimaryImagePath returns prepared anchor path")

        // 10. Backward-compatible JSON decoding for Take and GenerationResult with provenance
        var take = Take(
            shotID: UUID(),
            modelID: "ltx23_distilled_q4",
            seed: 42,
            promptSnapshot: "Hero stands heroically",
            settingsSnapshot: GenerationParameters.default,
            requestedWidth: 512,
            requestedHeight: 320,
            fps: 24,
            requestedDuration: 2.0
        )
        take.transitionIntent = "cut"
        take.conditioningStrategy = "identityAnchor"
        take.continueChainIndex = 0
        take.identityAnchorID = anchor.id
        take.reanchorApplied = false

        let takeData = try? JSONEncoder().encode(take)
        let decodedTake = takeData != nil ? try? JSONDecoder().decode(Take.self, from: takeData!) : nil
        t.checkEqual(decodedTake?.transitionIntent, "cut", "Decoded take transitionIntent preserved")
        t.checkEqual(decodedTake?.conditioningStrategy, "identityAnchor", "Decoded take conditioningStrategy preserved")
        t.checkEqual(decodedTake?.reanchorApplied, false, "Decoded take reanchorApplied is false in Phase 1")
    }
}
