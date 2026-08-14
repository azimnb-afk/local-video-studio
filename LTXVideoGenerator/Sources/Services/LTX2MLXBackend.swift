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
        height: Int
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
        if let sourceImage = request.sourceImagePath, !sourceImage.isEmpty {
            args.append(contentsOf: ["--image", sourceImage])
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
            repository: model.repo, userDefaults: userDefaults, fileManager: fileManager
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
        // ltx-2-mlx works in multiples of 32; the app already snaps to 64.
        let width = (params.width / 32) * 32
        let height = (params.height / 32) * 32
        let seed = params.seed ?? Int.random(in: 0..<Int(Int32.max))

        for note in Self.settingsMismatch(request: request).notes {
            progressHandler(0.02, note)
        }

        let args = Self.arguments(
            request: request, modelDirectory: modelDirectory, outputPath: outputPath,
            seed: seed, width: width, height: height
        )
        progressHandler(0.05, "Starting generation on \(GenerationBackendKind.ltx2MLX.displayName)…")

        try await run(executable: executable, arguments: args, progressHandler: progressHandler)

        // The runtime reports success by exit code; the app's contract is a
        // playable file, so the file itself is the acceptance check.
        let size = (try? URL(fileURLWithPath: outputPath).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard fileManager.fileExists(atPath: outputPath), size > 0 else {
            throw LTXError.generationFailed(
                "\(GenerationBackendKind.ltx2MLX.displayName) reported success but wrote no video to \(outputPath)."
            )
        }
        progressHandler(1.0, "Generation complete.")
        return (outputPath, seed, nil)
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

    private func run(
        executable: String,
        arguments: [String],
        progressHandler: @escaping (Double, String) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.environment = Self.runtimeEnvironment()

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            // Progress is coarse on purpose: the runtime prints named phases,
            // and inventing a finer curve from them would be fiction.
            let lock = NSLock()
            var tail: [String] = []
            let note: @Sendable (String) -> Void = { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                lock.lock()
                tail.append(trimmed)
                if tail.count > 40 { tail.removeFirst() }
                lock.unlock()
                progressHandler(Self.progress(for: trimmed), trimmed)
            }
            outPipe.fileHandleForReading.readabilityHandler = { handle in
                guard let text = String(data: handle.availableData, encoding: .utf8) else { return }
                text.components(separatedBy: "\n").forEach(note)
            }
            errPipe.fileHandleForReading.readabilityHandler = { handle in
                guard let text = String(data: handle.availableData, encoding: .utf8) else { return }
                text.components(separatedBy: "\n").forEach(note)
            }

            process.terminationHandler = { finished in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                if finished.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    lock.lock()
                    let detail = tail.suffix(12).joined(separator: "\n")
                    lock.unlock()
                    continuation.resume(throwing: LTXError.generationFailed(
                        "\(GenerationBackendKind.ltx2MLX.displayName) exited with code "
                        + "\(finished.terminationStatus).\n\(detail)"
                    ))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: LTXError.generationFailed(
                    "Could not start \(GenerationBackendKind.ltx2MLX.displayName) at \(executable): "
                    + error.localizedDescription
                ))
            }
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
