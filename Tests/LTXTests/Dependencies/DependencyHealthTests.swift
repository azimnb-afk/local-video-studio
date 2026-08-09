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
    }
}
