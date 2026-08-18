import Foundation
@testable import LTXVideoGeneratorCore

/// Deterministic, no-network coverage for the Qwen/family-recognition layer
/// added for the Qwen Director MVP. None of these tests talk to Ollama —
/// they only exercise pure string matching and Codable round-trips.
func runDirectorModelProfileTests(_ t: TestKit) {
    t.suite("DirectorModelFamily recognizes installed model tags by family, not exact version") {
        t.checkEqual(DirectorModelFamily.detect(modelIdentifier: "qwen3.6-claw-fast:latest"), .qwen,
                     "qwen3.6-claw-fast:latest recognized as Qwen")
        t.checkEqual(DirectorModelFamily.detect(modelIdentifier: "qwen2.5:7b"), .qwen,
                     "qwen2.5:7b recognized as Qwen")
        t.checkEqual(
            DirectorModelFamily.detect(modelIdentifier: "hf.co/Org/Qwen3-8B-GGUF:Q4_K_M"),
            .qwen,
            "hf.co-style Qwen repo path recognized as Qwen"
        )
        t.checkEqual(DirectorModelFamily.detect(modelIdentifier: "llama3.1:8b"), .llama,
                     "llama3.1:8b recognized as Llama")
        t.checkEqual(DirectorModelFamily.detect(modelIdentifier: "gemma2:9b"), .gemma,
                     "gemma2:9b recognized as Gemma")
        t.checkEqual(DirectorModelFamily.detect(modelIdentifier: "mixtral:8x7b"), .mistral,
                     "mixtral:8x7b recognized as Mistral")
        t.checkEqual(DirectorModelFamily.detect(modelIdentifier: "deepseek-r1:32b"), .deepseek,
                     "deepseek-r1:32b recognized as DeepSeek")
        t.checkEqual(DirectorModelFamily.detect(modelIdentifier: "phi3:14b"), .phi,
                     "phi3:14b recognized as Phi")
        t.checkEqual(DirectorModelFamily.detect(modelIdentifier: "muse-glimmer:30b-mlx"), .other,
                     "an unrelated model tag is not misclassified as a known family")
        t.checkEqual(DirectorModelFamily.detect(modelIdentifier: nil), .other,
                     "nil identifier defaults to .other")
        t.checkEqual(DirectorModelFamily.detect(modelIdentifier: "   "), .other,
                     "blank identifier defaults to .other")
    }

    t.suite("DirectorModelProfile never rewrites the underlying model identifier") {
        let qwen = DirectorModelProfile.detect(modelIdentifier: "qwen3.6-claw-fast:latest")
        t.checkEqual(qwen?.family, .qwen, "profile carries the detected family")
        t.checkEqual(qwen?.modelIdentifier, "qwen3.6-claw-fast:latest",
                     "profile preserves the exact installed tag verbatim")
        t.checkEqual(qwen?.displayName, "Qwen Director (qwen3.6-claw-fast:latest)",
                     "display name labels the family without hiding the real tag")

        let unrecognized = DirectorModelProfile.detect(modelIdentifier: "muse-glimmer:30b-mlx")
        t.checkEqual(unrecognized?.displayName, "muse-glimmer:30b-mlx",
                     "an unrecognized family falls back to the raw identifier, never a fabricated label")

        t.check(DirectorModelProfile.detect(modelIdentifier: nil) == nil,
               "no profile is produced when there is no model identifier at all")
        t.check(DirectorModelProfile.detect(modelIdentifier: "") == nil,
               "no profile is produced for an empty model identifier")
    }

    t.suite("DirectorSetupSnapshot.modelProfile is display-only and tracks effectiveModel") {
        let checking = DirectorSetupSnapshot.checking(mode: .auto)
        t.check(checking.modelProfile == nil, "no profile while still checking availability")

        let ready = DirectorSetupSnapshot(
            requestedMode: .auto, effectiveMode: .localAI,
            availability: .localAIReady(model: "qwen3.6-claw-fast:latest"),
            installedModels: ["qwen3.6-claw-fast:latest"], configuredModel: nil,
            effectiveModel: "qwen3.6-claw-fast:latest", fallbackReason: nil
        )
        t.checkEqual(ready.modelProfile?.family, .qwen,
                     "snapshot.modelProfile matches DirectorModelFamily.detect(effectiveModel:)")

        let basic = DirectorSetupSnapshot(
            requestedMode: .basic, effectiveMode: .basic, availability: .basicOnly,
            installedModels: [], configuredModel: nil, effectiveModel: nil, fallbackReason: nil
        )
        t.check(basic.modelProfile == nil, "Basic Director mode has no model profile to display")
    }

    t.suite("FilmProject persists directorProfile/directorPlanningDurationSeconds and decodes legacy JSON without them") {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LTXTests-director-profile-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = FilmProjectStore(projectsDirectory: tmpDir.appendingPathComponent("p1"))
        var project = FilmProject(title: "Qwen Director round-trip")
        project.directorProvider = "ollama"
        project.directorModel = "qwen3.6-claw-fast:latest"
        project.directorProfile = "Qwen Director (qwen3.6-claw-fast:latest)"
        project.directorPlanningDurationSeconds = 4.25
        store.save(project)

        let reloaded = FilmProjectStore(projectsDirectory: tmpDir.appendingPathComponent("p1")).project(id: project.id)
        t.checkEqual(reloaded?.directorProfile, "Qwen Director (qwen3.6-claw-fast:latest)",
                     "directorProfile round-trips through disk persistence")
        t.checkEqual(reloaded?.directorPlanningDurationSeconds, 4.25,
                     "directorPlanningDurationSeconds round-trips through disk persistence")

        // A project saved before this field existed must still decode cleanly,
        // exactly like the other optional Director provenance fields already do.
        let legacyJSON = """
        {"id":"\(UUID().uuidString)","title":"Legacy project","directorProvider":"ollama",
         "directorModel":"qwen2.5:7b","planningMode":"ai"}
        """
        let legacy = try? JSONDecoder().decode(FilmProject.self, from: Data(legacyJSON.utf8))
        t.check(legacy != nil, "legacy JSON without directorProfile/directorPlanningDurationSeconds still decodes")
        t.check(legacy?.directorProfile == nil, "legacy JSON decodes directorProfile as nil, not a crash")
        t.check(legacy?.directorPlanningDurationSeconds == nil,
               "legacy JSON decodes directorPlanningDurationSeconds as nil, not a crash")
    }
}
