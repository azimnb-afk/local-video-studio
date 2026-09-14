import Foundation

/// Assembles selected takes into the final film. Hard cuts (MVP).
/// The actual MP4s (ffprobe) decide the strategy:
///   all compatible → ffmpeg concat demuxer with stream copy
///   otherwise      → normalize (re-encode to project settings) → concat
final class FinalAssemblyService {

    enum AssemblyError: Error, Equatable {
        case noSelectedTakes
        case missingTakeFile(String)
        case ffmpegNotFound
        case ffmpegFailed(String)
        case probeFailed(String)
        case bgmFileMissing(String)
        case bgmProbeFailed(String)
        case bgmMixFailed(String)
        case insufficientDiskSpace(String)
        /// The attempt was cancelled; not a failure of the movie.
        case cancelled
    }

    struct AssemblyPlan: Equatable {
        var inputPaths: [String]
        var strategy: Strategy
        enum Strategy: String, Equatable {
            case streamCopy      // identical codecs/dimensions/fps → concat -c copy
            case normalizeReencode
        }
    }

    static let ffmpegCandidates = [
        "/opt/homebrew/bin/ffmpeg",
        "/usr/local/bin/ffmpeg",
        "/usr/bin/ffmpeg",
    ]

    static func ffmpegPath() -> String? {
        ffmpegCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Decides the assembly strategy from real file metadata.
    ///
    /// Chooses its clips from the project's global take selection. That is
    /// correct for a single project-backed movie and is the legacy path; a
    /// run-scoped movie must instead hand over its own clips explicitly —
    /// see `plan(forClipPaths:)`.
    static func plan(for project: FilmProject) throws -> AssemblyPlan {
        let selected = project.shots.sorted { $0.index < $1.index }.compactMap(\.selectedTake)
        guard !selected.isEmpty else { throw AssemblyError.noSelectedTakes }

        var paths: [String] = []
        for take in selected {
            guard let path = take.outputPath, FileManager.default.fileExists(atPath: path) else {
                throw AssemblyError.missingTakeFile(take.outputPath ?? "(nil)")
            }
            paths.append(path)
        }
        return try plan(forClipPaths: paths)
    }

    /// Decides the assembly strategy for an explicit, already-chosen clip list.
    ///
    /// Additive: the caller owns which clips are assembled, which is what lets
    /// two runs of one movie assemble their own films instead of both reading
    /// a single project-wide selection.
    static func plan(forClipPaths clipPaths: [String]) throws -> AssemblyPlan {
        guard !clipPaths.isEmpty else { throw AssemblyError.noSelectedTakes }

        var paths: [String] = []
        var infos: [MediaInfo] = []
        for path in clipPaths {
            guard FileManager.default.fileExists(atPath: path) else {
                throw AssemblyError.missingTakeFile(path)
            }
            guard let info = MediaProbe.probe(path: path) else {
                throw AssemblyError.probeFailed(path)
            }
            paths.append(path)
            infos.append(info)
        }

        let first = infos[0]
        let compatible = infos.allSatisfy {
            $0.videoCodec == first.videoCodec
                && $0.width == first.width && $0.height == first.height
                && abs(($0.fps ?? 0) - (first.fps ?? 0)) < 0.01
                && $0.audioCodec == first.audioCodec
                && $0.sampleRate == first.sampleRate
                && $0.channels == first.channels
        }
        return AssemblyPlan(inputPaths: paths, strategy: compatible ? .streamCopy : .normalizeReencode)
    }

    /// Runs the assembly. Blocking; call from a background context.
    ///
    /// When `project.finalAudio` is off (the default, and every project
    /// written before this feature existed), this produces exactly the same
    /// concatenated movie at `outputPath` as before Global BGM existed — no
    /// extra ffmpeg pass runs at all. Only when BGM is on and an asset is
    /// resolvable does a second, post-assembly mix pass run.
    /// Assembles from wholly explicit, frozen inputs — no `FilmProject`.
    ///
    /// This is the run-scoped entry point. The legacy project-driven
    /// `assemble(project:outputPath:)` is untouched and still serves legacy
    /// Auto Movie; what a queued run needs is that editing or deleting the
    /// source document cannot reach work already submitted.
    static func assembleFrozen(
        clipPaths: [String],
        spec: FrozenMovieAssemblySpec,
        outputPath: String,
        storageChecker: StorageHealthService = .shared,
        processController: AssemblyProcessController? = nil
    ) throws -> MediaInfo {
        // Static audio is verified, not trusted: a swapped file fails the
        // assembly rather than being mixed in silently.
        if let issue = spec.verifyFrozenAudio() {
            throw AssemblyError.insufficientDiskSpace(issue)
        }
        let assemblyPlan = try plan(forClipPaths: clipPaths)
        guard let ffmpeg = ffmpegPath() else { throw AssemblyError.ffmpegNotFound }

        let outputURL = URL(fileURLWithPath: outputPath)
        let totalInputBytes = assemblyPlan.inputPaths.reduce(Int64(0)) { total, path in
            total + ((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0)
        }
        let storageStatus = storageChecker.check(
            url: outputURL, for: .finalAssembly(sourceFileBytes: totalInputBytes))
        if storageStatus.isBlocked {
            throw AssemblyError.insufficientDiskSpace(
                storageStatus.message ?? "Not enough disk space for final assembly.")
        }

        try processController?.checkNotCancelled()
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ltx-run-assembly-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        // Canvas comes from the frozen spec, not from project settings.
        var concatInputs = assemblyPlan.inputPaths
        if assemblyPlan.strategy == .normalizeReencode {
            concatInputs = []
            for (index, input) in assemblyPlan.inputPaths.enumerated() {
                let normalized = workDir.appendingPathComponent("norm_\(index).mp4").path
                try runFFmpeg([
                    "-y", "-i", input,
                    "-vf", "scale=\(spec.width):\(spec.height):force_original_aspect_ratio=decrease,pad=\(spec.width):\(spec.height):(ow-iw)/2:(oh-ih)/2,fps=\(spec.fps)",
                    "-c:v", "libx264", "-preset", "medium", "-crf", "18", "-pix_fmt", "yuv420p",
                    "-c:a", "aac", "-ar", "48000", "-ac", "2",
                    normalized,
                ], ffmpeg: ffmpeg, controller: processController)
                concatInputs.append(normalized)
            }
        }

        let listFile = workDir.appendingPathComponent("concat.txt")
        let listContent = concatInputs
            .map { "file '\($0.replacingOccurrences(of: "'", with: "'\\''"))'" }
            .joined(separator: "\n")
        try listContent.write(to: listFile, atomically: true, encoding: .utf8)

        // Written to a work file first, so a failed concat never disturbs an
        // existing movie at `outputPath`.
        let concatOutputPath = workDir.appendingPathComponent("concatenated.mp4").path
        try runFFmpeg([
            "-y", "-f", "concat", "-safe", "0", "-i", listFile.path,
            "-c", "copy",
            concatOutputPath,
        ], ffmpeg: ffmpeg, controller: processController)

        guard let concatInfo = MediaProbe.probe(path: concatOutputPath) else {
            throw AssemblyError.probeFailed(concatOutputPath)
        }

        // Optional post-assembly mix, from the frozen policy and frozen files.
        if spec.finalAudio.isActive, spec.hasFrozenAudio {
            let mixedOutputPath = workDir.appendingPathComponent("mixed.mp4").path
            try FinalAudioMixer.mix(
                movieInputPath: concatOutputPath,
                movieInfo: concatInfo,
                bgmInputPath: spec.bgmPath,
                ambienceInputPath: spec.ambiencePath,
                settings: spec.finalAudio,
                outputPath: mixedOutputPath,
                ffmpeg: ffmpeg,
                controller: processController)
            guard let mixedInfo = MediaProbe.probe(path: mixedOutputPath), mixedInfo.hasAudio else {
                throw AssemblyError.bgmProbeFailed(mixedOutputPath)
            }
            try processController?.checkNotCancelled()
            try replaceFile(at: outputPath, with: mixedOutputPath)
            return mixedInfo
        }

        try processController?.checkNotCancelled()
        try replaceFile(at: outputPath, with: concatOutputPath)
        guard let info = MediaProbe.probe(path: outputPath) else {
            throw AssemblyError.probeFailed(outputPath)
        }
        return info
    }

    /// - Parameter clipPaths: when supplied, these exact clips are assembled
    ///   instead of the project's globally selected takes. A run-scoped movie
    ///   passes its own frozen list so two candidate runs of one movie cannot
    ///   splice each other's shots together.
    static func assemble(
        project: FilmProject,
        outputPath: String,
        store: FilmProjectStore = .shared,
        storageChecker: StorageHealthService = .shared,
        clipPaths: [String]? = nil
    ) throws -> MediaInfo {
        let assemblyPlan = try clipPaths.map { try plan(forClipPaths: $0) } ?? plan(for: project)
        guard let ffmpeg = ffmpegPath() else { throw AssemblyError.ffmpegNotFound }

        // Authoritative storage preflight check on output and working volume
        let outputURL = URL(fileURLWithPath: outputPath)
        let totalInputBytes = assemblyPlan.inputPaths.reduce(Int64(0)) { total, path in
            total + ((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0)
        }
        let storageStatus = storageChecker.check(url: outputURL, for: .finalAssembly(sourceFileBytes: totalInputBytes))
        if storageStatus.isBlocked {
            throw AssemblyError.insufficientDiskSpace(storageStatus.message ?? "Not enough disk space for final assembly.")
        }

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ltx-assembly-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        var concatInputs = assemblyPlan.inputPaths

        if assemblyPlan.strategy == .normalizeReencode {
            // Normalize every input to the project's canonical format first.
            let width = project.settings.width
            let height = project.settings.height
            let fps = project.settings.fps
            concatInputs = []
            for (index, input) in assemblyPlan.inputPaths.enumerated() {
                let normalized = workDir.appendingPathComponent("norm_\(index).mp4").path
                try runFFmpeg([
                    "-y", "-i", input,
                    "-vf", "scale=\(width):\(height):force_original_aspect_ratio=decrease,pad=\(width):\(height):(ow-iw)/2:(oh-ih)/2,fps=\(fps)",
                    "-c:v", "libx264", "-preset", "medium", "-crf", "18", "-pix_fmt", "yuv420p",
                    "-c:a", "aac", "-ar", "48000", "-ac", "2",
                    normalized,
                ], ffmpeg: ffmpeg)
                concatInputs.append(normalized)
            }
        }

        // concat demuxer list (paths escaped for ffmpeg's list format).
        let listFile = workDir.appendingPathComponent("concat.txt")
        let listContent = concatInputs
            .map { "file '\($0.replacingOccurrences(of: "'", with: "'\\''"))'" }
            .joined(separator: "\n")
        try listContent.write(to: listFile, atomically: true, encoding: .utf8)

        // Resolve the BGM asset (if any) before touching `outputPath` at all,
        // so a missing/invalid asset fails before any file is written or
        // overwritten — the existing Final Movie, if any, is never disturbed.
        let bgmSourcePath: String? = try {
            guard project.finalAudio.isBGMActive, let asset = project.finalAudio.bgmAsset else { return nil }
            guard let url = store.managedProjectAssetURL(projectID: project.id, relativePath: asset.projectRelativePath),
                  FileManager.default.fileExists(atPath: url.path) else {
                throw AssemblyError.bgmFileMissing(asset.originalFilename ?? asset.projectRelativePath)
            }
            return url.path
        }()
        
        let ambienceSourcePath: String? = try {
            guard project.finalAudio.isAmbienceActive, let asset = project.finalAudio.ambienceAsset else { return nil }
            guard let url = store.managedProjectAssetURL(projectID: project.id, relativePath: asset.projectRelativePath),
                  FileManager.default.fileExists(atPath: url.path) else {
                throw AssemblyError.bgmFileMissing(asset.originalFilename ?? asset.projectRelativePath)
            }
            return url.path
        }()

        // Concat always writes to a scratch path first. When BGM is off this
        // scratch file *is* effectively the whole job; it is copied into
        // place only after ffmpeg exits 0, so a failed concat never touches
        // an existing Final Movie at `outputPath`.
        let concatOutputPath = workDir.appendingPathComponent("concatenated.mp4").path
        try runFFmpeg([
            "-y", "-f", "concat", "-safe", "0", "-i", listFile.path,
            "-c", "copy",
            concatOutputPath,
        ], ffmpeg: ffmpeg)

        guard let concatInfo = MediaProbe.probe(path: concatOutputPath) else {
            throw AssemblyError.probeFailed(concatOutputPath)
        }

        if project.finalAudio.isActive && (bgmSourcePath != nil || ambienceSourcePath != nil) {
            let mixedOutputPath = workDir.appendingPathComponent("mixed.mp4").path
            try FinalAudioMixer.mix(
                movieInputPath: concatOutputPath,
                movieInfo: concatInfo,
                bgmInputPath: bgmSourcePath,
                ambienceInputPath: ambienceSourcePath,
                settings: project.finalAudio,
                outputPath: mixedOutputPath,
                ffmpeg: ffmpeg
            )
            guard let mixedInfo = MediaProbe.probe(path: mixedOutputPath), mixedInfo.hasAudio else {
                throw AssemblyError.bgmProbeFailed(mixedOutputPath)
            }
            try replaceFile(at: outputPath, with: mixedOutputPath)
        } else {
            try replaceFile(at: outputPath, with: concatOutputPath)
        }

        // Apply final model-aware resolution crop once to the assembled movie if needed
        let alignment = ModelAwareResolutionAlignment.align(
            requestedWidth: project.settings.width,
            requestedHeight: project.settings.height,
            modelID: project.settings.modelID
        )
        if alignment.crop?.hasCrop == true {
            _ = try? PostGenerationCropService.applyCropIfNeeded(
                videoPath: outputPath,
                alignment: alignment
            )
        }

        guard let info = MediaProbe.probe(path: outputPath) else {
            throw AssemblyError.probeFailed(outputPath)
        }
        return info
    }

    /// Atomic replace for a local single-user file: write finished
    /// elsewhere (already done by the caller), safely replace any previous file
    /// at the destination so a failure never destroys existing output.
    static func replaceFile(at destination: String, with source: String) throws {
        let destinationURL = URL(fileURLWithPath: destination)
        let sourceURL = URL(fileURLWithPath: source)
        let fm = FileManager.default
        let stagingDir = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destinationURL, create: true)
        defer { try? fm.removeItem(at: stagingDir) }
        
        let stagingURL = stagingDir.appendingPathComponent(destinationURL.lastPathComponent)
        try fm.copyItem(at: sourceURL, to: stagingURL)
        
        if fm.fileExists(atPath: destinationURL.path) {
            _ = try fm.replaceItemAt(destinationURL, withItemAt: stagingURL)
        } else {
            try fm.moveItem(at: stagingURL, to: destinationURL)
        }
    }

    static func runFFmpeg(
        _ arguments: [String], ffmpeg: String, controller: AssemblyProcessController? = nil
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = arguments
        let stderr = Pipe()
        process.standardOutput = Pipe()
        process.standardError = stderr
        if let controller {
            try controller.launch(process)
        } else {
            try process.run()
        }
        process.waitUntilExit()
        controller?.exited(process)
        // A process stopped by its attempt's cancel exits non-zero; that is a
        // cancellation, not an ffmpeg failure.
        try controller?.checkNotCancelled()
        if process.terminationStatus != 0 {
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8) ?? ""
            throw AssemblyError.ffmpegFailed(String(message.suffix(2000)))
        }
    }
}

/// One assembly attempt's stop switch.
///
/// Each run-scoped assembly attempt gets its own controller, and every ffmpeg
/// process that attempt launches is started through it. `cancel()` terminates
/// only the process this attempt is running — never any other ffmpeg — and
/// stops the attempt from launching another. Launch and cancel share one lock,
/// so a cancel cannot fall between a process starting and being recorded.
final class AssemblyProcessController: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var running: Process?

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    var hasRunningProcess: Bool {
        lock.lock(); defer { lock.unlock() }
        return running?.isRunning == true
    }

    /// Idempotent. Sends SIGTERM, which ffmpeg handles by exiting.
    func cancel() {
        lock.lock()
        let wasCancelled = cancelled
        cancelled = true
        let process = running
        lock.unlock()
        guard !wasCancelled, let process, process.isRunning else { return }
        process.terminate()
    }

    func checkNotCancelled() throws {
        if isCancelled { throw FinalAssemblyService.AssemblyError.cancelled }
    }

    /// Starts `process` for this attempt, or refuses once it is cancelled.
    func launch(_ process: Process) throws {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { throw FinalAssemblyService.AssemblyError.cancelled }
        try process.run()
        running = process
    }

    func exited(_ process: Process) {
        lock.lock(); defer { lock.unlock() }
        if running === process { running = nil }
    }
}
