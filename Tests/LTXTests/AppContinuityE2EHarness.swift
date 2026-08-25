import Foundation
@testable import LTXVideoGeneratorCore

enum AppContinuityE2EHarness {

    @MainActor
    static func runRealAppContinuityE2E() async -> Int32 {
        print("=== STARTING ACTUAL APP CONTINUITY E2E TEST ===")
        print("Model: LTX 2.3 Distilled Q4 (\(LTXModelCatalog.defaultModelID))")
        print("Requested Dimensions: 512x300")
        print("Expected Generation Canvas: 512x320")
        print("Expected Final Output: 512x300")

        let env = V3AcceptanceHarness.makeEnvironment(label: "app-continuity-e2e")
        defer { V3AcceptanceHarness.restoreOutputDir(env) }

        // Create 2-shot Auto Movie project with Director OFF and Custom resolution (512x300)
        var project = FilmProject(title: "App Continuity E2E 512x300")
        project.workflowMode = AutoMovieRunCoordinator.autoMovieWorkflowMode
        project.continuityChainEnabled = true
        project.directorProvider = "Direct"
        project.planningMode = "Direct (No Director)"
        project.settings = ProjectSettings(
            modelID: LTXModelCatalog.defaultModelID,
            textEncoderID: "gemma3_12b_4bit",
            qualityMode: QualityMode.advanced.rawValue,
            preset: "custom",
            width: 512,
            height: 300,
            fps: 24,
            numFrames: 17,
            numInferenceSteps: 8,
            audioEnabled: false,
            targetDurationSeconds: 1.4
        )

        var shot1 = Shot(index: 0, title: "Shot 1", summary: "A lone explorer stands on a red Martian dune.")
        shot1.compiledPrompt = "A cinematic wide shot of a lone explorer in spacesuit on a red Martian dune, sharp details, dramatic sunset"
        shot1.continuityMode = .cut
        shot1.durationSeconds = 0.7

        var shot2 = Shot(index: 1, title: "Shot 2", summary: "The explorer raises a beacon towards the sky.")
        shot2.compiledPrompt = "The explorer raises a glowing beacon towards the starry Martian sky, continuous motion"
        shot2.continuityMode = .continueFromPrevious
        shot2.durationSeconds = 0.7

        project.shots = [shot1, shot2]
        env.store.save(project)

        // Generate Shot 1
        print("\n--- Generating Shot 1 (CUT) ---")
        let (shot1Path, _) = await V3AcceptanceHarness.generateNextShot(
            env: env, projectID: project.id, label: "Shot 1"
        )
        guard let shot1Path, FileManager.default.fileExists(atPath: shot1Path) else {
            print("ERROR: Shot 1 generation failed")
            return 1
        }

        let shot1Probe = MediaProbe.probe(path: shot1Path)
        print("SHOT1_REQUESTED_RESOLUTION: 512x300")
        print("SHOT1_GENERATION_RESOLUTION: \(shot1Probe?.width ?? 0)x\(shot1Probe?.height ?? 0)")
        print("SHOT1_INTERNAL_OUTPUT_RESOLUTION: \(shot1Probe?.width ?? 0)x\(shot1Probe?.height ?? 0)")
        print("SHOT1_INTERNAL_PATH: \(shot1Path)")

        // Generate Shot 2 via V3AcceptanceHarness.generateNextShot
        print("\n--- Generating Shot 2 (CONTINUE) ---")
        let (shot2Path, _) = await V3AcceptanceHarness.generateNextShot(
            env: env, projectID: project.id, label: "Shot 2"
        )
        guard let shot2Path, FileManager.default.fileExists(atPath: shot2Path) else {
            print("ERROR: Shot 2 generation failed")
            return 1
        }

        let shot2Probe = MediaProbe.probe(path: shot2Path)
        print("SHOT2_GENERATION_RESOLUTION: \(shot2Probe?.width ?? 0)x\(shot2Probe?.height ?? 0)")
        print("SHOT2_INTERNAL_PATH: \(shot2Path)")

        // Verify continuity source frame path and resolution
        project = env.store.project(id: project.id)!
        let shot2State = project.shots[1]
        let continuityRelativePath = shot2State.continuityImageRelativePath
        var continuityURL: URL? = nil
        if let rel = continuityRelativePath {
            continuityURL = env.store.managedProjectAssetURL(projectID: project.id, relativePath: rel)
        }
        let continuityPath = continuityURL?.path ?? ""
        let cInfo = FileManager.default.fileExists(atPath: continuityPath) ? MediaProbe.probe(path: continuityPath) : nil
        print("\n--- Continuity Source Frame Verification ---")
        print("SHOT1_CONTINUE_SOURCE_PATH: \(continuityPath)")
        print("SHOT1_CONTINUE_SOURCE_RESOLUTION: \(cInfo?.width ?? 0)x\(cInfo?.height ?? 0)")

        // Ensure selectedTakeID is set for each shot prior to assembly
        for i in project.shots.indices {
            if project.shots[i].selectedTakeID == nil, let firstTake = project.shots[i].takes.first {
                project.shots[i].selectedTakeID = firstTake.id
            }
        }
        env.store.save(project)

        // Run Final Assembly
        print("\n--- Running Final Assembly ---")
        let finalMovieURL = env.tmpDir.appendingPathComponent("final_movie.mp4")
        do {
            let assembledInfo = try FinalAssemblyService.assemble(
                project: project,
                outputPath: finalMovieURL.path,
                store: env.store,
                storageChecker: StorageHealthService.shared
            )
            print("Assembly Succeeded!")
            print("FINAL_OUTPUT_PATH: \(finalMovieURL.path)")
            print("FINAL_OUTPUT_RESOLUTION: \(assembledInfo.width ?? 0)x\(assembledInfo.height ?? 0)")
            print("FINAL_MOVIE_FPS: \(assembledInfo.fps ?? 0)")
            print("FINAL_MOVIE_DURATION: \(assembledInfo.durationSeconds ?? 0)s")
        } catch {
            print("Assembly Failed: \(error)")
            return 1
        }

        // Output machine-readable JSON for metric calculation
        let summary: [String: Any] = [
            "shot1_requested": "512x300",
            "shot1_generation": "\(shot1Probe?.width ?? 0)x\(shot1Probe?.height ?? 0)",
            "shot1_internal_path": shot1Path,
            "shot2_requested": "512x300",
            "shot2_generation": "\(shot2Probe?.width ?? 0)x\(shot2Probe?.height ?? 0)",
            "shot2_internal_path": shot2Path,
            "continuity_image_path": continuityPath,
            "continuity_resolution": "\(cInfo?.width ?? 0)x\(cInfo?.height ?? 0)",
            "final_movie_path": finalMovieURL.path
        ]
        let summaryPath = "/tmp/app_e2e_summary.json"
        if let summaryData = try? JSONSerialization.data(withJSONObject: summary, options: .prettyPrinted) {
            try? summaryData.write(to: URL(fileURLWithPath: summaryPath))
        }
        print("\nE2E Run Summary written to \(summaryPath)")
        return 0
    }
}
