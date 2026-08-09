import Foundation
@testable import LTXVideoGeneratorCore

func runPhase5Evaluation(_ t: TestKit) {
    t.suite("CharacterBible Phase 5 — Starting Image Real Generation & Evaluation") {
        let store = FilmProjectStore.shared
        let projectID = UUID(uuidString: "07FA8292-0C89-4545-9D27-F1F64942C108")!
        guard var project = store.project(id: projectID) else {
            t.check(false, "Acceptance project 07FA8292-0C89-4545-9D27-F1F64942C108 not found in store")
            return
        }

        // Ensure pythonPath is configured in UserDefaults
        if (UserDefaults.standard.string(forKey: "pythonPath") ?? "").isEmpty {
            let venvPython = "/Users/azimnb/ltx-venv/bin/python3"
            if FileManager.default.isExecutableFile(atPath: venvPython) {
                UserDefaults.standard.set(venvPython, forKey: "pythonPath")
            }
        }

        let shotID = UUID(uuidString: "1C5DDE5B-1822-4CD7-87C1-4894EC05BA80")!
        let mayaCharacterID = UUID(uuidString: "7F76DC58-1349-40F4-9D1F-B29352D83605")!
        let frontAssetID = UUID(uuidString: "8962D90A-0D53-45AC-A0AC-092979F2F55A")!
        let faceAssetID = UUID(uuidString: "BDEB1F6C-98E4-4ECB-B132-6A9114F53F8B")!

        // Verify project structure
        t.check(project.characterBible.character(id: mayaCharacterID) != nil, "Maya character exists in project")
        let frontResolved = project.findReferenceAsset(id: frontAssetID)
        let faceResolved = project.findReferenceAsset(id: faceAssetID)
        t.check(frontResolved != nil, "Front reference asset resolved in project")
        t.check(faceResolved != nil, "Face reference asset resolved in project")

        let frontURL = project.managedReferenceAssetURL(for: frontAssetID, store: store)
        let faceURL = project.managedReferenceAssetURL(for: faceAssetID, store: store)
        t.check(frontURL != nil, "Front asset URL resolved")
        t.check(faceURL != nil, "Face asset URL resolved")
        t.check(FileManager.default.fileExists(atPath: frontURL!.path), "Front PNG exists on disk")
        t.check(FileManager.default.fileExists(atPath: faceURL!.path), "Face PNG exists on disk")

        // Force project settings for controlled comparison
        project.settings.modelID = "ltx23_distilled_q4"
        project.settings.textEncoderID = "gemma3_12b_4bit"
        project.settings.qualityMode = "auto"
        project.settings.preset = "quickPreview"
        project.settings.audioEnabled = false
        store.save(project)

        let coordinator = TakeGenerationCoordinator(store: store)
        let fixedSeed = 42

        struct ExperimentCondition {
            let label: String
            let startingImageAssetID: UUID?
            let expectedSourcePath: String?
        }

        let conditions: [ExperimentCondition] = [
            ExperimentCondition(label: "Condition A (None)", startingImageAssetID: nil, expectedSourcePath: nil),
            ExperimentCondition(label: "Condition B (Front)", startingImageAssetID: frontAssetID, expectedSourcePath: frontURL?.path),
            ExperimentCondition(label: "Condition C (Face)", startingImageAssetID: faceAssetID, expectedSourcePath: faceURL?.path)
        ]

        let evalOutputDir = URL(fileURLWithPath: "/tmp/phase5_eval", isDirectory: true)
        try? FileManager.default.createDirectory(at: evalOutputDir, withIntermediateDirectories: true)

        let dispatchGroup = DispatchGroup()

        for condition in conditions {
            print("\n--- Running Phase 5 Controlled Generation: \(condition.label) ---")
            guard var currentProject = store.project(id: projectID) else {
                t.check(false, "Project not found before running \(condition.label)")
                return
            }

            currentProject.setStartingImageAsset(condition.startingImageAssetID, forShot: shotID)
            store.save(currentProject)

            let requests: [GenerationRequest]
            do {
                requests = try coordinator.planTakes(
                    projectID: projectID,
                    shotID: shotID,
                    count: 1,
                    baseSeed: fixedSeed
                )
            } catch {
                t.check(false, "planTakes failed for \(condition.label): \(error)")
                continue
            }

            t.checkEqual(requests.count, 1, "\(condition.label) created 1 request")
            let request = requests[0]
            t.checkEqual(request.sourceImagePath, condition.expectedSourcePath, "\(condition.label) request.sourceImagePath matches expectation")

            let outputMP4 = evalOutputDir.appendingPathComponent("\(condition.label.replacingOccurrences(of: " ", with: "_")).mp4").path
            try? FileManager.default.removeItem(atPath: outputMP4)

            dispatchGroup.enter()
            var genError: Error? = nil
            var genResult: (videoPath: String, seed: Int, enhancedPrompt: String?)? = nil

            let bridge = LTXBridge.shared
            Task {
                do {
                    genResult = try await bridge.generate(request: request, outputPath: outputMP4) { progress, status in
                        // print("   [\(condition.label)] \(Int(progress * 100))% - \(status)")
                    }
                } catch {
                    genError = error
                }
                dispatchGroup.leave()
            }
            dispatchGroup.wait()

            if let genError {
                t.check(false, "Generation failed for \(condition.label): \(genError)")
                continue
            }

            guard let genResult, FileManager.default.fileExists(atPath: genResult.videoPath) else {
                t.check(false, "Video output missing for \(condition.label)")
                continue
            }

            t.check(FileManager.default.fileExists(atPath: genResult.videoPath), "\(condition.label) produced valid video MP4")
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: genResult.videoPath)[.size] as? Int64) ?? 0
            print("   SUCCESS \(condition.label): \(genResult.videoPath) (\(fileSize) bytes, seed \(genResult.seed))")

            // Extract frames (beginning, middle, end) via ffmpeg
            let frameDir = evalOutputDir.appendingPathComponent(condition.label.replacingOccurrences(of: " ", with: "_"), isDirectory: true)
            try? FileManager.default.createDirectory(at: frameDir, withIntermediateDirectories: true)

            let frame0 = frameDir.appendingPathComponent("frame_start.jpg").path
            let frameMid = frameDir.appendingPathComponent("frame_mid.jpg").path
            let frameEnd = frameDir.appendingPathComponent("frame_end.jpg").path

            // Extract frame 1 (0s)
            let p1 = Process()
            p1.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p1.arguments = ["ffmpeg", "-y", "-ss", "0.0", "-i", genResult.videoPath, "-vframes", "1", frame0]
            try? p1.run()
            p1.waitUntilExit()

            // Extract middle frame (1.0s)
            let p2 = Process()
            p2.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p2.arguments = ["ffmpeg", "-y", "-ss", "1.0", "-i", genResult.videoPath, "-vframes", "1", frameMid]
            try? p2.run()
            p2.waitUntilExit()

            // Extract end frame (1.8s)
            let p3 = Process()
            p3.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p3.arguments = ["ffmpeg", "-y", "-ss", "1.8", "-i", genResult.videoPath, "-vframes", "1", frameEnd]
            try? p3.run()
            p3.waitUntilExit()

            t.check(FileManager.default.fileExists(atPath: frame0), "\(condition.label) extracted start frame")
            t.check(FileManager.default.fileExists(atPath: frameMid), "\(condition.label) extracted mid frame")
            t.check(FileManager.default.fileExists(atPath: frameEnd), "\(condition.label) extracted end frame")
        }
    }
}
