import Foundation

/// Runs a generation on the `ltx-2-mlx` runtime (github.com/dgrauet/ltx-2-mlx).
///
/// Deliberately the same shape as the existing backend: a subprocess that
/// writes an MP4 and streams progress lines. No long-lived service, no daemon —
/// the process model that already works is reused rather than replaced.
///
/// This backend never falls back to `mlx-video-with-audio`. If it cannot run,
/// the generation fails on this backend, because returning a video from a
/// different checkpoint would misrepresent what the user asked for.
struct LTX2MLXBackend {
    private let userDefaults: UserDefaults
    private let fileManager: FileManager

    init(userDefaults: UserDefaults = .standard, fileManager: FileManager = .default) {
        self.userDefaults = userDefaults
        self.fileManager = fileManager
    }

    /// Settings this runtime cannot honor as the app expresses them. Surfaced
    /// rather than silently rewritten, so the diagnostics stay truthful.
    struct SettingsMismatch: Equatable {
        var notes: [String]
    }

    /// Builds the argument list. Pure and separately testable — the process
    /// launch below adds nothing that changes meaning.
    static func arguments(
        request: GenerationRequest,
        modelDirectory: String,
        outputPath: String,
        seed: Int,
        width: Int,
        height: Int,
        effectiveSourceImagePath: String? = nil
    ) -> [String] {
        var args = [
            "generate",
            "--model", modelDirectory,
            "--prompt", request.prompt,
            "--output", outputPath,
            "--seed", String(seed),
            "--width", String(width),
            "--height", String(height),
            "--frames", String(request.parameters.numFrames),
            "--frame-rate", String(request.parameters.fps),
            // The DMD distillation is baked into this transformer, so the
            // distilled two-stage pipeline is the one it was packaged for.
            "--distilled",
        ]
        let sourceImage = effectiveSourceImagePath ?? request.sourceImagePath
        if let sourceImage, !sourceImage.isEmpty {
            args.append(contentsOf: ["--image", sourceImage])
        }
        if request.disableAudio {
            args.append("--no-audio")
        }
        return args
    }

    /// Settings the app can express but this pipeline does not take.
    static func settingsMismatch(request: GenerationRequest) -> SettingsMismatch {
        var notes: [String] = []
        // --distilled derives its schedule from --stage1-steps/--stage2-steps,
        // not the single step count the app carries; a DMD-distilled model has
        // its schedule baked in, so forcing the app's number would change the
        // sampler's meaning rather than honor the request.
        notes.append(
            "Steps: requested \(request.parameters.numInferenceSteps); "
            + "the model uses the distilled pipeline's own 8/4-step schedule."
        )
        if request.parameters.guidanceScale > 1.0 {
            notes.append(
                "CFG scale: requested \(request.parameters.guidanceScale); "
                + "the distilled pipeline runs without classifier-free guidance."
            )
        }
        if !request.negativePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            notes.append("Negative prompt is not used by the distilled pipeline (no CFG).")
        }
        return SettingsMismatch(notes: notes)
    }

    func generate(
        request: GenerationRequest,
        model: LTXModel,
        outputPath: String,
        progressHandler: @escaping (Double, String) -> Void
    ) async throws -> (videoPath: String, seed: Int, enhancedPrompt: String?) {
        let readiness = LTX2MLXRuntime.readiness(
            modelID: request.modelId,
            repository: model.repo,
            localPath: request.customModelLocalPath,
            sourceMode: request.customModelSourceMode.flatMap { CustomModelSourceMode(rawValue: $0) },
            userDefaults: userDefaults,
            fileManager: fileManager
        )
        // Runtime and model are reported separately: they have different fixes.
        guard case .ready(let executable) = readiness.runtime else {
            throw LTXError.modelLoadFailed("\(model.displayName): \(readiness.runtime.detail)")
        }
        guard case .ready(let modelDirectory) = readiness.model else {
            throw LTXError.modelLoadFailed("\(model.displayName): \(readiness.model.detail)")
        }
        guard FFmpegDetector.isAvailable else {
            throw LTXError.generationFailed(
                "FFmpeg is required for \(GenerationBackendKind.ltx2MLX.displayName) video generation but was not found. "
                + "Install it via Homebrew: brew install ffmpeg"
            )
        }

        let params = request.parameters
        let alignment = ModelAwareResolutionAlignment.align(
            requestedWidth: params.width,
            requestedHeight: params.height,
            modelID: request.modelId,
            isContinuation: request.isContinuation
        )
        let width = alignment.generation.width
        let height = alignment.generation.height
        let seed = ExecutionSeedResolver.resolve(params, backend: "ltx2-mlx")

        var effectiveSourceImage = request.sourceImagePath
        if let rawPath = request.sourceImagePath?.trimmingCharacters(in: .whitespacesAndNewlines), !rawPath.isEmpty {
            if let prepared = try? ImageConditioningPreparer.shared.prepare(
                sourceURL: URL(fileURLWithPath: rawPath),
                targetWidth: width,
                targetHeight: height
            ) {
                effectiveSourceImage = prepared.preparedURL.path
            }
        }

        for note in Self.settingsMismatch(request: request).notes {
            progressHandler(0.02, note)
        }

        let args = Self.arguments(
            request: request, modelDirectory: modelDirectory, outputPath: outputPath,
            seed: seed, width: width, height: height,
            effectiveSourceImagePath: effectiveSourceImage
        )
        progressHandler(0.05, "Starting generation on \(GenerationBackendKind.ltx2MLX.displayName)…")

        let decodePlan = LTX2VAEDecodePlan.plan(
            width: width, height: height, frames: params.numFrames,
            unifiedMemoryBytes: ProcessInfo.processInfo.physicalMemory
        )
        // The runtime's temporary files (the decoded audio WAV) go to a
        // per-run directory that is removed afterwards: ltx-2-mlx leaves its
        // WAV behind whenever the video decode raises.
        let runTemporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("ltx2mlx-\(UUID().uuidString)", isDirectory: true)
        try? fileManager.createDirectory(at: runTemporaryDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: runTemporaryDirectory) }
        let diagnostics = Self.diagnosticsDirectory(fileManager: fileManager)
        let logURL = diagnostics?.appendingPathComponent(
            URL(fileURLWithPath: outputPath).deletingPathExtension().lastPathComponent + ".log")
        print("[LTX2MLXBackend] \(decodePlan.summary)")

        do {
            try await run(
                executable: executable,
                arguments: args,
                environment: Self.runtimeEnvironment(decodePlan: decodePlan, temporaryDirectory: runTemporaryDirectory),
                logURL: logURL,
                logHeader: decodePlan.summary,
                progressHandler: progressHandler
            )
            // The runtime reports success by exit code; the app's contract is a
            // playable video, so the file itself is the acceptance check.
            if let problem = Self.outputProblem(atPath: outputPath, fileManager: fileManager) {
                throw LTXError.generationFailed("\(GenerationBackendKind.ltx2MLX.displayName) \(problem)")
            }
        } catch {
            // Whatever the runtime left at the output path (an audio-only MP4
            // after a failed video decode) is not a generation result. Keep it
            // next to the log for diagnosis rather than among the videos.
            Self.setAsidePartialOutput(atPath: outputPath, into: diagnostics, fileManager: fileManager)
            throw error
        }
        // A run-scoped film child carries no filmProjectID by design, so the
        // old "nil means standalone" test would crop a shot the film pipeline
        // expects uncropped.
        if request.filmProjectID == nil, !request.isRunScopedFilmShot {
            _ = try? PostGenerationCropService.applyCropIfNeeded(
                videoPath: outputPath,
                alignment: alignment,
                fileManager: fileManager
            )
        }
        progressHandler(1.0, "Generation complete.")
        return (outputPath, seed, nil)
    }

    /// The generation environment: FFmpeg on PATH, the VAE decode budget from
    /// `decodePlan`, and a per-run temporary directory.
    static func runtimeEnvironment(
        decodePlan: LTX2VAEDecodePlan.Plan,
        temporaryDirectory: URL?,
        base: [String: String] = ProcessInfo.processInfo.environment,
        ffmpegPath: String? = FFmpegDetector.findFFmpeg()
    ) -> [String: String] {
        var env = runtimeEnvironment(base: base, ffmpegPath: ffmpegPath)
        // A value already in the app's own environment is a deliberate
        // developer override and wins over the computed plan.
        if env[LTX2VAEDecodePlan.environmentKey] == nil {
            env[LTX2VAEDecodePlan.environmentKey] = decodePlan.budgetGB
        }
        if let temporaryDirectory {
            env["TMPDIR"] = temporaryDirectory.path + "/"
        }
        return env
    }

    /// Where failed-run logs and set-aside partial outputs are kept.
    static func diagnosticsDirectory(fileManager: FileManager = .default) -> URL? {
        let url = AppStorageDirectory.root
            .appendingPathComponent("Diagnostics", isDirectory: true)
            .appendingPathComponent("ltx-2-mlx", isDirectory: true)
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        } catch {
            return nil
        }
    }

    /// Why the file at `path` is not an acceptable generation result, or nil.
    ///
    /// Exit code 0 is not proof of a video: ltx-2-mlx treats a closed ffmpeg
    /// pipe as a warning, which can leave an audio-only MP4 behind.
    static func outputProblem(atPath path: String, fileManager: FileManager = .default) -> String? {
        let size = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard fileManager.fileExists(atPath: path), size > 0 else {
            return "reported success but wrote no video to \(path)."
        }
        // Without ffprobe the stream layout cannot be checked; keep the
        // previous size-based acceptance rather than rejecting every result.
        guard let info = MediaProbe.probe(path: path) else { return nil }
        if info.videoCodec == nil {
            return "produced no video frames: the output has no video stream (audio only)."
        }
        if info.frameCount == 0 {
            return "produced no video frames: the video stream is empty."
        }
        return nil
    }

    /// Moves a failed run's partial output out of the videos folder, next to
    /// its diagnostic log. Falls back to deleting it so it can never be
    /// mistaken for a result.
    static func setAsidePartialOutput(atPath path: String, into directory: URL?, fileManager: FileManager = .default) {
        guard fileManager.fileExists(atPath: path) else { return }
        let source = URL(fileURLWithPath: path)
        if let directory {
            let destination = directory.appendingPathComponent(
                source.deletingPathExtension().lastPathComponent + ".partial." + source.pathExtension)
            try? fileManager.removeItem(at: destination)
            if (try? fileManager.moveItem(at: source, to: destination)) != nil { return }
        }
        try? fileManager.removeItem(at: source)
    }

    /// Builds a process environment containing the resolved FFmpeg directory in PATH.
    static func runtimeEnvironment(
        base: [String: String] = ProcessInfo.processInfo.environment,
        ffmpegPath: String? = FFmpegDetector.findFFmpeg()
    ) -> [String: String] {
        var env = base
        var searchDirs: [String] = []
        if let ffmpeg = ffmpegPath {
            let dir = URL(fileURLWithPath: ffmpeg).deletingLastPathComponent().path
            searchDirs.append(dir)
        }
        for candidate in FFmpegDetector.searchPaths {
            let dir = URL(fileURLWithPath: candidate).deletingLastPathComponent().path
            if !searchDirs.contains(dir) {
                searchDirs.append(dir)
            }
        }
        let existing = env["PATH"] ?? ""
        let parts = existing.components(separatedBy: ":")
        var prepend: [String] = []
        for dir in searchDirs {
            if !parts.contains(dir) && !prepend.contains(dir) {
                prepend.append(dir)
            }
        }
        if !prepend.isEmpty {
            env["PATH"] = (prepend + [existing]).filter { !$0.isEmpty }.joined(separator: ":")
        }
        return env
    }

    private let processTracker = ProcessCancellationTracker()

    func cancelActiveGeneration() {
        processTracker.cancel()
    }

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        logURL: URL? = nil,
        logHeader: String? = nil,
        progressHandler: @escaping (Double, String) -> Void
    ) async throws {
        // Progress is coarse on purpose: the runtime prints named phases,
        // and inventing a finer curve from them would be fiction.
        let capture = RuntimeOutputCapture(logURL: logURL, header: logHeader) { line in
            progressHandler(Self.progress(for: line), line)
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.environment = environment

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            // Both streams are read to EOF on their own threads, so the last
            // lines the runtime writes before exiting (a Python traceback) are
            // kept instead of being dropped when the process ends.
            capture.read(outPipe.fileHandleForReading)
            capture.read(errPipe.fileHandleForReading)

            process.terminationHandler = { [weak processTracker] finished in
                // Bounded: a surviving grandchild (the runtime's ffmpeg) can
                // hold a pipe open after the runtime itself has exited.
                capture.waitForEnd(timeout: 3)
                capture.finish()
                let wasCancelled = processTracker?.isCancelled == true
                processTracker?.unregister(finished)
                if wasCancelled {
                    continuation.resume(throwing: LTXError.cancelled)
                } else if finished.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let detail = capture.tail(12).joined(separator: "\n")
                    let logNote = capture.logPath.map { "\nFull log: \($0)" } ?? ""
                    // .uncaughtSignal means the OS killed the process — the
                    // reported terminationStatus is the raw signal number
                    // (confirmed via a direct reproduction: signal 9/SIGKILL,
                    // consistent with a memory/swap exhaustion kill, not the
                    // tool's own Python exit code). Distinguishing this from
                    // an ordinary non-zero exit is worth a clearer message;
                    // it is not evidence of an application bug on its own.
                    let message: String
                    if finished.terminationReason == .uncaughtSignal {
                        message = "\(GenerationBackendKind.ltx2MLX.displayName) was terminated by the "
                            + "system (signal \(finished.terminationStatus)). This commonly indicates "
                            + "memory or swap pressure — try a lower resolution/frame count, close other "
                            + "memory-heavy apps, or free up disk space (swap capacity is disk-backed)."
                            + "\n\(detail)"
                    } else if Self.isGPUOutOfMemory(capture.tail(40)) {
                        message = "\(GenerationBackendKind.ltx2MLX.displayName) ran out of GPU memory "
                            + "(Metal: Insufficient Memory) and exited with code \(finished.terminationStatus). "
                            + "Repeating the same settings will fail the same way; a lower resolution or a "
                            + "shorter clip needs less memory."
                            + "\n\(detail)"
                    } else {
                        message = "\(GenerationBackendKind.ltx2MLX.displayName) exited with code "
                            + "\(finished.terminationStatus).\n\(detail)"
                    }
                    continuation.resume(throwing: LTXError.generationFailed(message + logNote))
                }
            }

            do {
                try process.run()
                processTracker.register(process)
            } catch {
                // No child took the write ends; close them so the readers end.
                try? outPipe.fileHandleForWriting.close()
                try? errPipe.fileHandleForWriting.close()
                capture.waitForEnd(timeout: 1)
                capture.finish()
                continuation.resume(throwing: LTXError.generationFailed(
                    "Could not start \(GenerationBackendKind.ltx2MLX.displayName) at \(executable): "
                    + error.localizedDescription
                ))
            }
        }
    }

    /// MLX's GPU allocation failures: a command buffer aborted with
    /// "Insufficient Memory", or an allocation refused up front.
    static func isGPUOutOfMemory(_ lines: [String]) -> Bool {
        lines.contains { line in
            line.contains("kIOGPUCommandBufferCallbackErrorOutOfMemory")
                || line.localizedCaseInsensitiveContains("Insufficient Memory")
                || line.contains("[metal::malloc]")
        }
    }

    /// Maps the runtime's phase lines onto a coarse progress value.
    static func progress(for line: String) -> Double {
        let value = line.lowercased()
        if value.contains("loading text encoder") || value.contains("gemma") { return 0.10 }
        if value.contains("encoding prompt") { return 0.20 }
        if value.contains("loading transformer") || value.contains("transformer") { return 0.30 }
        if value.contains("stage 2") { return 0.70 }
        if value.contains("decod") || value.contains("vocoder") { return 0.85 }
        if value.contains("saving") || value.contains("writing") { return 0.95 }
        return 0.50
    }
}

// MARK: - VAE decode memory plan

/// Chooses `LTX2_VAE_DECODE_BUDGET_GB` so ltx-2-mlx's video VAE decode fits
/// in memory, by temporal tiling — never by changing the requested size or
/// length.
///
/// ltx-2-mlx decides tiling from one decoder activation (block 3: 512 ch ×
/// 4F × 4H × 4W, bf16) against an 8 GB budget. The real peak is the later,
/// full-resolution stages and is ~85× that, so it decoded 512×768 × 361 in a
/// single pass and failed with a Metal out-of-memory at a 47 GB footprint on
/// a 48 GB Mac. Measured on the pinned runtime (decode-only, M4 Pro 48 GB),
/// MLX's active peak is ≈ 2.16 GB + 684 bytes per pixel per frame of the
/// largest decode pass:
///   512×768, tiles of 168 / 80 / 40 frames → 44.2 / 23.2 / 12.2 GB
///   512×768 × 121 single pass → 33.3 GB; × 241 → 65.5 GB (only via swap)
///   512×320 × 361 single pass → 42.7 GB
enum LTX2VAEDecodePlan {
    static let environmentKey = "LTX2_VAE_DECODE_BUDGET_GB"
    static let fixedOverheadBytes = 2.16 * 1_073_741_824.0
    static let bytesPerPixelFrame = 684.0
    /// Upper bound for the predicted MLX active peak, as a share of unified
    /// memory. Measured system free memory was 45 % at a 12 GB peak and 20 %
    /// at 23 GB; the process footprint runs well above MLX's active figure
    /// (buffer cache, decoder weights, frames queued for ffmpeg). 37.5 %
    /// (18 GB on 48 GB) keeps roughly a third of the machine free and stays
    /// under half of Metal's recommended working set (37.4 GB on 48 GB).
    static let targetShareOfUnifiedMemory = 0.375

    struct Plan: Equatable {
        /// Latent frames in the clip.
        let latentFrames: Int
        /// Latent frames decoded per pass; equal to `latentFrames` for a single pass.
        let latentFramesPerPass: Int
        /// Video frames in the largest decode pass.
        let framesPerPass: Int
        let predictedPeakBytes: Double
        /// Value for `LTX2_VAE_DECODE_BUDGET_GB`.
        let budgetGB: String

        var isTiled: Bool { latentFramesPerPass < latentFrames }

        var summary: String {
            let peak = String(format: "%.1f", predictedPeakBytes / 1_073_741_824)
            let passes = isTiled ? "tiled, \(framesPerPass)-frame passes" : "single pass"
            return "VAE decode plan: \(passes), predicted peak \(peak) GB, "
                + "\(LTX2VAEDecodePlan.environmentKey)=\(budgetGB)"
        }
    }

    static func plan(width: Int, height: Int, frames: Int, unifiedMemoryBytes: UInt64) -> Plan {
        let heightLatent = max(1, (height + 31) / 32)
        let widthLatent = max(1, (width + 31) / 32)
        let latentFrames = max(1, (frames - 1) / 8 + 1)
        let bytesPerFrame = bytesPerPixelFrame * Double(heightLatent * 32 * widthLatent * 32)
        let target = Double(unifiedMemoryBytes) * targetShareOfUnifiedMemory
        let maxFramesPerPass = (target - fixedOverheadBytes) / bytesPerFrame

        let perPass: Int
        if Double(frames) <= maxFramesPerPass {
            perPass = latentFrames
        } else {
            // The runtime never tiles below 2 latent frames.
            perPass = min(latentFrames, max(2, Int(maxFramesPerPass / 8)))
        }
        let framesPerPass = perPass == latentFrames ? frames : max(16, perPass * 8)

        // The runtime compares this budget against one block-3 activation per
        // latent frame and floors the quotient; half a latent frame of
        // headroom makes that floor land on exactly `perPass`.
        let block3BytesPerLatentFrame = Double(512 * 4 * (4 * heightLatent) * (4 * widthLatent) * 2)
        let budget = (Double(perPass) + 0.5) * block3BytesPerLatentFrame / 1_073_741_824
        return Plan(
            latentFrames: latentFrames,
            latentFramesPerPass: perPass,
            framesPerPass: framesPerPass,
            predictedPeakBytes: fixedOverheadBytes + bytesPerFrame * Double(framesPerPass),
            budgetGB: String(format: "%.9f", budget)
        )
    }
}

// MARK: - Runtime output capture

/// Reads a runtime subprocess's stdout and stderr to EOF on background
/// threads. Forwards lines for progress, keeps a bounded tail for the error
/// message, and optionally writes everything to a diagnostic log.
final class RuntimeOutputCapture: @unchecked Sendable {
    let logPath: String?

    private let lock = NSLock()
    private var lines: [String] = []
    private let maxLines: Int
    private let readers = DispatchGroup()
    private var log: FileHandle?
    private let onLine: @Sendable (String) -> Void

    init(logURL: URL?, header: String? = nil, maxLines: Int = 40, onLine: @escaping @Sendable (String) -> Void) {
        self.maxLines = maxLines
        self.onLine = onLine
        if let logURL,
           FileManager.default.createFile(atPath: logURL.path, contents: header.map { Data(($0 + "\n").utf8) }),
           let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            log = handle
            logPath = logURL.path
        } else {
            logPath = nil
        }
    }

    func read(_ handle: FileHandle) {
        readers.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            var pending = Data()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                writeToLog(chunk)
                pending.append(chunk)
                // tqdm redraws with "\r"; both "\r" and "\n" end a line.
                while let end = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                    record(String(decoding: pending[pending.startIndex..<end], as: UTF8.self))
                    pending.removeSubrange(pending.startIndex...end)
                }
                // A redraw without its terminator yet: show it now, keep it
                // in the tail once it completes.
                if !pending.isEmpty {
                    forward(String(decoding: pending, as: UTF8.self))
                }
            }
            if !pending.isEmpty {
                record(String(decoding: pending, as: UTF8.self))
            }
            readers.leave()
        }
    }

    /// Waits for both streams to reach EOF; returns false on timeout.
    @discardableResult
    func waitForEnd(timeout: TimeInterval) -> Bool {
        readers.wait(timeout: .now() + timeout) == .success
    }

    func finish() {
        lock.lock()
        try? log?.close()
        log = nil
        lock.unlock()
    }

    func tail(_ count: Int) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(lines.suffix(count))
    }

    private func record(_ text: String) {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        lock.lock()
        lines.append(line)
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        lock.unlock()
        onLine(line)
    }

    private func forward(_ text: String) {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !line.isEmpty { onLine(line) }
    }

    private func writeToLog(_ data: Data) {
        lock.lock()
        log?.write(data)
        lock.unlock()
    }
}
