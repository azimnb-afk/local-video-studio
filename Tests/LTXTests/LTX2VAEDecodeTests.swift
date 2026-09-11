import Foundation
@testable import LTXVideoGeneratorCore

/// Regression tests for the LTX-2.5 video VAE decode OOM (512×768 × 361 ran as
/// a single pass and hit a Metal out-of-memory at a 47 GB footprint on a
/// 48 GB Mac) and for the failure diagnostics around it.
func runLTX2VAEDecodeTests(_ t: TestKit) {
    let gib = 1_073_741_824.0
    let mac48: UInt64 = 48 * 1_073_741_824

    /// Mirror of the pinned runtime's `_compute_decode_tiling`
    /// (ltx_core_mlx/model/video_vae/video_vae.py, rev b30079e): returns the
    /// temporal tile size in frames, or nil for a single pass.
    func runtimeTileFrames(width: Int, height: Int, frames: Int, budgetGB: String) -> Int? {
        let hLat = height / 32, wLat = width / 32, fLat = (frames - 1) / 8 + 1
        let budgetBytes = Int(Double(budgetGB)! * gib)
        let block3 = 512 * 4 * (hLat * 4) * (wLat * 4) * 2
        if block3 * fLat <= budgetBytes { return nil }
        let maxLatentFrames = max(2, budgetBytes / block3)
        return max(16, maxLatentFrames * 8)
    }

    t.suite("VAE_OOM — decode plan") {
        // VAE_OOM_1: the failing production shape is tiled, under target.
        let failing = LTX2VAEDecodePlan.plan(width: 512, height: 768, frames: 361, unifiedMemoryBytes: mac48)
        t.check(failing.isTiled, "VAE_OOM_1: 512×768 × 361 is decoded in tiles")
        t.checkEqual(failing.framesPerPass, 56, "VAE_OOM_1: 56-frame passes on a 48 GB Mac")
        t.check(failing.predictedPeakBytes <= Double(mac48) * LTX2VAEDecodePlan.targetShareOfUnifiedMemory,
                "VAE_OOM_1: predicted peak \(String(format: "%.1f", failing.predictedPeakBytes / gib)) GB is within the 37.5 % target")
        t.checkEqual(runtimeTileFrames(width: 512, height: 768, frames: 361, budgetGB: failing.budgetGB), 56,
                     "VAE_OOM_1: the runtime's own tiling math turns the budget into exactly the planned tile")

        // VAE_OOM_2: a genuinely small clip stays a single pass; the old
        // "known good" 512×320 × 361 does not (measured 42.7 GB single pass).
        let small = LTX2VAEDecodePlan.plan(width: 512, height: 320, frames: 97, unifiedMemoryBytes: mac48)
        t.check(!small.isTiled, "VAE_OOM_2: 512×320 × 97 fits and stays a single pass")
        t.checkEqual(runtimeTileFrames(width: 512, height: 320, frames: 97, budgetGB: small.budgetGB), nil,
                     "VAE_OOM_2: the runtime also decodes it in one pass")
        let formerlyGood = LTX2VAEDecodePlan.plan(width: 512, height: 320, frames: 361, unifiedMemoryBytes: mac48)
        t.check(formerlyGood.isTiled, "VAE_OOM_2: 512×320 × 361 is tiled (its single pass measured 42.7 GB)")
        let portrait = LTX2VAEDecodePlan.plan(width: 320, height: 512, frames: 361, unifiedMemoryBytes: mac48)
        t.checkEqual(portrait.framesPerPass, formerlyGood.framesPerPass, "VAE_OOM_2: 320×512 plans like 512×320 (same pixels)")
        let landscape = LTX2VAEDecodePlan.plan(width: 768, height: 512, frames: 361, unifiedMemoryBytes: mac48)
        t.checkEqual(landscape.framesPerPass, failing.framesPerPass, "VAE_OOM_2: 768×512 plans like 512×768")

        // VAE_OOM_3: the budget drives the runtime's tile size, and the plan
        // scales with the machine's memory.
        t.checkEqual(runtimeTileFrames(width: 512, height: 768, frames: 361, budgetGB: "0.5"), 168, "VAE_OOM_3: budget 0.5 → 168-frame tiles")
        t.checkEqual(runtimeTileFrames(width: 512, height: 768, frames: 361, budgetGB: "0.25"), 80, "VAE_OOM_3: budget 0.25 → 80-frame tiles")
        t.checkEqual(runtimeTileFrames(width: 512, height: 768, frames: 361, budgetGB: "0.125"), 40, "VAE_OOM_3: budget 0.125 → 40-frame tiles")
        t.checkEqual(runtimeTileFrames(width: 512, height: 768, frames: 361, budgetGB: "2.0"), nil, "VAE_OOM_3: budget 2.0 is still a single pass")
        let mac32 = LTX2VAEDecodePlan.plan(width: 512, height: 768, frames: 361, unifiedMemoryBytes: 32 * 1_073_741_824)
        let mac64 = LTX2VAEDecodePlan.plan(width: 512, height: 768, frames: 361, unifiedMemoryBytes: 64 * 1_073_741_824)
        t.check(mac32.framesPerPass < failing.framesPerPass && failing.framesPerPass < mac64.framesPerPass,
                "VAE_OOM_3: less memory → shorter passes (32/48/64 GB: \(mac32.framesPerPass)/\(failing.framesPerPass)/\(mac64.framesPerPass))")

        let plan = failing
        let computed = LTX2MLXBackend.runtimeEnvironment(decodePlan: plan, temporaryDirectory: nil, base: ["PATH": "/usr/bin"], ffmpegPath: nil)
        t.checkEqual(computed[LTX2VAEDecodePlan.environmentKey], plan.budgetGB, "VAE_OOM_3: the plan's budget reaches the runtime environment")
        let overridden = LTX2MLXBackend.runtimeEnvironment(
            decodePlan: plan, temporaryDirectory: nil,
            base: ["PATH": "/usr/bin", LTX2VAEDecodePlan.environmentKey: "0.3"], ffmpegPath: nil)
        t.checkEqual(overridden[LTX2VAEDecodePlan.environmentKey], "0.3", "VAE_OOM_3: an explicit developer override is kept")

        // VAE_OOM_4: the decision follows the peak stage, not block 3. The
        // runtime's block-3 estimate for the failing shape (1.08 GB) is far
        // under its default 8 GB budget, which is why it chose a single pass.
        let block3Total = Double(512 * 4 * (24 * 4) * (16 * 4) * 2 * 46) / gib
        t.check(block3Total < 8, "VAE_OOM_4: runtime estimate \(String(format: "%.2f", block3Total)) GB → its default is a single pass")
        t.checkEqual(runtimeTileFrames(width: 512, height: 768, frames: 361, budgetGB: "8.0"), nil,
                     "VAE_OOM_4: runtime default reproduces the failing single pass")
        // The plan's model reproduces every measured decode peak within 10 %.
        let measured: [(w: Int, h: Int, passFrames: Int, peakGB: Double)] = [
            (512, 768, 169, 44.23), (512, 768, 81, 23.24), (512, 768, 41, 12.18),
            (512, 768, 121, 33.34), (512, 768, 241, 65.52), (512, 320, 361, 42.74),
        ]
        for m in measured {
            let predicted = (LTX2VAEDecodePlan.fixedOverheadBytes
                + LTX2VAEDecodePlan.bytesPerPixelFrame * Double(m.w * m.h * m.passFrames)) / gib
            t.check(abs(predicted - m.peakGB) / m.peakGB < 0.10,
                    "VAE_OOM_4: \(m.w)×\(m.h) pass of \(m.passFrames) frames predicted \(String(format: "%.1f", predicted)) GB vs measured \(m.peakGB) GB")
        }
    }

    // MARK: - Stub runtime for the backend-level tests

    let work = FileManager.default.temporaryDirectory.appendingPathComponent("vae-oom-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: work) }

    func ffmpeg(_ args: [String]) -> Bool {
        guard let path = FFmpegDetector.findFFmpeg() else { return false }
        let p = Process(); p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["-y", "-v", "error"] + args
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
    let audioOnly = work.appendingPathComponent("audio-only.mp4")
    let realVideo = work.appendingPathComponent("video.mp4")
    let haveMedia = ffmpeg(["-f", "lavfi", "-i", "sine=frequency=440:duration=1", "-c:a", "aac", audioOnly.path])
        && ffmpeg(["-f", "lavfi", "-i", "testsrc=size=64x64:rate=8:duration=1", "-pix_fmt", "yuv420p", realVideo.path])

    /// A stand-in for `ltx-2-mlx generate`: writes `payload` to --output,
    /// drops a WAV into $TMPDIR, prints `lines` to stderr and exits `code`.
    func makeStub(_ name: String, payload: URL?, lines: Int, traceback: Bool, code: Int32, holdPipe: Bool = false) -> URL {
        let stub = work.appendingPathComponent("\(name).sh")
        let tmpMarker = work.appendingPathComponent("\(name).tmpdir")
        var s = "#!/bin/bash\nout=\"\"\nwhile [ $# -gt 0 ]; do [ \"$1\" = \"--output\" ] && out=\"$2\"; shift; done\n"
        s += "echo \"$TMPDIR\" > '\(tmpMarker.path)'\n"
        s += "printf 'RIFF' > \"${TMPDIR}tmpstub.wav\"\n"
        if let payload { s += "cp '\(payload.path)' \"$out\"\n" }
        s += "for i in $(seq 1 \(lines)); do echo \"[step $i] denoising progress line with some padding to make the stream large\" >&2; done\n"
        s += "printf 'Denoising:  50%%|#####     | 4/8\\rDenoising: 100%%|##########| 8/8\\n' >&2\n"
        if holdPipe { s += "( sleep 8 ) &\n" }
        if traceback {
            s += "cat >&2 <<'TB'\nTraceback (most recent call last):\n  File \"/rt/bin/ltx-2-mlx\", line 8, in <module>\n    sys.exit(main())\n  File \"/rt/video_vae.py\", line 510, in decode_and_stream\n    mx.eval(frame_hwc)\nRuntimeError: [METAL] Command buffer execution failed: Insufficient Memory (00000008:kIOGPUCommandBufferCallbackErrorOutOfMemory).\nTB\n"
        }
        s += "exit \(code)\n"
        try? Data(s.utf8).write(to: stub)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        return stub
    }

    func makeBackend(stub: URL) -> (LTX2MLXBackend, GenerationRequest, String) {
        let suite = "vae-oom-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(stub.path, forKey: LTX2MLXRuntimeManager.overrideExecutableKey)
        let modelDir = work.appendingPathComponent("model-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
        try? Data("gguf".utf8).write(to: modelDir.appendingPathComponent("model.gguf"))
        try? Data("vae".utf8).write(to: modelDir.appendingPathComponent("vae_decoder.safetensors"))
        var params = GenerationParameters.default
        params.width = 512; params.height = 768; params.numFrames = 361; params.fps = 24; params.seed = 7
        let request = GenerationRequest(
            prompt: "p", modelId: ModelRegistry.customModelID, parameters: params,
            customModelLocalPath: modelDir.path, customModelSourceMode: CustomModelSourceMode.local.rawValue)
        let output = AppStorageDirectory.videosDirectory.appendingPathComponent("\(UUID().uuidString).mp4").path
        return (LTX2MLXBackend(userDefaults: defaults, fileManager: .default), request, output)
    }

    func generate(_ backend: LTX2MLXBackend, _ request: GenerationRequest, _ output: String) -> (error: String?, seconds: Double) {
        var failure: String?
        let done = DispatchSemaphore(value: 0)
        let start = Date()
        Task.detached {
            do { _ = try await backend.generate(request: request, model: CustomLTX2MLXModelCatalog.customModel(), outputPath: output) { _, _ in } }
            catch { failure = (error as? LTXError)?.localizedDescription ?? error.localizedDescription }
            done.signal()
        }
        done.wait()
        return (failure, Date().timeIntervalSince(start))
    }

    t.suite("VAE_OOM — failure diagnostics and cleanup") {
        t.check(haveMedia, "precondition: ffmpeg produced the audio-only and video fixtures")

        // VAE_OOM_5: the complete end of a traceback survives a 200 KB stderr.
        let oomStub = makeStub("oom", payload: audioOnly, lines: 2500, traceback: true, code: 1)
        let (backend, request, output) = makeBackend(stub: oomStub)
        let result = generate(backend, request, output)
        let message = result.error ?? ""
        t.check(message.contains("RuntimeError: [METAL] Command buffer execution failed: Insufficient Memory"),
                "VAE_OOM_5: the final traceback line (the exception) is in the error message")
        t.check(message.contains("ran out of GPU memory"), "VAE_OOM_5: the failure is classified as a GPU out-of-memory")
        t.check(message.contains("same settings will fail the same way"), "VAE_OOM_5: the message says repeating will not help")
        let logPath = message.components(separatedBy: "Full log: ").last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let log = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
        t.check(log.contains("[step 1] ") && log.contains("[step 2500] ") && log.contains("kIOGPUCommandBufferCallbackErrorOutOfMemory"),
                "VAE_OOM_5: the diagnostic log holds the whole output, first line to last")
        t.check(log.hasPrefix("VAE decode plan: tiled"), "VAE_OOM_5: the log starts with the decode plan")

        // VAE_OOM_6: a failed decode leaves nothing in the videos folder.
        t.check(!FileManager.default.fileExists(atPath: output), "VAE_OOM_6: the audio-only file is not left at the output path")
        let setAside = LTX2MLXBackend.diagnosticsDirectory()!
            .appendingPathComponent(URL(fileURLWithPath: output).deletingPathExtension().lastPathComponent + ".partial.mp4")
        t.check(FileManager.default.fileExists(atPath: setAside.path), "VAE_OOM_6: it is kept with the diagnostic log instead")

        // VAE_OOM_7: exit code 0 with an audio-only file is still a failure.
        t.check(LTX2MLXBackend.outputProblem(atPath: audioOnly.path)?.contains("no video stream") == true,
                "VAE_OOM_7: an audio-only MP4 is recognized as invalid output")
        t.checkEqual(LTX2MLXBackend.outputProblem(atPath: realVideo.path), nil, "VAE_OOM_7: a real video passes")
        let silentStub = makeStub("silent", payload: audioOnly, lines: 3, traceback: false, code: 0)
        let (b7, r7, o7) = makeBackend(stub: silentStub)
        let r7result = generate(b7, r7, o7)
        t.check(r7result.error?.contains("no video stream") == true,
                "VAE_OOM_7: an exit-0 run that wrote only audio is reported as failed")
        t.check(!FileManager.default.fileExists(atPath: o7), "VAE_OOM_7: and its output is not left among the videos")

        // VAE_OOM_8: the runtime's temp WAV goes to a per-run directory that is removed.
        let tmpUsed = (try? String(contentsOf: work.appendingPathComponent("oom.tmpdir"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        t.check(tmpUsed.contains("ltx2mlx-"), "VAE_OOM_8: the runtime ran with a per-run TMPDIR (\(tmpUsed))")
        t.check(!tmpUsed.isEmpty && !FileManager.default.fileExists(atPath: tmpUsed),
                "VAE_OOM_8: that directory (and the WAV in it) is gone after the failed run")

        // Bounded drain: a grandchild holding the pipe cannot stall completion.
        let holdStub = makeStub("hold", payload: nil, lines: 5, traceback: true, code: 1, holdPipe: true)
        let (b9, r9, o9) = makeBackend(stub: holdStub)
        let held = generate(b9, r9, o9)
        t.check(held.seconds < 6.5, "VAE_OOM_5: a grandchild holding the pipe open does not stall completion (\(String(format: "%.1f", held.seconds)) s)")
        t.check(held.error?.contains("Insufficient Memory") == true, "VAE_OOM_5: output written before the grandchild detached is still captured")

        // Readers split tqdm's carriage-return redraws into separate lines.
        var seen: [String] = []
        let lock = NSLock()
        let capture = RuntimeOutputCapture(logURL: nil) { line in lock.lock(); seen.append(line); lock.unlock() }
        let pipe = Pipe()
        capture.read(pipe.fileHandleForReading)
        pipe.fileHandleForWriting.write(Data("Denoising: 1/8\rDenoising: 2/8\rDeco".utf8))
        pipe.fileHandleForWriting.write(Data("ding done é\n".utf8))
        try? pipe.fileHandleForWriting.close()
        capture.waitForEnd(timeout: 2)
        t.checkEqual(capture.tail(10), ["Denoising: 1/8", "Denoising: 2/8", "Decoding done é"],
                     "VAE_OOM_5: \\r redraws become lines; a line split across reads is joined")
    }

    t.suite("VAE_OOM — multi-queue behavior around a failed candidate") {
        // Like the failed production batch: no explicit seed, so each
        // candidate draws its own. (An explicit seed is shared on purpose.)
        var params = GenerationParameters.default
        params.seed = nil
        let base = GenerationRequest(prompt: "p", modelId: ModelRegistry.customModelID, parameters: params)
        let runs = CandidateExpander.expand(base, count: 3)
        let failedID = runs[0].id
        let outcomes = [RunOutcomeRecord(runID: failedID, outcome: .failed, attemptNumber: 1, outputPath: nil,
                                         failureReason: "ltx-2-mlx ran out of GPU memory (Metal: Insufficient Memory)")]
        let planA = RunRetryPlanner.plan(requests: runs, outcomes: outcomes)
        let planB = RunRetryPlanner.plan(requests: runs, outcomes: outcomes)

        // VAE_OOM_9: one failure does not touch its siblings.
        t.checkEqual(planA.requestsToRun.map(\.parameters.seed), runs.map(\.parameters.seed),
                     "VAE_OOM_9: every run keeps its own frozen seed after a sibling fails")
        t.checkEqual(planA.requestsToRun.map(\.parameters.width), runs.map(\.parameters.width),
                     "VAE_OOM_9: sibling settings are unchanged")
        t.checkEqual(Set(runs.map(\.parameters.seed)).count, 3, "VAE_OOM_9: siblings still have distinct seeds")

        // VAE_OOM_10: the (unchanged) policy is deterministic and persisted.
        t.checkEqual(planA, planB, "VAE_OOM_10: planning after a failure is deterministic")
        var job = ProductionJobSnapshot()
        job.pendingRequests = runs
        job.runOutcomes = outcomes
        let decoded = try? JSONDecoder().decode(ProductionJobSnapshot.self, from: JSONEncoder().encode(job))
        t.checkEqual(decoded?.runOutcomes, outcomes, "VAE_OOM_10: the failed run and its OOM reason persist with the job")
    }
}
