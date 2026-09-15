import CryptoKit
import Foundation

/// Thread-safe controller tracking active subprocess instances for graceful cancellation.
///
/// Ensures that cancellation targets only the exact Process instance launched by the
/// application, preventing accidental signals to unrelated processes or PIDs.
/// Serves as the shared cancellation foundation across LTXBridge, LTX2MLXBackend,
/// and future long-running workers (including Director Planning).
final class ProcessCancellationTracker: @unchecked Sendable {

    static let shared = ProcessCancellationTracker()

    private let lock = NSLock()
    private var process: Process?
    private var handle: RenderProcessHandle?
    private var _isCancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isCancelled
    }

    var hasActiveProcess: Bool {
        lock.lock()
        defer { lock.unlock() }
        return process?.isRunning == true
    }

    /// `handle` is set for a render launched under `RenderProcessSupervisor`.
    func register(_ process: Process, handle: RenderProcessHandle? = nil) {
        lock.lock()
        self.process = process
        self.handle = handle
        self._isCancelled = false
        lock.unlock()
    }

    func unregister(_ process: Process) {
        lock.lock()
        var finished: RenderProcessHandle?
        if self.process === process {
            self.process = nil
            finished = handle
            handle = nil
        }
        lock.unlock()
        finished?.finish()
    }

    /// Gracefully terminates the registered process using SIGTERM.
    /// Returns true if a running process was found and signaled.
    ///
    /// `Process.terminate()` signals the process group Foundation created for
    /// the child, so helpers the render started receive SIGTERM too. A
    /// supervised render is also told its owner is done, and its supervisor
    /// SIGKILLs whatever of the group is still there after the grace period.
    @discardableResult
    func cancel() -> Bool {
        lock.lock()
        _isCancelled = true
        let proc = self.process
        let handle = self.handle
        lock.unlock()

        guard let proc, proc.isRunning else {
            handle?.finish()
            return false
        }
        proc.terminate()
        handle?.finish()
        return true
    }

    func reset() {
        lock.lock()
        process = nil
        handle = nil
        _isCancelled = false
        lock.unlock()
    }
}

// MARK: - Render process supervision

/// Who a render process belongs to.
struct RenderProcessOwner: Codable, Equatable {
    var backend: String
    var requestID: UUID
    /// The work the request renders: its take, or its place in a batch.
    var workKey: String
    var attempt: Int
    /// The attempt's own output file; never the adopted one.
    var stagingPath: String

    init(backend: String, request: GenerationRequest, stagingPath: String) {
        self.backend = backend
        self.requestID = request.id
        self.workKey = request.takeID.map { "take:\($0.uuidString)" }
            ?? request.batchID.map { "batch:\($0.uuidString)#\(request.batchIndex ?? 0)" }
            ?? "request:\(request.id.uuidString)"
        self.attempt = request.attemptNumber ?? 1
        self.stagingPath = stagingPath
    }
}

/// Runs a render backend (LTXBridge's Python wrapper, the LTX2MLX runtime)
/// under a small shell supervisor, so the whole render tree ends when its
/// owner does — including when the app itself is gone.
///
/// Foundation already starts the child in its own process group, and
/// `Process.terminate()` signals that group. That was not enough. A member
/// that does not exit on SIGTERM survived cancel. And after a crash nothing
/// signalled the group at all: a render only died when it next wrote to a pipe
/// nobody read, which a quiet render may not do for a long time.
///
/// The supervisor holds the read end of a control pipe on its stdin; the app
/// holds the only write end and never writes to it. The pipe reaches EOF when
/// that write end closes — the app finished with the render, cancelled it, or
/// the app process died, whatever its output was doing. A watcher in the group
/// waiting on that EOF then sends SIGTERM to the group, waits the grace
/// period, and sends SIGKILL. Because the watcher is itself a member until
/// that last signal, the group cannot empty and its id cannot be reused by an
/// unrelated process in between. When the render exits on its own the
/// supervisor ends the watcher and exits with the render's status (re-raising
/// the render's signal, so a system kill still reads as one).
enum RenderProcessSupervisor {
    static let marker = "lvs-render-supervisor"
    static var graceSeconds = 5

    static let script = """
    grace="$1"; shift
    exec 3<&0
    "$@" </dev/null 3<&- &
    child=$!
    (
      trap '' TERM INT HUP
      while read -r _ <&3; do :; done
      kill -TERM 0 2>/dev/null
      /bin/sleep "$grace"
      kill -KILL 0 2>/dev/null
    ) </dev/null >/dev/null 2>&1 &
    watcher=$!
    exec 3<&-
    wait "$child"
    status=$?
    kill -KILL "$watcher" 2>/dev/null
    if [ "$status" -gt 128 ]; then
      trap - TERM INT HUP
      kill -"$((status - 128))" $$ 2>/dev/null
    fi
    exit "$status"
    """

    /// Points `process` at the supervisor running `executable arguments`.
    /// Returns the control pipe to hand to `didLaunch` after `run()`.
    static func configure(_ process: Process, executable: String, arguments: [String]) -> Pipe {
        let control = Pipe()
        // `/bin/bash` itself, not `/bin/sh`: macOS's `/bin/sh` re-executes the
        // selected shell after launch, which would change the executable the
        // lease records a moment later.
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script, marker, String(graceSeconds), executable] + arguments
        process.standardInput = control
        return control
    }

    static func didLaunch(
        _ process: Process, control: Pipe, owner: RenderProcessOwner?,
        ledger: RenderProcessLedger = .shared,
        inspector: ProcessInspecting = LiveProcessInspector()
    ) -> RenderProcessHandle {
        try? control.fileHandleForReading.close()
        let writer = control.fileHandleForWriting
        _ = fcntl(writer.fileDescriptor, F_SETFD, FD_CLOEXEC)
        var lease: RenderProcessLease?
        if let owner, case .identity(let identity) = inspector.inspect(pid: process.processIdentifier) {
            let recorded = RenderProcessLease(
                owner: owner, ownerAppInstanceID: AssemblyProcessLedger.currentAppInstanceID,
                rootPID: process.processIdentifier, processGroupID: getpgid(process.processIdentifier),
                identity: RenderProcessIdentity(identity), launchedAt: Date())
            ledger.upsert(recorded)
            lease = recorded
        }
        let handle = RenderProcessHandle(process: process, control: writer, lease: lease, ledger: ledger)
        RenderProcessRegistry.shared.insert(handle)
        return handle
    }
}

/// The app's hold on one supervised render.
final class RenderProcessHandle: @unchecked Sendable {
    let process: Process
    private let lock = NSLock()
    private var control: FileHandle?
    let lease: RenderProcessLease?
    private let ledger: RenderProcessLedger

    init(process: Process, control: FileHandle, lease: RenderProcessLease?, ledger: RenderProcessLedger) {
        self.process = process
        self.control = control
        self.lease = lease
        self.ledger = ledger
    }

    /// Releases the render: the supervisor ends whatever of its group remains.
    /// Idempotent.
    func finish() {
        lock.lock()
        let writer = control
        control = nil
        lock.unlock()
        guard let writer else { return }
        try? writer.close()
        if let lease { ledger.remove(lease) }
        RenderProcessRegistry.shared.remove(self)
    }
}

/// Supervised renders in flight, so a clean quit can end them.
final class RenderProcessRegistry: @unchecked Sendable {
    static let shared = RenderProcessRegistry()
    private let lock = NSLock()
    private var live: [ObjectIdentifier: RenderProcessHandle] = [:]

    var handles: [RenderProcessHandle] {
        lock.lock(); defer { lock.unlock() }
        return Array(live.values)
    }

    func insert(_ handle: RenderProcessHandle) {
        lock.lock(); defer { lock.unlock() }
        live[ObjectIdentifier(handle)] = handle
    }

    func remove(_ handle: RenderProcessHandle) {
        lock.lock(); defer { lock.unlock() }
        live[ObjectIdentifier(handle)] = nil
    }

    /// Called as the app terminates.
    func stopAllForAppExit() {
        for handle in handles {
            if handle.process.isRunning { handle.process.terminate() }
            handle.finish()
        }
    }
}

/// The kernel identity of a supervised render's root, with its argument vector
/// kept as a digest: the arguments carry the prompt, which does not belong in
/// a process ledger.
struct RenderProcessIdentity: Codable, Equatable {
    var startSeconds: UInt64
    var startMicroseconds: UInt64
    var userID: UInt32
    var executablePath: String
    var argumentsSHA256: String

    init(_ identity: ProcessIdentity) {
        startSeconds = identity.startSeconds
        startMicroseconds = identity.startMicroseconds
        userID = identity.userID
        executablePath = identity.executablePath
        argumentsSHA256 = Self.digest(identity.arguments)
    }

    static func digest(_ arguments: [String]) -> String {
        let joined = Data(arguments.joined(separator: "\u{0}").utf8)
        return SHA256.hash(data: joined).map { String(format: "%02x", $0) }.joined()
    }
}

struct RenderProcessLease: Codable, Equatable {
    var owner: RenderProcessOwner
    var ownerAppInstanceID: UUID
    var rootPID: Int32
    var processGroupID: Int32
    var identity: RenderProcessIdentity
    var launchedAt: Date

    func isSameLaunch(as other: RenderProcessLease) -> Bool {
        rootPID == other.rootPID && identity == other.identity && ownerAppInstanceID == other.ownerAppInstanceID
    }
}

/// Persisted supervised renders, written synchronously and atomically.
final class RenderProcessLedger: @unchecked Sendable {
    static let shared = RenderProcessLedger()
    private let fileURL: URL
    private let lock = NSLock()

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL
            ?? AppStorageDirectory.root.appendingPathComponent("render_process_leases.json")
    }

    func leases() -> [RenderProcessLease] {
        lock.lock(); defer { lock.unlock() }
        return read()
    }

    func upsert(_ lease: RenderProcessLease) {
        lock.lock(); defer { lock.unlock() }
        write(read().filter { !$0.isSameLaunch(as: lease) } + [lease])
    }

    func remove(_ lease: RenderProcessLease) {
        lock.lock(); defer { lock.unlock() }
        let all = read()
        let kept = all.filter { !$0.isSameLaunch(as: lease) }
        if kept.count != all.count { write(kept) }
    }

    private func read() -> [RenderProcessLease] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([RenderProcessLease].self, from: data)) ?? []
    }

    private func write(_ leases: [RenderProcessLease]) {
        if leases.isEmpty {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(leases) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// Signals a process group, for the render reaper.
protocol ProcessGroupSignalling {
    func groupExists(_ pgid: Int32) -> Bool
    func signalGroup(_ pgid: Int32, _ signal: Int32) -> Bool
}

struct LiveProcessGroupSignaller: ProcessGroupSignalling {
    func groupExists(_ pgid: Int32) -> Bool {
        guard pgid > 1 else { return false }
        return killpg(pgid, 0) == 0 || errno == EPERM
    }
    func signalGroup(_ pgid: Int32, _ signal: Int32) -> Bool {
        pgid > 1 && killpg(pgid, signal) == 0
    }
}

/// Run once at launch: ends supervised renders a previous app session left
/// behind — only when the recorded root is proven to be that launch — and then
/// removes that attempt's own staging output. Never adopts, settles or
/// changes a job.
enum RenderOrphanReaper {

    enum Outcome: Equatable {
        case currentInstance
        /// Verified root; its group was ended and its staging output removed.
        case terminated
        /// Neither the root nor any of its group remains; staging output removed.
        case noProcess
        /// Something runs under the PID that is not the recorded launch.
        case unverified
        /// The root is gone but members of its group remain, and nothing proves
        /// the group is still that render's. Left alone; lease kept.
        case unverifiedGroup
        /// Verified and signalled, still present at the bound. Lease kept.
        case survivedTermination
    }

    static func reconcile(
        ledger: RenderProcessLedger = .shared,
        currentAppInstanceID: UUID = AssemblyProcessLedger.currentAppInstanceID,
        inspector: ProcessInspecting = LiveProcessInspector(),
        groups: ProcessGroupSignalling = LiveProcessGroupSignaller(),
        fileManager: FileManager = .default,
        terminationTimeout: TimeInterval = 5
    ) -> [(lease: RenderProcessLease, outcome: Outcome)] {
        ledger.leases().map { lease in
            if lease.ownerAppInstanceID == currentAppInstanceID { return (lease, .currentInstance) }
            let outcome = reconcile(lease, inspector: inspector, groups: groups,
                                    fileManager: fileManager, timeout: terminationTimeout)
            if outcome != .survivedTermination && outcome != .unverifiedGroup { ledger.remove(lease) }
            return (lease, outcome)
        }
    }

    private static func reconcile(
        _ lease: RenderProcessLease, inspector: ProcessInspecting, groups: ProcessGroupSignalling,
        fileManager: FileManager, timeout: TimeInterval
    ) -> Outcome {
        switch inspector.inspect(pid: lease.rootPID) {
        case .absent:
            guard !groups.groupExists(lease.processGroupID) else { return .unverifiedGroup }
            RenderAttemptOutput.discard(stagingPath: lease.owner.stagingPath, fileManager: fileManager)
            return .noProcess
        case .unreadable:
            return .unverified
        case .identity(let live):
            guard isVerified(live, for: lease) else { return .unverified }
            // The verified root is a member, so the group is that render's now.
            // A process group id cannot be handed to a new group while any
            // member remains; the group is watched without a gap from here, and
            // is only signalled again while it has existed throughout.
            _ = groups.signalGroup(lease.processGroupID, SIGTERM)
            let deadline = Date().addingTimeInterval(timeout)
            while groups.groupExists(lease.processGroupID), Date() < deadline { usleep(20_000) }
            if groups.groupExists(lease.processGroupID) {
                _ = groups.signalGroup(lease.processGroupID, SIGKILL)
                let killDeadline = Date().addingTimeInterval(2)
                while groups.groupExists(lease.processGroupID), Date() < killDeadline { usleep(20_000) }
                if groups.groupExists(lease.processGroupID) { return .survivedTermination }
            }
            RenderAttemptOutput.discard(stagingPath: lease.owner.stagingPath, fileManager: fileManager)
            return .terminated
        }
    }

    /// Same kernel start time, owner and executable; the same argument vector;
    /// launched as a render supervisor naming this attempt's staging output; and
    /// the group is the one Foundation made for it.
    static func isVerified(_ live: ProcessIdentity, for lease: RenderProcessLease) -> Bool {
        RenderProcessIdentity(live) == lease.identity
            && live.userID == getuid()
            && lease.processGroupID == lease.rootPID
            && live.arguments.contains(RenderProcessSupervisor.marker)
            && live.arguments.contains { $0.contains(lease.owner.stagingPath) }
    }
}

/// Boundary between model descriptors and generation backends.
/// The official fast path stays inside OfficialMLXAudioAdapter, which is a thin
/// wrapper over the existing LTXBridge — the bridge itself is unchanged.
protocol VideoGenerationAdapter {
    func supports(model: ModelDescriptor) -> Bool

    func generate(
        request: GenerationRequest,
        model: ModelDescriptor,
        outputPath: String,
        progressHandler: @escaping (Double, String) -> Void
    ) async throws -> (videoPath: String, seed: Int, enhancedPrompt: String?)

    func cancelActiveGeneration()
}

extension VideoGenerationAdapter {
    func cancelActiveGeneration() {}
}

/// Official catalog models → existing LTXBridge (protected fast path).
final class OfficialMLXAudioAdapter: VideoGenerationAdapter {
    private let bridge = LTXBridge.shared

    func supports(model: ModelDescriptor) -> Bool {
        model.isOfficial && model.runtime.backend == "mlx-video-with-audio"
    }

    func generate(
        request: GenerationRequest,
        model: ModelDescriptor,
        outputPath: String,
        progressHandler: @escaping (Double, String) -> Void
    ) async throws -> (videoPath: String, seed: Int, enhancedPrompt: String?) {
        try await bridge.generate(
            request: request,
            outputPath: outputPath,
            progressHandler: progressHandler
        )
    }

    func cancelActiveGeneration() {
        bridge.cancelActiveGeneration()
    }
}

/// Derived (non-official) models that have passed the Phase 2 verification
/// gate. Unverified models are rejected before reaching the backend.
final class DerivedModelAdapter: VideoGenerationAdapter {
    private let bridge = LTXBridge.shared

    func supports(model: ModelDescriptor) -> Bool {
        !model.isOfficial && model.runtime.backend == "mlx-video-with-audio"
    }

    func generate(
        request: GenerationRequest,
        model: ModelDescriptor,
        outputPath: String,
        progressHandler: @escaping (Double, String) -> Void
    ) async throws -> (videoPath: String, seed: Int, enhancedPrompt: String?) {
        guard model.runtime.verified else {
            throw LTXError.generationFailed(ModelPolicyError.modelUnverified(modelID: model.id).userMessage)
        }
        guard model.revision != nil || model.localPath != nil else {
            throw LTXError.generationFailed(
                "Derived model '\(model.id)' has no pinned revision or local snapshot; refusing to generate."
            )
        }
        // Derived models reuse the official bridge only because their catalog
        // repo resolves identically; anything needing a different backend goes
        // through its own adapter (e.g. LowRAMMLXAdapter).
        return try await bridge.generate(
            request: request,
            outputPath: outputPath,
            progressHandler: progressHandler
        )
    }

    func cancelActiveGeneration() {
        bridge.cancelActiveGeneration()
    }
}

/// Derived models packaged for the ltx-2-mlx backend. Enforces the
/// same verification and pinned-revision gate as DerivedModelAdapter — being
/// on a different backend doesn't relax that requirement.
final class LTX2MLXAdapter: VideoGenerationAdapter {
    private let backend = LTX2MLXBackend()

    func supports(model: ModelDescriptor) -> Bool {
        !model.isOfficial && model.runtime.backend == "ltx-2-mlx"
    }

    func generate(
        request: GenerationRequest,
        model: ModelDescriptor,
        outputPath: String,
        progressHandler: @escaping (Double, String) -> Void
    ) async throws -> (videoPath: String, seed: Int, enhancedPrompt: String?) {
        guard model.runtime.verified else {
            throw LTXError.generationFailed(ModelPolicyError.modelUnverified(modelID: model.id).userMessage)
        }
        guard model.revision != nil || model.localPath != nil else {
            throw LTXError.generationFailed(
                "Derived model '\(model.id)' has no pinned revision or local snapshot; refusing to generate."
            )
        }
        // LTX2MLXModelCatalog only names the small set of built-in ltx-2-mlx
        // models (the legacy single custom-model slot, LTX-2.5 Experimental).
        // A user-defined custom model profile (`custom_profile_<UUID>`) is not
        // in that catalog and never will be — its identity, display name, and
        // local path already live on `model` itself, resolved moments ago by
        // ModelRegistry.descriptor(for:). Falling back to that descriptor
        // instead of re-deriving from a catalog it was never registered in is
        // what makes every custom profile generate-able through this adapter,
        // not just the one legacy custom-model slot the catalog was written
        // for.
        let ltxModel = LTX2MLXModelCatalog.model(id: model.id) ?? LTXModel(
            id: model.id,
            repo: model.repository,
            displayName: model.displayName,
            downloadSize: model.estimatedModelSizeGB.map { "~\(Int($0))GB" } ?? "unknown",
            supportsBuiltInAudio: model.capabilities.synchronizedAudio,
            qualityWarning: nil,
            recommendedStepsLower: 8,
            recommendedStepsUpper: 30,
            tips: model.runtime.verificationNotes
        )
        return try await backend.generate(
            request: request,
            model: ltxModel,
            outputPath: outputPath,
            progressHandler: progressHandler
        )
    }

    func cancelActiveGeneration() {
        backend.cancelActiveGeneration()
    }
}

/// Stable MiniMax H3 descriptor → dedicated HTTP backend. The resolved
/// descriptor is passed through intact; no legacy LTX catalog is consulted.
final class MiniMaxH3Adapter: VideoGenerationAdapter {
    private let backend: MiniMaxH3Backend

    init(backend: MiniMaxH3Backend = MiniMaxH3Backend()) {
        self.backend = backend
    }

    func supports(model: ModelDescriptor) -> Bool {
        MiniMaxH3Configuration.isMiniMaxH3(modelID: model.id)
            && model.runtime.backend == GenerationBackendKind.minimaxH3.rawValue
    }

    func generate(
        request: GenerationRequest,
        model: ModelDescriptor,
        outputPath: String,
        progressHandler: @escaping (Double, String) -> Void
    ) async throws -> (videoPath: String, seed: Int, enhancedPrompt: String?) {
        guard model.runtime.verified else {
            throw LTXError.generationFailed(
                ModelPolicyError.modelUnverified(modelID: model.id).userMessage)
        }
        do {
            return try await backend.generate(
                request: request,
                model: model,
                outputPath: outputPath,
                progressHandler: progressHandler)
        } catch MiniMaxH3Error.cancelled {
            // Normalize renderer-local cancellation into the queue's existing
            // cancellation contract. Do not add an H3-only terminal state.
            throw LTXError.cancelled
        }
    }

    func cancelActiveGeneration() {
        ProcessCancellationTracker.shared.cancel()
    }
}

/// Picks the adapter for a descriptor. Order matters: first match wins.
final class AdapterRegistry {
    static let shared = AdapterRegistry()

    private(set) var adapters: [VideoGenerationAdapter]

    init(adapters: [VideoGenerationAdapter]? = nil) {
        self.adapters = adapters ?? [
            OfficialMLXAudioAdapter(),
            DerivedModelAdapter(),
            LTX2MLXAdapter(),
            MiniMaxH3Adapter(),
        ]
    }

    func register(_ adapter: VideoGenerationAdapter) {
        adapters.append(adapter)
    }

    func adapter(for model: ModelDescriptor) -> VideoGenerationAdapter? {
        adapters.first { $0.supports(model: model) }
    }

    func cancelActiveGeneration() {
        for adapter in adapters {
            adapter.cancelActiveGeneration()
        }
    }
}
