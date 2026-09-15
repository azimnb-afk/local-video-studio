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
        // Recorded before it exists, so no crash can leave it unnamed.
        processController?.noteWorkDirectory(workDir.path)
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
    private var returned = false
    /// Records each launched process, so a crash cannot orphan it unnoticed.
    let ownership: AssemblyProcessOwnership?

    init(ownership: AssemblyProcessOwnership? = nil) {
        self.ownership = ownership
    }

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

    /// Whether the attempt's assembly call has returned, however it ended.
    var hasReturned: Bool {
        lock.lock(); defer { lock.unlock() }
        return returned
    }

    func markReturned() {
        lock.lock(); defer { lock.unlock() }
        returned = true
    }

    func noteWorkDirectory(_ path: String) {
        ownership?.workDirectory(path)
    }

    func checkNotCancelled() throws {
        if isCancelled { throw FinalAssemblyService.AssemblyError.cancelled }
    }

    /// Starts `process` for this attempt, or refuses once it is cancelled.
    ///
    /// The lease says a launch is under way before `run()`, and names the
    /// process — PID and kernel identity — straight after. A crash between the
    /// two leaves a lease that admits it cannot identify the process, rather
    /// than one that is silently missing.
    func launch(_ process: Process) throws {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { throw FinalAssemblyService.AssemblyError.cancelled }
        ownership?.launching()
        do {
            try process.run()
        } catch {
            ownership?.exited()
            throw error
        }
        running = process
        ownership?.launched(pid: process.processIdentifier)
    }

    func exited(_ process: Process) {
        lock.lock(); defer { lock.unlock() }
        if running === process {
            running = nil
            ownership?.exited()
        }
    }
}

// MARK: - Orphaned assembly processes

/// What the kernel reports about one live process, read for a single PID.
///
/// A PID alone proves nothing after a relaunch: it can belong to anything by
/// then. The start time is the kernel's own record of when this process began,
/// to the microsecond, and together with the owner, the resolved executable and
/// the full argument vector it identifies one process instance.
struct ProcessIdentity: Codable, Equatable {
    var startSeconds: UInt64
    var startMicroseconds: UInt64
    var userID: UInt32
    var executablePath: String
    var arguments: [String]
}

enum ProcessInspection: Equatable {
    /// No process has this PID.
    case absent
    /// A process has this PID but cannot be read — not this user's, or exiting.
    case unreadable
    case identity(ProcessIdentity)
}

protocol ProcessInspecting {
    /// Reads exactly one PID. Never lists other processes.
    func inspect(pid: Int32) -> ProcessInspection
    /// Sends SIGTERM to exactly this PID.
    func terminate(pid: Int32) -> Bool
}

struct LiveProcessInspector: ProcessInspecting {
    func inspect(pid: Int32) -> ProcessInspection {
        guard pid > 0 else { return .absent }
        if kill(pid, 0) != 0 { return errno == ESRCH ? .absent : .unreadable }

        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              proc_pidpath(pid, &path, UInt32(path.count)) > 0,
              let arguments = Self.arguments(of: pid) else {
            return kill(pid, 0) != 0 && errno == ESRCH ? .absent : .unreadable
        }
        return .identity(ProcessIdentity(
            startSeconds: info.pbi_start_tvsec,
            startMicroseconds: info.pbi_start_tvusec,
            userID: info.pbi_uid,
            executablePath: String(cString: path),
            arguments: arguments))
    }

    func terminate(pid: Int32) -> Bool {
        pid > 0 && kill(pid, SIGTERM) == 0
    }

    /// `KERN_PROCARGS2`: argc, the exec path, padding, then argv.
    private static func arguments(of pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var length = 0
        guard sysctl(&mib, 3, nil, &length, nil, 0) == 0, length > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, 3, &buffer, &length, nil, 0) == 0 else { return nil }
        let argc = Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) })
        var index = MemoryLayout<Int32>.size
        while index < length, buffer[index] != 0 { index += 1 }
        while index < length, buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < argc, index < length {
            var end = index
            while end < length, buffer[end] != 0 { end += 1 }
            arguments.append(String(decoding: buffer[index..<end], as: UTF8.self))
            index = end + 1
        }
        return arguments.count == argc ? arguments : nil
    }
}

/// One in-flight assembly attempt's claim on the process and files it is using,
/// persisted so a later launch can tell what a crashed session left running.
struct AssemblyProcessLease: Codable, Equatable {
    var jobID: UUID
    var runID: UUID
    var attempt: Int
    /// The app process that wrote this. A lease from the running instance is
    /// never reaped.
    var ownerAppInstanceID: UUID
    var candidatePath: String
    var outputPath: String
    var workDirectoryPath: String?
    /// Set just before a process is launched and cleared once its identity is
    /// recorded. A lease left in this state names a process that may be running
    /// but cannot be identified.
    var launching: Bool = false
    var pid: Int32?
    /// Read from the kernel right after launch. Nil when it could not be read.
    var identity: ProcessIdentity?

    func isSameAttempt(as other: AssemblyProcessLease) -> Bool {
        jobID == other.jobID && runID == other.runID && attempt == other.attempt
            && ownerAppInstanceID == other.ownerAppInstanceID
    }
}

/// The persisted set of leases. Written synchronously and atomically on every
/// change, because the point is that it is on disk before the process it
/// describes can outlive the app.
final class AssemblyProcessLedger: @unchecked Sendable {
    static let shared = AssemblyProcessLedger()
    /// Minted once per app process.
    static let currentAppInstanceID = UUID()

    private let fileURL: URL
    private let lock = NSLock()

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL
            ?? AppStorageDirectory.root.appendingPathComponent("assembly_process_leases.json")
    }

    func leases() -> [AssemblyProcessLease] {
        lock.lock(); defer { lock.unlock() }
        return read()
    }

    func upsert(_ lease: AssemblyProcessLease) {
        lock.lock(); defer { lock.unlock() }
        var all = read().filter { !$0.isSameAttempt(as: lease) }
        all.append(lease)
        write(all)
    }

    func remove(_ lease: AssemblyProcessLease) {
        lock.lock(); defer { lock.unlock() }
        let all = read()
        let kept = all.filter { !$0.isSameAttempt(as: lease) }
        if kept.count != all.count { write(kept) }
    }

    private func read() -> [AssemblyProcessLease] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([AssemblyProcessLease].self, from: data)) ?? []
    }

    private func write(_ leases: [AssemblyProcessLease]) {
        if leases.isEmpty {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        guard let data = try? JSONEncoder().encode(leases) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// Keeps one attempt's lease in step with what the attempt is doing.
final class AssemblyProcessOwnership: @unchecked Sendable {
    private let ledger: AssemblyProcessLedger
    private let inspector: ProcessInspecting
    private let lock = NSLock()
    private(set) var lease: AssemblyProcessLease

    init(ledger: AssemblyProcessLedger, jobID: UUID, runID: UUID, attempt: Int,
         candidatePath: String, outputPath: String,
         inspector: ProcessInspecting = LiveProcessInspector(),
         ownerAppInstanceID: UUID = AssemblyProcessLedger.currentAppInstanceID) {
        self.ledger = ledger
        self.inspector = inspector
        self.lease = AssemblyProcessLease(
            jobID: jobID, runID: runID, attempt: attempt, ownerAppInstanceID: ownerAppInstanceID,
            candidatePath: candidatePath, outputPath: outputPath)
    }

    private func update(_ change: (inout AssemblyProcessLease) -> Void) {
        lock.lock(); defer { lock.unlock() }
        change(&lease)
        ledger.upsert(lease)
    }

    func begin() { update { _ in } }
    func workDirectory(_ path: String) { update { $0.workDirectoryPath = path } }
    func launching() { update { $0.launching = true; $0.pid = nil; $0.identity = nil } }

    func launched(pid: Int32) {
        let identity: ProcessIdentity?
        if case .identity(let read) = inspector.inspect(pid: pid) { identity = read } else { identity = nil }
        update { $0.launching = false; $0.pid = pid; $0.identity = identity }
    }

    func exited() { update { $0.launching = false; $0.pid = nil; $0.identity = nil } }

    func finish() {
        lock.lock(); defer { lock.unlock() }
        ledger.remove(lease)
    }
}

/// Run once at launch: ends the assembly processes a crashed session left
/// behind — only those whose identity is proven — and removes the exact files
/// their attempts owned once nothing can still be writing them.
///
/// Every doubt resolves toward leaving things alone. A leaked process or file is
/// recoverable; terminating an unrelated process that reused a PID, or deleting
/// output another process is still writing, is not.
enum AssemblyOrphanReaper {

    enum Outcome: Equatable {
        /// Written by the running app instance.
        case currentInstance
        /// The attempt is running in this session.
        case active
        /// The recorded process was verified and ended; its files were removed.
        case terminated
        /// No process was running for the attempt; its files were removed.
        case noProcess
        /// Something runs under the PID but it cannot be proven to be the
        /// recorded process. Not signalled; files left.
        case unverified
        /// Verified and signalled, but still running at the bound. Lease kept.
        case survivedTermination
        /// The session died while launching a process it never identified.
        /// Files left.
        case unidentifiedLaunch
    }

    static func reconcile(
        ledger: AssemblyProcessLedger,
        currentAppInstanceID: UUID = AssemblyProcessLedger.currentAppInstanceID,
        isActive: (AssemblyProcessLease) -> Bool,
        inspector: ProcessInspecting = LiveProcessInspector(),
        fileManager: FileManager = .default,
        terminationTimeout: TimeInterval = 3
    ) -> [(lease: AssemblyProcessLease, outcome: Outcome)] {
        let all = ledger.leases()
        let protected = all.filter { $0.ownerAppInstanceID == currentAppInstanceID || isActive($0) }
        return all.map { lease in
            if lease.ownerAppInstanceID == currentAppInstanceID { return (lease, .currentInstance) }
            if isActive(lease) { return (lease, .active) }
            let outcome = reconcile(lease, protected: protected, inspector: inspector,
                                    fileManager: fileManager, timeout: terminationTimeout)
            if outcome != .survivedTermination { ledger.remove(lease) }
            return (lease, outcome)
        }
    }

    private static func reconcile(
        _ lease: AssemblyProcessLease, protected: [AssemblyProcessLease],
        inspector: ProcessInspecting, fileManager: FileManager, timeout: TimeInterval
    ) -> Outcome {
        if lease.launching { return .unidentifiedLaunch }
        guard let pid = lease.pid else {
            removeFiles(of: lease, protected: protected, fileManager: fileManager)
            return .noProcess
        }
        switch inspector.inspect(pid: pid) {
        case .absent:
            removeFiles(of: lease, protected: protected, fileManager: fileManager)
            return .noProcess
        case .unreadable:
            return .unverified
        case .identity(let live):
            guard isVerified(live, for: lease) else { return .unverified }
            _ = inspector.terminate(pid: pid)
            let deadline = Date().addingTimeInterval(timeout)
            while stillRunning(pid, lease, inspector) {
                guard Date() < deadline else { return .survivedTermination }
                usleep(20_000)
            }
            removeFiles(of: lease, protected: protected, fileManager: fileManager)
            return .terminated
        }
    }

    /// The live process is the one the lease recorded: same kernel start time,
    /// same owner, same resolved executable, the same argument vector — and that
    /// vector names this attempt's own work directory.
    static func isVerified(_ live: ProcessIdentity, for lease: AssemblyProcessLease) -> Bool {
        guard let recorded = lease.identity,
              let workDirectory = lease.workDirectoryPath, !workDirectory.isEmpty else { return false }
        let owned = workDirectory.hasSuffix("/") ? workDirectory : workDirectory + "/"
        return live == recorded
            && live.userID == getuid()
            && recorded.arguments.contains { $0.hasPrefix(owned) }
    }

    private static func stillRunning(
        _ pid: Int32, _ lease: AssemblyProcessLease, _ inspector: ProcessInspecting
    ) -> Bool {
        if case .identity(let live) = inspector.inspect(pid: pid) { return isVerified(live, for: lease) }
        return false
    }

    /// The attempt's candidate file and work directory — the exact paths the
    /// lease names, never anything found by listing — unless another lease the
    /// reaper must not touch names the same path.
    private static func removeFiles(
        of lease: AssemblyProcessLease, protected: [AssemblyProcessLease], fileManager: FileManager
    ) {
        if !protected.contains(where: { $0.candidatePath == lease.candidatePath || $0.outputPath == lease.candidatePath }) {
            MovieAssemblyDriver.discardCandidate(lease.candidatePath, output: lease.outputPath, fileManager: fileManager)
        }
        guard let workDirectory = lease.workDirectoryPath,
              isAssemblyWorkDirectory(workDirectory),
              !protected.contains(where: { $0.workDirectoryPath == workDirectory }) else { return }
        try? fileManager.removeItem(atPath: workDirectory)
    }

    /// Only a directory `assembleFrozen` creates: directly inside the
    /// temporary directory, named for an assembly work directory.
    static func isAssemblyWorkDirectory(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        return url.deletingLastPathComponent().path == temporary.path
            && url.lastPathComponent.hasPrefix("ltx-run-assembly-")
            && FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}
