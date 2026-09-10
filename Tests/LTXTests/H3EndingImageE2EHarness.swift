import Foundation
@testable import LTXVideoGeneratorCore

/// Phase V — bounded end-to-end for the experimental Ending Image, driven
/// through the PRODUCTION path (GenerationService → ModelRegistry →
/// AdapterRegistry → MiniMaxH3Adapter → MiniMaxH3Backend), with isolated
/// store/history/output directories so no Dev or Personal project is touched.
///
///   swift run LTXTests --h3-ending-image-e2e <first.png> <last.png>
enum H3EndingImageE2EHarness {

    @MainActor
    static func run(firstPath: String, lastPath: String) async -> Int32 {
        print("H3 ENDING IMAGE — production-path E2E")
        print("started: \(ISO8601DateFormatter().string(from: Date()))")

        guard FileManager.default.isReadableFile(atPath: firstPath),
              FileManager.default.isReadableFile(atPath: lastPath) else {
            print("FAILED: keyframe images unreadable"); return 2
        }
        let modelID = MiniMaxH3Configuration.standardModelID
        guard H3EndingImageCapability.supportsEndingImage(modelID: modelID) else {
            print("FAILED: model \(modelID) is not on the verified allow-list"); return 2
        }
        let endingHash = H3EndingImageCapability.contentHash(ofFileAt: lastPath)
        print("model: \(modelID)")
        print("first: \(firstPath)")
        print("last : \(lastPath)  hash=\(endingHash?.prefix(16) ?? "nil")")

        let env = V3AcceptanceHarness.makeEnvironment(label: "h3-ending-image")
        defer { V3AcceptanceHarness.restoreOutputDir(env) }

        var parameters = GenerationParameters.default
        parameters.width = 512
        parameters.height = 288
        parameters.fps = 24
        parameters.numFrames = 56
        parameters.numInferenceSteps = 16
        parameters.seed = 4242

        let request = GenerationRequest(
            prompt: "The scene transitions naturally from the first frame to the last frame.",
            sourceImagePath: firstPath,
            endingImagePath: lastPath,
            endingImageContentHash: endingHash,
            disableAudio: true,
            modelId: modelID,
            parameters: parameters,
            qualityMode: GenerationPreset.custom.qualityMode.rawValue,
            preset: MiniMaxH3Preset.custom.rawValue,
            targetDurationSeconds: 56.0 / 24.0,
            generationSource: "oneShot",
            minimaxH3ModelDirectory: UserDefaults(suiteName: "com.localvideostudio.dev")?
                .string(forKey: "minimaxH3ModelDirectory"),
            minimaxH3Endpoint: "http://127.0.0.1:11236",
            minimaxH3RequestedDurationSeconds: 56.0 / 24.0)

        print("PRODUCTION_PATH=GenerationService->ModelRegistry->AdapterRegistry->MiniMaxH3Adapter->MiniMaxH3Backend")
        print("REQUEST_ID=\(request.id.uuidString)")
        print("hasEndingImage=\(request.hasEndingImage)")

        let started = Date()
        env.generationService.addToQueue(request)
        while Date().timeIntervalSince(started) < 3_600 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if !env.generationService.isProcessing, env.generationService.queue.isEmpty { break }
        }
        let elapsed = Date().timeIntervalSince(started)

        guard let result = env.historyManager.results.first(where: { $0.requestId == request.id })
        else {
            print("FAILED: no GenerationResult; error=\(String(describing: env.generationService.error))")
            return 1
        }
        print(String(format: "GENERATION_ELAPSED=%.1fs", elapsed))
        print("HISTORY=PASS (result recorded for the request)")

        let path = result.videoPath
        guard FileManager.default.fileExists(atPath: path) else {
            print("FAILED: output file missing at \(path)"); return 1
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        print("OUTPUT_FILE=PASS \(path) (\(size ?? 0) bytes)")

        // Reopen History from disk: the One Shot result must survive persistence.
        let reopened = HistoryManager(rootDirectory: env.tmpDir.appendingPathComponent("History"))
        reopened.loadInitialData()
        let persisted = reopened.results.contains { $0.requestId == request.id }
        print("HISTORY_REOPEN=\(persisted ? "PASS" : "FAIL")")
        print("TAKE=\(request.takeID == nil ? "NOT_APPLICABLE (One Shot path creates no Take)" : "present")")
        print("EVIDENCE_DIR=\(env.tmpDir.path)")
        print("finished: \(ISO8601DateFormatter().string(from: Date()))")
        return persisted ? 0 : 1
    }
}
