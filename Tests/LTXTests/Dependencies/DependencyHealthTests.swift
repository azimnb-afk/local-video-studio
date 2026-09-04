import Foundation
@testable import LTXVideoGeneratorCore

class FakePythonChecker: PythonChecking {
    var status: SetupStatus = .ready
    func check() async -> SetupStatus { status }
}

class FakeFFmpegChecker: FFmpegChecking {
    var status: SetupStatus = .ready
    func check() async -> SetupStatus { status }
}

class FakeModelChecker: ModelChecking {
    var videoStatus: SetupStatus = .ready
    var textStatus: SetupStatus = .ready
    
    func checkVideoModel() async -> SetupStatus { videoStatus }
    func checkTextEncoder() async -> SetupStatus { textStatus }
}

class FakeOptionalServiceChecker: OptionalServiceChecking {
    var localDirectorStatus: SetupStatus = .ready
    var visionStatus: SetupStatus = .ready
    
    func checkLocalDirector() async -> SetupStatus { localDirectorStatus }
    func checkVision() async -> SetupStatus { visionStatus }
}

func runDependencyHealthTests(_ t: TestKit) {
    t.suite("Phase A1 — Dependency Health Checks") {
        print("Test 1: All dependencies ready implies generation is ready")
        var done1 = false
        Task { @MainActor in
            let manager1 = DependencyHealthManager(
                pythonChecker: FakePythonChecker(),
                ffmpegChecker: FakeFFmpegChecker(),
                modelChecker: FakeModelChecker(),
                optionalServiceChecker: FakeOptionalServiceChecker()
            )
            
            await manager1.refresh()
            t.checkEqual(manager1.isGenerationReady, true, "isGenerationReady")
            done1 = true
        }
        while !done1 { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1)) }
        
        print("Test 2: Python missing implies generation is not ready")
        var done2 = false
        Task { @MainActor in
            let python2 = FakePythonChecker()
            python2.status = .missing("Python missing")
            let manager2 = DependencyHealthManager(
                pythonChecker: python2,
                ffmpegChecker: FakeFFmpegChecker(),
                modelChecker: FakeModelChecker(),
                optionalServiceChecker: FakeOptionalServiceChecker()
            )
            await manager2.refresh()
            t.checkEqual(manager2.isGenerationReady, false, "isGenerationReady false")
            t.checkEqual(manager2.statuses[.python], .missing("Python missing"), "Python status")
            done2 = true
        }
        while !done2 { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1)) }
        
        print("Test 3: Optional service missing leaves generation ready")
        var done3 = false
        Task { @MainActor in
            let opt3 = FakeOptionalServiceChecker()
            opt3.localDirectorStatus = .missing("Ollama not running")
            opt3.visionStatus = .missing("Ollama not running")

            let manager3 = DependencyHealthManager(
                pythonChecker: FakePythonChecker(),
                ffmpegChecker: FakeFFmpegChecker(),
                modelChecker: FakeModelChecker(),
                optionalServiceChecker: opt3
            )
            await manager3.refresh()
            t.checkEqual(manager3.isGenerationReady, true, "isGenerationReady true")
            t.checkEqual(manager3.statuses[.localDirector], .missing("Ollama not running"), "Director missing")
            done3 = true
        }
        while !done3 { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1)) }

        // --- Post-Phase-3 regression: Text Encoder / video model setup ---
        // A selected model that is not yet downloaded ("Download Required")
        // must block generation until the user explicitly prepares it in
        // Settings. Generation is never an implicit model installer.

        print("Test 4: selected Text Encoder missing locally -> Generate blocked, routes to explicit Download instead")
        var done4 = false
        Task { @MainActor in
            let models4 = FakeModelChecker()
            models4.videoStatus = .ready
            models4.textStatus = .missing("Text encoder 'Gemma 4B bf16' is not downloaded. Open Preferences > Models to download.")
            let manager4 = DependencyHealthManager(
                pythonChecker: FakePythonChecker(),
                ffmpegChecker: FakeFFmpegChecker(),
                modelChecker: models4,
                optionalServiceChecker: FakeOptionalServiceChecker()
            )
            await manager4.refresh()
            t.checkEqual(manager4.statuses[.textEncoder], models4.textStatus, "textEncoder status reflects missing selection, not silently 'installed'")
            t.checkEqual(manager4.isGenerationReady, false, "isGenerationReady false while a required model is missing")
            t.checkEqual(manager4.canStartGeneration, false, "canStartGeneration false — a missing text encoder now routes to the explicit Download flow instead of an implicit first-use download")
            done4 = true
        }
        while !done4 { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1)) }

        print("Test 5: selected Text Encoder present locally -> ready, no redundant download needed")
        var done5 = false
        Task { @MainActor in
            let models5 = FakeModelChecker()
            models5.videoStatus = .ready
            models5.textStatus = .ready
            let manager5 = DependencyHealthManager(
                pythonChecker: FakePythonChecker(),
                ffmpegChecker: FakeFFmpegChecker(),
                modelChecker: models5,
                optionalServiceChecker: FakeOptionalServiceChecker()
            )
            await manager5.refresh()
            t.checkEqual(manager5.isGenerationReady, true, "isGenerationReady true when everything required is actually cached")
            t.checkEqual(manager5.canStartGeneration, true, "canStartGeneration true when ready")
            done5 = true
        }
        while !done5 { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1)) }

        print("Test 6: selection alone is not installation — video model missing blocks both readiness and the attempt")
        var done6 = false
        Task { @MainActor in
            let models6 = FakeModelChecker()
            models6.videoStatus = .missing("Model 'LTX-2 Unified' is not downloaded. Open Preferences > Models to download.")
            models6.textStatus = .ready
            let manager6 = DependencyHealthManager(
                pythonChecker: FakePythonChecker(),
                ffmpegChecker: FakeFFmpegChecker(),
                modelChecker: models6,
                optionalServiceChecker: FakeOptionalServiceChecker()
            )
            await manager6.refresh()
            t.checkEqual(manager6.isGenerationReady, false, "a selected-but-not-downloaded video model must not be conflated with installed")
            t.checkEqual(manager6.canStartGeneration, false, "canStartGeneration false — a missing video model requires explicit setup")
            done6 = true
        }
        while !done6 { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1)) }

        print("Test 7: an invalid/unregistered selection still blocks the attempt (real problem, not just 'not downloaded yet')")
        var done7 = false
        Task { @MainActor in
            let models7 = FakeModelChecker()
            models7.videoStatus = .ready
            models7.textStatus = .invalid("Selected text encoder 'bogus_id' is not registered.")
            let manager7 = DependencyHealthManager(
                pythonChecker: FakePythonChecker(),
                ffmpegChecker: FakeFFmpegChecker(),
                modelChecker: models7,
                optionalServiceChecker: FakeOptionalServiceChecker()
            )
            await manager7.refresh()
            t.checkEqual(manager7.isGenerationReady, false, "isGenerationReady false for an invalid selection")
            t.checkEqual(manager7.canStartGeneration, false, "canStartGeneration false — an invalid selection is a real problem a generation attempt cannot resolve")
            done7 = true
        }
        while !done7 { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1)) }

        print("Test 8: Python or ffmpeg missing still hard-blocks the attempt even if models are already cached")
        var done8 = false
        Task { @MainActor in
            let python8 = FakePythonChecker()
            python8.status = .missing("Python not configured")
            let manager8 = DependencyHealthManager(
                pythonChecker: python8,
                ffmpegChecker: FakeFFmpegChecker(),
                modelChecker: FakeModelChecker(),
                optionalServiceChecker: FakeOptionalServiceChecker()
            )
            await manager8.refresh()
            t.checkEqual(manager8.canStartGeneration, false, "canStartGeneration false — Python is a hard prerequisite a generation attempt cannot resolve on its own")

            let ffmpeg8 = FakeFFmpegChecker()
            ffmpeg8.status = .missing("FFmpeg not installed")
            let manager8b = DependencyHealthManager(
                pythonChecker: FakePythonChecker(),
                ffmpegChecker: ffmpeg8,
                modelChecker: FakeModelChecker(),
                optionalServiceChecker: FakeOptionalServiceChecker()
            )
            await manager8b.refresh()
            t.checkEqual(manager8b.canStartGeneration, false, "canStartGeneration false — ffmpeg missing also hard-blocks")
            done8 = true
        }
        while !done8 { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1)) }

        print("Test 9: a still-missing text encoder after a failed download attempt stays not-ready and Generate stays blocked (Download's own Retry is the recovery path, see TextEncoderDownloadCoordinator tests)")
        var done9 = false
        Task { @MainActor in
            let models9 = FakeModelChecker()
            models9.videoStatus = .ready
            models9.textStatus = .missing("Text encoder 'Gemma 4B bf16' is not downloaded. Open Preferences > Models to download.")
            let manager9 = DependencyHealthManager(
                pythonChecker: FakePythonChecker(),
                ffmpegChecker: FakeFFmpegChecker(),
                modelChecker: models9,
                optionalServiceChecker: FakeOptionalServiceChecker()
            )
            await manager9.refresh()
            t.checkEqual(manager9.isGenerationReady, false, "a still-missing model after a failed download is not marked ready")
            t.checkEqual(manager9.canStartGeneration, false, "canStartGeneration stays false — Generate is not the retry path for a missing text encoder anymore")
            done9 = true
        }
        while !done9 { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1)) }
    }
}
