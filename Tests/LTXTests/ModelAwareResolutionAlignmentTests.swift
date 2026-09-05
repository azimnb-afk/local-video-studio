import Foundation
@testable import LTXVideoGeneratorCore

func runModelAwareResolutionAlignmentTests(_ t: TestKit) {
    t.suite("Model-Aware Resolution Alignment Policy & 3-Layer Model") {

        // 1. Already aligned (64 multiple) with LTX 2.3 Distilled
        let aligned = ModelAwareResolutionAlignment.align(
            requestedWidth: 512,
            requestedHeight: 320,
            modelID: LTXModelCatalog.defaultModelID
        )
        t.checkEqual(aligned.requested.width, 512, "Aligned 512x320: requested width 512")
        t.checkEqual(aligned.requested.height, 320, "Aligned 512x320: requested height 320")
        t.checkEqual(aligned.generation.width, 512, "Aligned 512x320: generation width 512")
        t.checkEqual(aligned.generation.height, 320, "Aligned 512x320: generation height 320")
        t.checkEqual(aligned.finalOutput.width, 512, "Aligned 512x320: final width 512")
        t.checkEqual(aligned.finalOutput.height, 320, "Aligned 512x320: final height 320")
        t.check(aligned.crop == nil, "Aligned 512x320: crop is nil")
        t.checkEqual(aligned.alignmentMultiple, 64, "Aligned 512x320: alignment multiple 64")
        t.checkEqual(aligned.alignmentReason, .alreadyCompatible, "Aligned 512x320: reason alreadyCompatible")

        // 2. Needs height expansion (1280x720 -> 1280x768)
        let hd = ModelAwareResolutionAlignment.align(
            requestedWidth: 1280,
            requestedHeight: 720,
            modelID: LTXModelCatalog.defaultModelID
        )
        t.checkEqual(hd.requested.width, 1280, "1280x720: requested width 1280")
        t.checkEqual(hd.requested.height, 720, "1280x720: requested height 720")
        t.checkEqual(hd.generation.width, 1280, "1280x720: generation width 1280")
        t.checkEqual(hd.generation.height, 768, "1280x720: generation height 768 (expanded to multiple of 64)")
        t.checkEqual(hd.finalOutput.width, 1280, "1280x720: final width 1280")
        t.checkEqual(hd.finalOutput.height, 720, "1280x720: final height 720")
        t.check(hd.crop != nil, "1280x720: crop present")
        t.checkEqual(hd.crop?.top, 24, "1280x720: crop top 24")
        t.checkEqual(hd.crop?.bottom, 24, "1280x720: crop bottom 24")
        t.checkEqual(hd.crop?.left, 0, "1280x720: crop left 0")
        t.checkEqual(hd.crop?.right, 0, "1280x720: crop right 0")
        t.checkEqual(hd.alignmentReason, .modelGridAlignment, "1280x720: reason modelGridAlignment")

        // 3. Needs expansion on height (1920x1080 -> 1920x1088)
        let fhd = ModelAwareResolutionAlignment.align(
            requestedWidth: 1920,
            requestedHeight: 1080,
            modelID: LTXModelCatalog.defaultModelID
        )
        t.checkEqual(fhd.requested.width, 1920, "1920x1080: requested width 1920")
        t.checkEqual(fhd.requested.height, 1080, "1920x1080: requested height 1080")
        t.checkEqual(fhd.generation.width, 1920, "1920x1080: generation width 1920")
        t.checkEqual(fhd.generation.height, 1088, "1920x1080: generation height 1088 (expanded from 1080)")
        t.checkEqual(fhd.finalOutput.width, 1920, "1920x1080: final width 1920")
        t.checkEqual(fhd.finalOutput.height, 1080, "1920x1080: final height 1080")
        t.checkEqual(fhd.crop?.top, 4, "1920x1080: crop top 4")
        t.checkEqual(fhd.crop?.bottom, 4, "1920x1080: crop bottom 4")
        t.checkEqual(fhd.crop?.left, 0, "1920x1080: crop left 0")
        t.checkEqual(fhd.crop?.right, 0, "1920x1080: crop right 0")

        // 4. Portrait equivalent (1080x1920 -> 1088x1920)
        let portraitFHD = ModelAwareResolutionAlignment.align(
            requestedWidth: 1080,
            requestedHeight: 1920,
            modelID: LTXModelCatalog.defaultModelID
        )
        t.checkEqual(portraitFHD.generation.width, 1088, "1080x1920: generation width 1088")
        t.checkEqual(portraitFHD.generation.height, 1920, "1080x1920: generation height 1920")
        t.checkEqual(portraitFHD.crop?.left, 4, "1080x1920: crop left 4")
        t.checkEqual(portraitFHD.crop?.right, 4, "1080x1920: crop right 4")
        t.checkEqual(portraitFHD.crop?.top, 0, "1080x1920: crop top 0")
        t.checkEqual(portraitFHD.crop?.bottom, 0, "1080x1920: crop bottom 0")

        // 5. Odd delta deterministic crop distribution (759 -> 768, delta=9)
        let oddDelta = ModelAwareResolutionAlignment.align(
            requestedWidth: 759,
            requestedHeight: 512,
            modelID: LTXModelCatalog.defaultModelID
        )
        t.checkEqual(oddDelta.generation.width, 768, "759x512: generation width 768")
        t.checkEqual(oddDelta.crop?.left, 4, "759x512: crop left 4 (delta 9 -> 4/5)")
        t.checkEqual(oddDelta.crop?.right, 5, "759x512: crop right 5")

        // 6. ltx-2-mlx backend (multiple 32)
        let ltx2mlxAligned = ModelAwareResolutionAlignment.align(
            requestedWidth: 700,
            requestedHeight: 500,
            modelID: LTX25ModelCatalog.ltx25ExperimentalID
        )
        t.checkEqual(ltx2mlxAligned.generation.width, 704, "ltx-2-mlx 700x500 width")
        t.checkEqual(ltx2mlxAligned.generation.height, 512, "ltx-2-mlx 700x500 height")
        t.checkEqual(ltx2mlxAligned.alignmentMultiple, 32, "ltx-2-mlx alignment multiple strictly 32")
        t.checkEqual(ltx2mlxAligned.crop?.left, 2, "ltx-2-mlx crop left 2")
        t.checkEqual(ltx2mlxAligned.crop?.right, 2, "ltx-2-mlx crop right 2")
        t.checkEqual(ltx2mlxAligned.crop?.top, 6, "ltx-2-mlx crop top 6")
        t.checkEqual(ltx2mlxAligned.crop?.bottom, 6, "ltx-2-mlx crop bottom 6")

        // 7. Fail-Closed Model Routing tests (nil, empty, unknown, unsupported)
        let nilModelAligned = ModelAwareResolutionAlignment.align(
            requestedWidth: 700,
            requestedHeight: 500,
            modelID: nil
        )
        t.checkEqual(nilModelAligned.generation.width, 700, "Nil model: generation width unchanged (700)")
        t.checkEqual(nilModelAligned.generation.height, 500, "Nil model: generation height unchanged (500)")
        t.check(nilModelAligned.alignmentMultiple == nil, "Nil model: alignmentMultiple is nil (NO-OP)")
        t.check(nilModelAligned.crop == nil, "Nil model: crop is nil")
        t.checkEqual(nilModelAligned.alignmentReason, .unsupported, "Nil model: reason unsupported")

        let unknownModelAligned = ModelAwareResolutionAlignment.align(
            requestedWidth: 700,
            requestedHeight: 500,
            modelID: "completely_unknown_xyz"
        )
        t.checkEqual(unknownModelAligned.generation.width, 700, "Unknown model: generation width unchanged")
        t.check(unknownModelAligned.alignmentMultiple == nil, "Unknown model: alignmentMultiple is nil (NO-OP)")
        t.check(unknownModelAligned.crop == nil, "Unknown model: crop is nil")
        t.checkEqual(unknownModelAligned.alignmentReason, .unsupported, "Unknown model: reason unsupported")

        let emptyModelAligned = ModelAwareResolutionAlignment.align(
            requestedWidth: 700,
            requestedHeight: 500,
            modelID: "   "
        )
        t.check(emptyModelAligned.alignmentMultiple == nil, "Empty model: alignmentMultiple is nil (NO-OP)")
        t.check(emptyModelAligned.crop == nil, "Empty model: crop is nil")

        // 8. MiniMax H3 validated presets (NO-OP / preserved)
        let h3Tier1 = ModelAwareResolutionAlignment.align(
            requestedWidth: 512,
            requestedHeight: 288,
            modelID: MiniMaxH3Configuration.modelID
        )
        t.checkEqual(h3Tier1.requested.width, 512, "H3 Tier1: requested width 512")
        t.checkEqual(h3Tier1.requested.height, 288, "H3 Tier1: requested height 288")
        t.checkEqual(h3Tier1.generation.width, 512, "H3 Tier1: generation width 512")
        t.checkEqual(h3Tier1.generation.height, 288, "H3 Tier1: generation height 288")
        t.checkEqual(h3Tier1.finalOutput.width, 512, "H3 Tier1: final width 512")
        t.checkEqual(h3Tier1.finalOutput.height, 288, "H3 Tier1: final height 288")
        t.check(h3Tier1.crop == nil, "H3 Tier1: crop is nil")
        t.checkEqual(h3Tier1.alignmentReason, .validatedPreset, "H3 Tier1: reason validatedPreset")

        let h3Tier2 = ModelAwareResolutionAlignment.align(
            requestedWidth: 640,
            requestedHeight: 384,
            modelID: MiniMaxH3Configuration.modelID
        )
        t.checkEqual(h3Tier2.generation.width, 640, "H3 Tier2: generation width 640")
        t.checkEqual(h3Tier2.generation.height, 384, "H3 Tier2: generation height 384")
        t.check(h3Tier2.crop == nil, "H3 Tier2: crop is nil")
        t.checkEqual(h3Tier2.alignmentReason, .validatedPreset, "H3 Tier2: reason validatedPreset")

        // 9. Backward compatibility JSON decoding test for Take and GenerationResult
        var sampleTake = Take(
            shotID: UUID(),
            modelID: "ltx23_distilled_q4",
            seed: 42,
            promptSnapshot: "A woman walks in the park",
            settingsSnapshot: GenerationParameters.preview,
            requestedWidth: 512,
            requestedHeight: 320,
            fps: 24,
            requestedDuration: 2.0
        )
        sampleTake.status = .completed
        let encodedData = try? JSONEncoder().encode(sampleTake)
        let decodedTake = encodedData != nil ? try? JSONDecoder().decode(Take.self, from: encodedData!) : nil
        t.check(decodedTake != nil, "Legacy Take JSON decodes successfully")
        t.check(decodedTake?.finalWidth == nil, "Legacy Take finalWidth is nil (optional)")
        t.check(decodedTake?.cropTop == nil, "Legacy Take cropTop is nil (optional)")
        t.check(decodedTake?.alignmentApplied == nil, "Legacy Take alignmentApplied is nil (optional)")
    }
}
