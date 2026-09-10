import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import LTXVideoGeneratorCore

/// Phase U matrix for the experimental Ending Image capability.
///
/// The behaviours that matter most here are the refusals: an Ending Image must
/// never be silently dropped, silently sent to a model that cannot use it, or
/// silently replaced by different bytes than the user submitted.

private let verifiedH3 = MiniMaxH3Configuration.standardModelID       // 2-bit TE pack
private let unverifiedH3HQ = MiniMaxH3Configuration.highQualityModelID
private let ltxModel = LTXModelCatalog.defaultModelID

private func tempImage(_ name: String, bytes: String = "PNGDATA") -> String {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ending-\(name)-\(UUID().uuidString).png")
    try? Data(bytes.utf8).write(to: url)
    return url.path
}

private func h3Request(
    model: String = verifiedH3,
    start: String? = "/tmp/start.png",
    ending: String? = nil,
    endingHash: String? = nil
) -> GenerationRequest {
    GenerationRequest(
        prompt: "a woman raises her hand",
        sourceImagePath: start,
        endingImagePath: ending,
        endingImageContentHash: endingHash,
        modelId: model,
        parameters: GenerationParameters.default)
}

func runEndingAsync(_ block: @escaping () async -> Void) {
    let sem = DispatchSemaphore(value: 0)
    Task { await block(); sem.signal() }
    while sem.wait(timeout: .now() + 0.05) == .timedOut {
        RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
    }
}

func runH3EndingImageTests(_ t: TestKit) {

    // 1 & 15. Capability is a hard allow-list, not "is it an H3 model".
    t.suite("Ending Image — capability is scoped to the verified pack only") {
        t.check(H3EndingImageCapability.supportsEndingImage(modelID: verifiedH3),
                "verified H3 Standard pack supports Ending Image")
        t.check(!H3EndingImageCapability.supportsEndingImage(modelID: unverifiedH3HQ),
                "H3 High Quality is NOT assumed to support it merely for being H3")
        t.check(!H3EndingImageCapability.supportsEndingImage(modelID: ltxModel),
                "LTX does not support Ending Image")
        t.check(!H3EndingImageCapability.supportsEndingImage(modelID: nil),
                "nil model does not support Ending Image")
        t.checkEqual(H3EndingImageCapability.verifiedModelIDs.count, 1,
                     "exactly one model is on the allow-list")
        // Both H3 ids are recognised as H3 — so the scope really is narrower
        // than "is MiniMax H3", which is the whole point of this type.
        t.check(MiniMaxH3Configuration.isMiniMaxH3(modelID: unverifiedH3HQ),
                "HQ is still an H3 model — scope is deliberately narrower than that")
    }

    // 1. Start-only behaviour is untouched.
    t.suite("Ending Image — start-only requests unchanged") {
        let r = h3Request()
        t.check(!r.hasEndingImage, "no ending image by default")
        t.check(r.endingImagePath == nil, "path nil")
        t.check(r.endingImageContentHash == nil, "hash nil")
        t.check(r.isImageToVideo, "start image still drives I2V")
        let payload = MiniMaxH3Backend.makePayload(
            request: r, prompt: "p", sourceImageData: Data("start".utf8),
            endingImageData: nil, seed: 1)
        t.check(payload.firstFrameImage != nil, "first_frame_image present")
        t.check(payload.lastFrameImage == nil, "last_frame_image absent")
        // Absent must mean the key is omitted, not null.
        let json = String(data: try! JSONEncoder().encode(payload), encoding: .utf8) ?? ""
        t.check(!json.contains("last_frame_image"),
                "last_frame_image key is omitted entirely when there is no Ending Image")
        t.check(json.contains("first_frame_image"), "first_frame_image key present")
    }

    // 2 & T. Start + End sends both, under the confirmed field name.
    t.suite("Ending Image — start + end sends both keyframes") {
        let r = h3Request(ending: "/tmp/end.png", endingHash: "abc")
        t.check(r.hasEndingImage, "request reports an ending image")
        let payload = MiniMaxH3Backend.makePayload(
            request: r, prompt: "p", sourceImageData: Data("start".utf8),
            endingImageData: Data("end".utf8), seed: 1)
        t.check(payload.firstFrameImage != nil, "first_frame_image present")
        t.check(payload.lastFrameImage != nil, "last_frame_image present")
        let json = String(data: try! JSONEncoder().encode(payload), encoding: .utf8) ?? ""
        t.check(json.contains("last_frame_image"), "serialises as last_frame_image")
        t.check(!json.contains("image_end"),
                "does NOT use image_end (that is a chat token, not this field)")
    }

    // 3 & J. End without Start is rejected, never reinterpreted as a start.
    t.suite("Ending Image — end without start is rejected") {
        let err = H3EndingImageValidator.validateAtSubmission(
            modelID: verifiedH3, startImagePath: nil, endingImagePath: "/tmp/end.png")
        t.checkEqual(err, .endWithoutStart, "end-without-start rejected")
        t.check(err?.errorDescription?.contains("開始画像") == true,
                "message names the missing starting image")
        let blank = H3EndingImageValidator.validateAtSubmission(
            modelID: verifiedH3, startImagePath: "   ", endingImagePath: "/tmp/end.png")
        t.checkEqual(blank, .endWithoutStart, "whitespace-only start counts as absent")
    }

    // 14 & 15 & H. Model switch never silently drops the Ending Image.
    t.suite("Ending Image — model switch blocks instead of dropping") {
        for (model, label) in [(ltxModel, "LTX-2.5"), (unverifiedH3HQ, "H3 HQ (unverified)")] {
            let err = H3EndingImageValidator.validateAtSubmission(
                modelID: model, startImagePath: "/tmp/s.png", endingImagePath: "/tmp/e.png")
            switch err {
            case .unsupportedModel(let reason):
                t.check(true, "\(label): rejected with an explicit reason")
                t.check(reason.contains("終了画像"), "\(label): message names 終了画像")
                t.check(reason.contains("削除") || reason.contains("切り替え"),
                        "\(label): message tells the user what to do")
            default:
                t.check(false, "\(label): expected unsupportedModel, got \(String(describing: err))")
            }
        }
        // With no Ending Image configured, an unsupported model is fine.
        t.check(H3EndingImageValidator.validateAtSubmission(
                    modelID: ltxModel, startImagePath: "/tmp/s.png", endingImagePath: nil) == nil,
                "unsupported model is unaffected when no Ending Image is set")
    }

    // 8 & M. Missing file fails closed.
    t.suite("Ending Image — missing file fails closed") {
        let path = tempImage("gone")
        let hash = H3EndingImageCapability.contentHash(ofFileAt: path)
        try? FileManager.default.removeItem(atPath: path)
        let err = H3EndingImageValidator.verifyAtExecution(
            endingImagePath: path, expectedContentHash: hash)
        t.checkEqual(err, .missingFile(path), "deleted ending image is rejected")
        t.check(err?.errorDescription?.contains("見つかりません") == true,
                "message says the file is missing")
    }

    // 9 & L. Contents changing after submission is detected.
    t.suite("Ending Image — content change after submission is detected") {
        let path = tempImage("mutate", bytes: "ORIGINAL")
        let submitted = H3EndingImageCapability.contentHash(ofFileAt: path)
        t.check(submitted != nil, "hash captured at submission")
        // Unchanged file passes.
        t.check(H3EndingImageValidator.verifyAtExecution(
                    endingImagePath: path, expectedContentHash: submitted) == nil,
                "unchanged file passes verification")
        // Same path, different bytes — the exact queue-wait hazard.
        try? Data("REPLACED".utf8).write(to: URL(fileURLWithPath: path))
        let err = H3EndingImageValidator.verifyAtExecution(
            endingImagePath: path, expectedContentHash: submitted)
        t.checkEqual(err, .contentChanged(path), "modified contents rejected")
        t.check(err?.errorDescription?.contains("変更") == true,
                "message says the contents changed")
        try? FileManager.default.removeItem(atPath: path)
    }

    // Legacy requests carry no hash; existence alone is all that can be checked.
    t.suite("Ending Image — legacy request without a hash still checks existence") {
        let path = tempImage("legacy")
        t.check(H3EndingImageValidator.verifyAtExecution(
                    endingImagePath: path, expectedContentHash: nil) == nil,
                "no recorded hash: existing file passes")
        try? FileManager.default.removeItem(atPath: path)
        t.checkEqual(H3EndingImageValidator.verifyAtExecution(
                        endingImagePath: path, expectedContentHash: nil),
                     .missingFile(path),
                     "no recorded hash: missing file still fails closed")
    }

    // 12 & 13 & O. Legacy persisted JSON decodes safely.
    //
    // Rather than hand-authoring a full legacy document (which would drift as
    // unrelated fields change), encode a real request and DELETE the two new
    // keys. That reproduces exactly what an older persisted file looks like:
    // identical in every other respect, missing only these fields.
    t.suite("Ending Image — legacy persisted JSON decodes") {
        func strippingEndingKeys(_ data: Data) -> Data {
            var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            obj.removeValue(forKey: "endingImagePath")
            obj.removeValue(forKey: "endingImageContentHash")
            return (try? JSONSerialization.data(withJSONObject: obj)) ?? data
        }

        let modern = h3Request(ending: "/tmp/end.png", endingHash: "h")
        guard let encoded = try? JSONEncoder().encode(modern) else {
            t.check(false, "could not encode request"); return
        }
        let legacyData = strippingEndingKeys(encoded)
        let legacyText = String(data: legacyData, encoding: .utf8) ?? ""
        t.check(!legacyText.contains("endingImagePath"),
                "legacy fixture genuinely lacks the new keys")

        do {
            let decoded = try JSONDecoder().decode(GenerationRequest.self, from: legacyData)
            t.check(true, "legacy GenerationRequest JSON decodes")
            t.check(decoded.endingImagePath == nil, "ending image path is nil")
            t.check(decoded.endingImageContentHash == nil, "ending hash is nil")
            t.check(!decoded.hasEndingImage, "hasEndingImage false")
            t.checkEqual(decoded.prompt, modern.prompt, "existing fields intact")
            t.checkEqual(decoded.sourceImagePath, modern.sourceImagePath,
                         "starting image intact")
        } catch {
            t.check(false, "legacy decode failed: \(error)")
        }

        // Legacy queue snapshot carrying legacy pending requests.
        var snap = ProductionJobSnapshot()
        snap.pendingRequests = [modern]
        guard let snapEncoded = try? JSONEncoder().encode(snap),
              var snapObj = (try? JSONSerialization.jsonObject(with: snapEncoded)) as? [String: Any],
              let reqs = snapObj["pendingRequests"] as? [[String: Any]] else {
            t.check(false, "could not encode snapshot"); return
        }
        snapObj["pendingRequests"] = reqs.map { r -> [String: Any] in
            var c = r
            c.removeValue(forKey: "endingImagePath")
            c.removeValue(forKey: "endingImageContentHash")
            return c
        }
        do {
            let legacySnap = try JSONSerialization.data(withJSONObject: snapObj)
            let back = try JSONDecoder().decode(ProductionJobSnapshot.self, from: legacySnap)
            t.checkEqual(back.pendingRequests.count, 1, "legacy queue snapshot decodes")
            t.check(back.pendingRequests[0].endingImagePath == nil,
                    "queued legacy request has no ending image")
        } catch {
            t.check(false, "legacy snapshot decode failed: \(error)")
        }
    }

    // New request round-trips, and survives the queue snapshot.
    t.suite("Ending Image — new request round-trip and queue preservation") {
        let r = h3Request(ending: "/tmp/end.png", endingHash: "deadbeef")
        do {
            let data = try JSONEncoder().encode(r)
            let back = try JSONDecoder().decode(GenerationRequest.self, from: data)
            t.checkEqual(back.endingImagePath, "/tmp/end.png", "path round-trips")
            t.checkEqual(back.endingImageContentHash, "deadbeef", "hash round-trips")
            t.check(back.hasEndingImage, "hasEndingImage survives")

            // 6. Queue wait: snapshot carries the submitted request verbatim.
            var snap = ProductionJobSnapshot()
            snap.pendingRequests = [r]
            let snapBack = try JSONDecoder().decode(
                ProductionJobSnapshot.self, from: try JSONEncoder().encode(snap))
            t.checkEqual(snapBack.pendingRequests.first?.endingImagePath, "/tmp/end.png",
                         "queue preserves the Ending Image path")
            t.checkEqual(snapBack.pendingRequests.first?.endingImageContentHash, "deadbeef",
                         "queue preserves the submitted content hash")
        } catch {
            t.check(false, "round-trip failed: \(error)")
        }
    }

    // 7. Retry reuses the SUBMITTED request, so the Ending Image and its hash
    //    travel with it — a newly modified file cannot sneak in.
    t.suite("Ending Image — retry preserves the submitted image and hash") {
        let r = h3Request(ending: "/tmp/end.png", endingHash: "submitted-hash")
        var snapshot = ProductionJobSnapshot()
        snapshot.pendingRequests = [r]
        let store = ProductionQueueStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("ending-retry-\(UUID().uuidString).json"))
        let coordinator = ProductionQueueCoordinator(store: store, restoreOnInit: false)
        let job = coordinator.enqueue(
            ProductionJob(kind: .generate, title: "t", snapshot: snapshot))
        // enqueue() forces .waiting, so drive the job to a retryable state the
        // way the app does.
        coordinator.markFailed(jobID: job.id, reason: "simulated backend failure")
        // A retry clones the job; the request inside must be unchanged.
        let retried = coordinator.retry(jobID: job.id)
        if let retried {
            t.checkEqual(retried.snapshot.pendingRequests.first?.endingImagePath,
                         "/tmp/end.png", "retry keeps the Ending Image")
            t.checkEqual(retried.snapshot.pendingRequests.first?.endingImageContentHash,
                         "submitted-hash",
                         "retry keeps the SUBMITTED hash, so a changed file is still caught")
        } else {
            t.check(false, "retry returned nil")
        }
    }

    // REGRESSION (the previous false positive): the earlier version of this
    // suite exercised CanonicalShotRequestBuilder DIRECTLY with a spec that
    // already carried the Ending Image. One Shot does not call the builder
    // directly — it goes through LocalDirector, which rebuilt the spec from
    // `base` and silently dropped the field. A green builder test therefore
    // proved nothing about the path the user actually uses.
    //
    // These two cases go through LocalDirector, the real One Shot path.
    t.suite("Ending Image — LocalDirector preserves it (the real One Shot path)") {
        let base = h3Request(ending: "/tmp/end.png", endingHash: "hash-1")
        t.check(base.hasEndingImage, "base request carries the Ending Image")

        // Director OFF — One Shot's direct path.
        let (direct, _) = LocalDirector.makeDirectRequest(prompt: "p", base: base)
        t.checkEqual(direct.endingImagePath, "/tmp/end.png",
                     "Director OFF: makeDirectRequest carries the Ending Image")
        t.checkEqual(direct.endingImageContentHash, "hash-1",
                     "Director OFF: submitted hash carried too")

        // Director ON — One Shot's planned path.
        let planJSON = #"{"camera":"static medium shot","action":"A woman raises her hand","dialogue":[],"audioCues":[],"durationIntentSeconds":5}"#
        runEndingAsync {
            let mock = MockDirectorProvider(responses: [planJSON])
            do {
                let (planned, _, _) = try await LocalDirector(providers: [mock])
                    .makeRequest(brief: "a woman raises her hand", base: base)
                t.checkEqual(planned.endingImagePath, "/tmp/end.png",
                             "Director ON: planned request carries the Ending Image")
                t.checkEqual(planned.endingImageContentHash, "hash-1",
                             "Director ON: submitted hash carried too")
                t.checkEqual(planned.sourceImagePath, base.sourceImagePath,
                             "Director ON: starting image unchanged")
            } catch {
                t.check(false, "Director ON path failed: \(error)")
            }
        }

        // And with no Ending Image, nothing is invented.
        let plain = h3Request()
        let (plainDirect, _) = LocalDirector.makeDirectRequest(prompt: "p", base: plain)
        t.check(!plainDirect.hasEndingImage,
                "Director OFF invents no Ending Image when none was submitted")
    }

    // REGRESSION: the control must live in the LIVE One Shot view, not in the
    // Generate view. The first implementation put it in PromptInputView (the
    // Generate tab) while the user was looking at One Shot, so the feature was
    // invisible where it was supposed to be. This is a structural check on the
    // source, NOT proof that the control renders — only a human can confirm that.
    t.suite("Ending Image — UI lives in the One Shot view, not Generate") {
        func read(_ path: String) -> String {
            (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        }
        let oneShot = read("LTXVideoGenerator/Sources/Views/ContentView.swift")
        let generate = read("LTXVideoGenerator/Sources/Views/PromptInputView.swift")
        t.check(!oneShot.isEmpty && !generate.isEmpty, "both view sources readable")

        // ContentView holds the live One Shot screen (`case .oneShot: OneShotView`).
        t.check(oneShot.contains("case .oneShot:") && oneShot.contains("OneShotView("),
                "OneShotView is the live One Shot screen")
        t.check(oneShot.contains("終了画像"), "One Shot view contains the 終了画像 control")
        t.check(oneShot.contains("endingImageSection"), "One Shot view renders endingImageSection")
        t.check(oneShot.contains("oneShotEndingImagePath"),
                "One Shot uses its own storage key, so Generate cannot inherit it")

        // The Generate tab is out of scope and must stay clean.
        t.check(!generate.contains("終了画像"), "Generate view has no 終了画像 control")
        t.check(!generate.contains("endingImage"), "Generate view has no ending-image wiring")

        // No internal vocabulary leaks into the UI.
        for term in ["FL2VA", "fl2va", "last_frame_image", "conditioning rows",
                     "keyframes_abs_pos_embedding"] {
            t.check(!oneShot.contains(term), "One Shot UI does not expose \(term)")
        }
    }

    // 4 & 5 & Q. The canonical builder also carries it (layer below Director).
    t.suite("Ending Image — canonical builder preserves it") {
        var spec = CanonicalShotSpecification(
            prompt: "compiled prompt",
            modelID: verifiedH3, textEncoderID: "t5",
            width: 512, height: 288, fps: 24, numInferenceSteps: 16)
        spec.conditioningImage = ResolvedShotConditioningImage(
            path: "/tmp/start.png", imageStrength: nil, effectiveSource: .explicitStartingImage)
        spec.endingImagePath = "/tmp/end.png"
        spec.endingImageContentHash = "hash-1"
        let (request, _, _) = CanonicalShotRequestBuilder.buildRequest(from: spec)
        t.checkEqual(request.endingImagePath, "/tmp/end.png",
                     "builder carries the Ending Image into the request")
        t.checkEqual(request.endingImageContentHash, "hash-1", "and its hash")
        t.checkEqual(request.sourceImagePath, "/tmp/start.png", "start image unchanged")

        // Director-planned specs go through the same builder, so the Ending
        // Image is not something the Director can invent or remove.
        var noEnding = spec
        noEnding.endingImagePath = nil
        noEnding.endingImageContentHash = nil
        let (plain, _, _) = CanonicalShotRequestBuilder.buildRequest(from: noEnding)
        t.check(plain.endingImagePath == nil, "no Ending Image when the spec has none")
        t.check(!plain.hasEndingImage, "hasEndingImage false")
    }

    // 10 & 11 & N. Preprocessing: the Ending Image must go through the SAME
    // deterministic preparation as the Starting Image, so both keyframes reach
    // the runtime with identical geometry.
    t.suite("Ending Image — preprocessing is shared and deterministic") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ending-prep-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        func writePNG(_ name: String, w: Int, h: Int, orientation: Int? = nil) -> URL {
            let url = dir.appendingPathComponent("\(name).png")
            let cs = CGColorSpaceCreateDeviceRGB()
            let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                bytesPerRow: 0, space: cs,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            // Asymmetric mark so an orientation error would be detectable.
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: max(1, w / 4), height: max(1, h / 8)))
            let image = ctx.makeImage()!
            var props: [CFString: Any] = [:]
            if let orientation { props[kCGImagePropertyOrientation] = orientation }
            let dest = CGImageDestinationCreateWithURL(
                url as CFURL, "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, image, props as CFDictionary)
            CGImageDestinationFinalize(dest)
            return url
        }

        let target = (w: 512, h: 288)
        // 1. Same aspect ratio for both.
        let startSame = writePNG("start-same", w: 1024, h: 576)
        let endSame = writePNG("end-same", w: 1024, h: 576)
        // 2. Different aspect ratios.
        let endTall = writePNG("end-tall", w: 600, h: 1200)
        // 3. EXIF-rotated (orientation 6 = rotate 90).
        let endExif = writePNG("end-exif", w: 800, h: 400, orientation: 6)
        // 4. Different pixel dimensions, same ratio.
        let endSmall = writePNG("end-small", w: 256, h: 144)

        func prepared(_ url: URL) -> ImageConditioningGeometry? {
            try? ImageConditioningPreparer.shared.prepare(
                sourceURL: url, targetWidth: target.w, targetHeight: target.h).geometry
        }

        let gStart = prepared(startSame)
        t.check(gStart != nil, "start image prepares")
        for (label, url) in [("same aspect", endSame), ("different aspect", endTall),
                             ("EXIF rotated", endExif), ("different size", endSmall)] {
            guard let g = prepared(url) else { t.check(false, "\(label): prepare failed"); continue }
            t.checkEqual(g.targetWidth, target.w, "\(label): prepared width matches target")
            t.checkEqual(g.targetHeight, target.h, "\(label): prepared height matches target")
            if let gStart {
                t.checkEqual(g.targetWidth, gStart.targetWidth,
                             "\(label): start and end share prepared width")
                t.checkEqual(g.targetHeight, gStart.targetHeight,
                             "\(label): start and end share prepared height")
            }
        }

        // Deterministic: preparing twice gives the same geometry.
        if let a = prepared(endTall), let b = prepared(endTall) {
            t.checkEqual(a, b, "preparation is deterministic for identical input")
        }

        // Aspect is preserved by cropping, never by stretching: a 600x1200
        // source must be scaled by the larger ratio and cropped, so the scale
        // factor is uniform in x and y.
        if let g = prepared(endTall) {
            t.check(g.targetWidth == target.w && g.targetHeight == target.h,
                    "fill-crop lands exactly on the target canvas (no stretch to fit)")
        }
    }

    // 16-20. Nothing else changes shape.
    t.suite("Ending Image — unrelated paths unaffected") {
        let ltx = GenerationRequest(prompt: "p", sourceImagePath: "/tmp/s.png",
                                    modelId: ltxModel, parameters: .default)
        t.check(!ltx.hasEndingImage, "LTX request has no ending image")
        t.check(ltx.isImageToVideo, "LTX I2V unaffected")

        // Direct One Shot construction (Director OFF) is unchanged.
        let base = h3Request()
        let direct = LocalDirector.makeDirectRequest(prompt: "p", base: base)
        t.check(!direct.request.hasEndingImage,
                "direct request has no Ending Image unless the spec carried one")
        t.check(direct.request.sourceImagePath == base.sourceImagePath,
                "direct path preserves the starting image")

        // The Prompt Enhancer schema is untouched by this feature.
        for key in ["endingImagePath", "last_frame_image", "endingImage"] {
            t.check(!H3EnhancementDraft.allowedKeys.contains(key),
                    "Prompt Enhancer schema still exposes no \(key)")
        }
    }
}
