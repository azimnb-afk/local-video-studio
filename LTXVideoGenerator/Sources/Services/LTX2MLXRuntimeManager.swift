import Foundation

/// Defines the compatibility and capabilities of an app-managed or override `ltx-2-mlx` runtime.
public struct LTX2MLXRuntimeManifest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let minimumRuntimeVersion = "0.2.0-preview4"

    // Runtime source history, most recent first:
    //
    // ead83e2 -> 11a0d33: the official LTX-2.5 combined VAE stores both halves
    // under encoder./decoder. prefixes, but ImageConditioner filtered by the
    // LTX-2.3 "vae_encoder." prefix — matching 0 of the file's 170 keys — and
    // loaded with strict=False, so the video VAE *encoder* silently kept its
    // random initialization. Text-to-video never touches the encoder and stayed
    // correct; every image-conditioned generation (One Shot with a starting
    // image, Auto Movie Shot 1, every continuity shot) encoded its reference
    // through noise and produced a valid MP4 of brown mush. The encoder now
    // mirrors the decoder's loader and uses strict=True, so an unmatched
    // checkpoint fails instead of running on noise — see
    // ltx25_official_video_vae_encoder_v1, required below. The previous export
    // stays reachable as tag v0.9.0-preview.4-runtime so already-shipped
    // Preview.4 installs keep working.
    //
    // cbded94 -> ead83e2: azimnb-afk/ltx-2-mlx was rebuilt as a clean,
    // single-commit source export ("Initial Local Video Studio runtime
    // export") to remove private developer paths and internal branding
    // that were baked into old, already-merged commits inherited from the
    // dgrauet -> mrbizarro fork chain (the working tree was always clean;
    // only inherited git history was affected). The export contains only
    // LICENSE plus each package's README/pyproject/src (no tests/, no
    // poc/, no history) and was independently privacy-audited after
    // publication: fresh clone, full `git log -p --all`, and every raw
    // git object scanned for private paths/branding — zero matches.
    // Functionally identical to cbded94 (same source files, same fixes).
    //
    // 9c5819b -> cbded94: two fixes landed together for Preview.4 —
    // (1) official Lightricks/LTX-2.5 combined Video VAE support
    // (decoder./encoder. prefixes, raw PyTorch Conv3D layout; previously
    // not loadable at all, see ltx25_official_video_vae_v1), and
    // (2) the Generate Audio toggle actually working for LTX-2.5 (a new
    // --no-audio CLI flag threaded through disable_audio, skipping the
    // audio decoder/vocoder load and mux step entirely; previously
    // LTX2MLXBackend.arguments() never read request.disableAudio at all,
    // see ltx25_audio_toggle_v1). Both verified end-to-end through the
    // real app: 86/86 strict VAE load, Audio OFF -> 0 audio streams,
    // Audio ON -> unchanged AAC 48kHz stereo.
    //
    // c49bcc1 -> 9c5819b: exact prefix resolution + strict=True loading for
    // VideoDecoder. Without this fix, MP4 generation can succeed while the
    // decoded video is full-screen noise — see video_decoder_weights_v2.
    //
    // Runtime source moved from dgrauet/ltx-2-mlx (upstream) to
    // azimnb-afk/ltx-2-mlx (a user-owned, user-controlled fork of
    // mrbizarro/ltx-2-mlx, itself a fork of dgrauet/ltx-2-mlx) at the same
    // time as the cbded94 pin bump, so the app is never blocked on an
    // external maintainer accepting a large experimental PR on their own
    // timeline.
    //
    // Installing a monorepo root via plain `pip install git+<url>@<rev>`
    // does not work here regardless of revision — ltx-2-mlx is a uv
    // workspace with no single installable package at the repo root
    // (setuptools refuses outright: "Multiple top-level packages
    // discovered in a flat-layout: ['poc', 'packages']"). installManagedRuntime
    // below installs each of packages/ltx-core-mlx and
    // packages/ltx-pipelines-mlx individually via pip's VCS subdirectory
    // syntax (#subdirectory=...), mirroring the editable dev-override path.
    // Verified against the real public repo with no developer overrides.
    public static let pinnedRepoURL: String = "https://github.com/azimnb-afk/ltx-2-mlx.git"
    public static let pinnedSourceRevision: String = "b30079e"

    // ltx25_official_video_vae_encoder_v1 is required as of the 11a0d33 pin.
    // The pin and this entry move together on purpose: requiring a capability
    // that the pinned runtime does not provide would mark every install
    // permanently outdated, and pinning a runtime without the capability
    // would silently restore the corrupted image-conditioning path.
    public static let requiredCapabilities: [String] = [
        "ltx25_gguf",
        "gguf_block_streaming_v1",
        "audio_decode_v2",
        "video_decoder_weights_v2",
        "ltx25_official_video_vae_v1",
        "ltx25_audio_toggle_v1",
        "ltx25_official_video_vae_encoder_v1"
    ]

    public var schemaVersion: Int
    public var runtime: String
    public var runtimeVersion: String
    public var sourceRevision: String
    public var capabilities: [String]
    public var installedAt: Date?

    public init(
        schemaVersion: Int = currentSchemaVersion,
        runtime: String = "ltx-2-mlx",
        runtimeVersion: String = minimumRuntimeVersion,
        sourceRevision: String = pinnedSourceRevision,
        capabilities: [String] = requiredCapabilities,
        installedAt: Date? = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.runtime = runtime
        self.runtimeVersion = runtimeVersion
        self.sourceRevision = sourceRevision
        self.capabilities = capabilities
        self.installedAt = installedAt
    }

    public var isCompatible: Bool {
        for req in Self.requiredCapabilities {
            if !capabilities.contains(req) {
                return false
            }
        }
        return true
    }

    public var missingCapabilities: [String] {
        Self.requiredCapabilities.filter { !capabilities.contains($0) }
    }
}

/// Status of the LTX-2.5 / ltx-2-mlx runtime.
public enum LTX2MLXRuntimeStatus: Equatable, Sendable {
    case notInstalled
    case installing(progress: Double, step: String)
    case ready(executablePath: String, manifest: LTX2MLXRuntimeManifest)
    case outdated(executablePath: String, currentVersion: String, requiredVersion: String, missingCapabilities: [String])
    case broken(reason: String)
    /// The runtime is on disk but its capabilities have not been verified yet;
    /// a background probe is running. Never Ready: an unverified runtime must
    /// not be offered for generation.
    case checking(executablePath: String)

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    public var executablePath: String? {
        switch self {
        case .ready(let path, _), .outdated(let path, _, _, _):
            return path
        default:
            return nil
        }
    }

    public var displayMessage: String {
        switch self {
        case .notInstalled:
            return "Runtime is not installed."
        case .installing(_, let step):
            return "Installing runtime: \(step)…"
        case .ready(_, let manifest):
            return "Runtime ready (v\(manifest.runtimeVersion), rev \(manifest.sourceRevision.prefix(7)))"
        case .outdated(_, let curr, let req, let missing):
            return "Runtime update required (v\(curr) -> v\(req), missing: \(missing.joined(separator: ", ")))"
        case .broken(let reason):
            return "Runtime issue: \(reason)"
        case .checking:
            return "Checking runtime…"
        }
    }
}

/// Manages the discovery, capability probing, installation, and updating of the LTX-2.5 runtime.
public final class LTX2MLXRuntimeManager: ObservableObject, @unchecked Sendable {
    public static let shared = LTX2MLXRuntimeManager()

    public static let overrideExecutableKey = "ltx2mlxExecutableOverridePath"
    public static let legacyExecutableKey = "ltx2mlxExecutablePath"

    @Published public private(set) var status: LTX2MLXRuntimeStatus

    private let fileManager: FileManager
    private let userDefaults: UserDefaults
    private let probeCache: LTX2MLXCapabilityProbeCache

    public init(
        fileManager: FileManager = .default,
        userDefaults: UserDefaults = .standard,
        probeTimeout: TimeInterval? = nil
    ) {
        self.fileManager = fileManager
        self.userDefaults = userDefaults
        self.probeCache = LTX2MLXCapabilityProbeCache(
            timeout: probeTimeout ?? LTX2MLXCapabilityProbeCache.defaultTimeout)
        // Fast, non-probing initial guess (no subprocess launch during app
        // init); refreshStatus()/evaluateStatus() do the real capability
        // probe. Priority must match evaluateStatus(): an explicit Advanced
        // override wins, then the installed managed runtime, then the
        // legacy General Settings path as a last resort — see evaluateStatus
        // for why the managed runtime outranks the legacy path.
        if let override = Self.nonEmptyValue(userDefaults.string(forKey: Self.overrideExecutableKey)) {
            self.status = .ready(executablePath: override, manifest: LTX2MLXRuntimeManifest())
        } else {
            let managedExec = AppStorageDirectory.runtimesDirectory.appendingPathComponent("ltx-2-mlx/bin/ltx-2-mlx").path
            if fileManager.fileExists(atPath: managedExec) {
                self.status = .ready(executablePath: managedExec, manifest: LTX2MLXRuntimeManifest())
            } else if let legacy = Self.nonEmptyValue(userDefaults.string(forKey: Self.legacyExecutableKey)) {
                self.status = .ready(executablePath: legacy, manifest: LTX2MLXRuntimeManifest())
            } else {
                self.status = .notInstalled
            }
        }
        probeCache.onProbeCompleted = { [weak self] in
            DispatchQueue.main.async { self?.publishProbedStatus() }
        }
    }

    /// Called on the main thread when a background probe finishes. The probe
    /// result is cached by then, so this re-evaluation does not probe again.
    private func publishProbedStatus() {
        if case .installing = status { return }
        status = evaluateStatus()
    }

    private static func nonEmptyValue(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Path Resolution

    /// The root directory for the app-managed `ltx-2-mlx` virtual environment.
    public var managedRuntimeDirectory: URL {
        AppStorageDirectory.runtimesDirectory.appendingPathComponent("ltx-2-mlx", isDirectory: true)
    }

    /// The canonical executable path inside the app-managed runtime directory.
    public var managedExecutableURL: URL {
        managedRuntimeDirectory.appendingPathComponent("bin/ltx-2-mlx")
    }

    /// Manifest file stored alongside the app-managed runtime.
    public var manifestURL: URL {
        managedRuntimeDirectory.appendingPathComponent("runtime_manifest.json")
    }

    /// User-configured override executable path (if any).
    public func overrideExecutablePath(userDefaults: UserDefaults? = nil) -> String? {
        let defaults = userDefaults ?? self.userDefaults
        if let override = defaults.string(forKey: Self.overrideExecutableKey)?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            return override
        }
        if let legacy = defaults.string(forKey: Self.legacyExecutableKey)?.trimmingCharacters(in: .whitespacesAndNewlines), !legacy.isEmpty {
            return legacy
        }
        return nil
    }

    /// Sets or clears the explicit developer override executable path.
    public func setOverrideExecutablePath(_ path: String?) {
        let cleaned = path?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cleaned, !cleaned.isEmpty {
            userDefaults.set(cleaned, forKey: Self.overrideExecutableKey)
        } else {
            userDefaults.removeObject(forKey: Self.overrideExecutableKey)
            userDefaults.removeObject(forKey: Self.legacyExecutableKey)
        }
        refreshStatus()
    }

    // MARK: - Status & Probing

    /// Re-evaluates and publishes the runtime status.
    ///
    /// Never runs or waits on a capability probe on the main thread: there, an
    /// unverified runtime reports `.checking`, the probe runs in the
    /// background, and the verified status is published when it finishes.
    /// `forceProbe` discards cached probe results first (explicit Refresh).
    @discardableResult
    public func refreshStatus(forceProbe: Bool = false) -> LTX2MLXRuntimeStatus {
        if forceProbe { invalidateCapabilityCache() }
        let newStatus = evaluateStatus()
        DispatchQueue.main.async { [weak self] in
            self?.status = newStatus
        }
        return newStatus
    }

    /// Pure status evaluator for testing or background calls.
    ///
    /// Canonical priority — the SAME order Settings display, generation
    /// (`LTX2MLXRuntime.executablePath`/`.readiness`), and this evaluator all
    /// resolve through:
    ///  1. The explicit "Advanced Developer Override" path, when configured —
    ///     a deliberate, current choice with its own Clear button in Settings.
    ///  2. The app-managed runtime, once installed — this is exactly what
    ///     Install/Update/Repair Runtime changes, so once present on disk it
    ///     must outrank a bare historical path that carries no "this is
    ///     intentional" signal.
    ///  3. The legacy General Settings executable path, only as a last
    ///     resort when neither of the above exists — preserves pre-managed-
    ///     runtime setups without letting that historical value permanently
    ///     shadow a newly installed/updated managed runtime forever.
    public func evaluateStatus(userDefaults: UserDefaults? = nil) -> LTX2MLXRuntimeStatus {
        let defaults = userDefaults ?? self.userDefaults

        if let overridePath = Self.nonEmptyValue(defaults.string(forKey: Self.overrideExecutableKey)) {
            return evaluateExplicitPath(overridePath)
        }

        let managedExec = managedExecutableURL.path
        if fileManager.fileExists(atPath: managedExec) {
            guard fileManager.isExecutableFile(atPath: managedExec) else {
                return .broken(reason: "Managed runtime binary is not executable: \(managedExec)")
            }

            var manifest: LTX2MLXRuntimeManifest?
            if fileManager.fileExists(atPath: manifestURL.path),
               let data = try? Data(contentsOf: manifestURL),
               let decoded = try? JSONDecoder().decode(LTX2MLXRuntimeManifest.self, from: data) {
                manifest = decoded
            }

            let probedManifest: LTX2MLXRuntimeManifest
            switch capabilityProbe(executablePath: managedExec) {
            case .unprobeable:
                probedManifest = manifest ?? LTX2MLXRuntimeManifest()
            case .pending:
                return .checking(executablePath: managedExec)
            case .failed(let reason):
                // Fail closed: the on-disk manifest is what the probe exists
                // to verify, so it is never trusted in place of a failed probe.
                return .broken(reason: "Could not verify the runtime (\(reason)).")
            case .capabilities(let caps):
                var verified = manifest ?? LTX2MLXRuntimeManifest()
                verified.capabilities = caps
                probedManifest = verified
            }
            if probedManifest.isCompatible {
                return .ready(executablePath: managedExec, manifest: probedManifest)
            }
            return .outdated(
                executablePath: managedExec,
                currentVersion: probedManifest.runtimeVersion,
                requiredVersion: LTX2MLXRuntimeManifest.minimumRuntimeVersion,
                missingCapabilities: probedManifest.missingCapabilities
            )
        }

        if let legacyPath = Self.nonEmptyValue(defaults.string(forKey: Self.legacyExecutableKey)) {
            return evaluateExplicitPath(legacyPath)
        }

        return .notInstalled
    }

    /// Shared probe used by both the Advanced override and the legacy
    /// General Settings path — the two "explicit executable path" tiers.
    private func evaluateExplicitPath(_ path: String) -> LTX2MLXRuntimeStatus {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else {
            return .broken(reason: "Configured override executable not found at: \(path)")
        }
        guard fileManager.isExecutableFile(atPath: path) else {
            return .broken(reason: "Configured override file is not executable: \(path)")
        }
        let probe: LTX2MLXRuntimeManifest
        switch capabilityProbe(executablePath: path) {
        case .unprobeable:
            probe = LTX2MLXRuntimeManifest()
        case .pending:
            return .checking(executablePath: path)
        case .failed(let reason):
            return .broken(reason: "Could not verify the runtime (\(reason)).")
        case .capabilities(let caps):
            probe = LTX2MLXRuntimeManifest(capabilities: caps)
        }
        if probe.isCompatible {
            return .ready(executablePath: path, manifest: probe)
        } else if !probe.missingCapabilities.isEmpty {
            return .outdated(
                executablePath: path,
                currentVersion: probe.runtimeVersion,
                requiredVersion: LTX2MLXRuntimeManifest.minimumRuntimeVersion,
                missingCapabilities: probe.missingCapabilities
            )
        } else {
            // If probe returned default compatible (e.g. standalone test stub), accept as ready
            return .ready(executablePath: path, manifest: probe)
        }
    }

    /// Outcome of looking up a runtime's capabilities.
    enum CapabilityProbeResult: Equatable {
        /// No `python3` next to the executable (a standalone stub/script):
        /// there is nothing to probe, callers keep their existing fallback.
        case unprobeable
        /// Not verified yet; a background probe is running. Main thread only.
        case pending
        case failed(String)
        case capabilities([String])
    }

    /// The single entry point to capability probing.
    ///
    /// On the main thread this NEVER launches or waits on a process: it answers
    /// from the cache, or starts a background probe (at most one per runtime
    /// identity) and returns `.pending`. A synchronous `waitUntilExit()` here
    /// spun a nested run loop inside SwiftUI's view update and crashed the app.
    /// Off the main thread it answers from the cache or waits — bounded by the
    /// probe timeout — for the one in-flight probe.
    func capabilityProbe(executablePath: String) -> CapabilityProbeResult {
        let pythonPath = URL(fileURLWithPath: executablePath)
            .deletingLastPathComponent().appendingPathComponent("python3").path
        guard fileManager.isExecutableFile(atPath: pythonPath) else { return .unprobeable }
        let key = LTX2MLXCapabilityProbeCache.Key(
            executablePath: executablePath, pythonPath: pythonPath, fileManager: fileManager)

        let outcome: LTX2MLXCapabilityProbeCache.Outcome
        if Thread.isMainThread {
            let cached = probeCache.lookup(key)
            if cached.outcome == nil || cached.isStale {
                probeCache.startProbeIfNeeded(key, script: Self.capabilityProbeScript)
            }
            guard let known = cached.outcome else { return .pending }
            outcome = known
        } else {
            outcome = probeCache.outcome(for: key, script: Self.capabilityProbeScript)
        }
        switch outcome {
        case .capabilities(let caps): return .capabilities(caps)
        case .failed(let reason): return .failed(reason)
        }
    }

    /// Discards cached probe results so the next status evaluation probes
    /// again. Used by explicit Refresh and after installing/updating.
    public func invalidateCapabilityCache() {
        probeCache.invalidate()
    }

    /// Test/debug instrumentation.
    var capabilityProbeCache: LTX2MLXCapabilityProbeCache { probeCache }

    /// Probes the capabilities of a given `ltx-2-mlx` executable.
    ///
    /// Fails closed: a probe that could not run, failed, timed out or has not
    /// finished yet reports no capabilities (never the fallback manifest's).
    public func probeCapabilities(executablePath: String, fallbackManifest: LTX2MLXRuntimeManifest? = nil) -> LTX2MLXRuntimeManifest {
        var manifest = fallbackManifest ?? LTX2MLXRuntimeManifest()
        switch capabilityProbe(executablePath: executablePath) {
        case .unprobeable:
            // A standalone stub or script without adjacent python3 (test harness).
            return manifest
        case .capabilities(let caps):
            manifest.capabilities = caps
        case .pending, .failed:
            manifest.capabilities = []
        }
        return manifest
    }

    static let capabilityProbeScript = """
        import sys, json
        caps = []
        try:
            import ltx_pipelines_mlx.distilled as d
            import inspect
            src = inspect.getsource(d.DistilledPipeline.generate_two_stage)
            if 'audio_latent_4d = self.audio_patchifier.unpatchify' in src:
                caps.append('audio_decode_v2')
        except Exception:
            pass

        try:
            import ltx_core_mlx.loader.block_streaming as bs
            if hasattr(bs, 'GGUFBlockStreamer'):
                caps.append('gguf_block_streaming_v1')
                caps.append('ltx25_gguf')
        except Exception:
            pass

        try:
            import ltx_pipelines_mlx.utils.blocks as blocks
            import inspect
            src = inspect.getsource(blocks.VideoDecoder.load)
            if 'strict=True' in src:
                caps.append('video_decoder_weights_v2')
            if 'pytorch_conv3d_reorder' in src and 'per_channel_statistics.mean-of-means' in src:
                caps.append('ltx25_official_video_vae_v1')
        except Exception:
            pass

        try:
            import ltx_pipelines_mlx.utils.blocks as blocks
            import inspect
            src = inspect.getsource(blocks.ImageConditioner.load)
            # The encoder half of the official combined VAE. Without both of
            # these the encoder silently keeps random weights and every
            # image-conditioned generation decodes to noise.
            if 'strict=True' in src and 'per_channel_statistics.mean_of_means' in src:
                caps.append('ltx25_official_video_vae_encoder_v1')
        except Exception:
            pass

        try:
            import ltx_pipelines_mlx.ti2vid_two_stages as ts
            import inspect
            sig = inspect.signature(ts.TI2VidTwoStagesPipeline.generate_and_save)
            if 'disable_audio' in sig.parameters:
                caps.append('ltx25_audio_toggle_v1')
        except Exception:
            pass

        print(json.dumps({'capabilities': caps}))
        """

    // MARK: - Installation & Updates

    /// Available disk space in bytes for runtime installation.
    public static func freeSpaceBytes() -> Int64 {
        let appSupport = AppStorageDirectory.root.path
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: appSupport),
           let freeSize = attrs[.systemFreeSize] as? NSNumber {
            return freeSize.int64Value
        }
        return Int64.max
    }

    /// Installs or updates the app-managed LTX-2.5 runtime.
    public func installManagedRuntime(
        basePythonPath: String? = nil,
        localSourceDirectory: URL? = nil,
        progressHandler: @escaping (Double, String) -> Void
    ) async throws {
        // Storage preflight
        let freeSpace = Self.freeSpaceBytes()
        let requiredSpace: Int64 = 2 * 1024 * 1024 * 1024 // 2 GB
        if freeSpace < requiredSpace {
            throw LTXError.generationFailed("Insufficient disk space to install LTX-2.5 runtime. At least 2GB free space is required.")
        }

        DispatchQueue.main.async { [weak self] in
            self?.status = .installing(progress: 0.05, step: "Preparing environment")
        }
        progressHandler(0.05, "Preparing runtime environment…")

        // 1. Resolve base Python
        let python = basePythonPath ?? PythonEnvironment.shared.discoverPythonPaths().first(where: {
            !$0.contains("ltx-2-mlx") && PythonEnvironment.shared.isVirtualEnvironment($0) == false
        }) ?? "/usr/bin/python3"

        guard fileManager.isExecutableFile(atPath: python) else {
            let errorMsg = "No suitable base Python installation found to construct isolated runtime."
            DispatchQueue.main.async { [weak self] in self?.status = .broken(reason: errorMsg) }
            throw LTXError.generationFailed(errorMsg)
        }

        // 2. Create isolated venv directory
        let runtimeDir = managedRuntimeDirectory
        let targetPath = runtimeDir.path

        if fileManager.fileExists(atPath: targetPath) {
            try? fileManager.removeItem(at: runtimeDir)
        }
        try fileManager.createDirectory(at: runtimeDir.deletingLastPathComponent(), withIntermediateDirectories: true)

        progressHandler(0.15, "Creating isolated virtual environment…")
        DispatchQueue.main.async { [weak self] in
            self?.status = .installing(progress: 0.15, step: "Creating virtual environment")
        }

        let createProcess = Process()
        createProcess.executableURL = URL(fileURLWithPath: python)
        createProcess.arguments = ["-m", "venv", targetPath]
        let errPipe = Pipe()
        createProcess.standardError = errPipe
        try createProcess.run()
        createProcess.waitUntilExit()

        guard createProcess.terminationStatus == 0 else {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let errorMsg = "Failed to create runtime venv: \(err)"
            DispatchQueue.main.async { [weak self] in self?.status = .broken(reason: errorMsg) }
            throw LTXError.generationFailed(errorMsg)
        }

        let venvPip = runtimeDir.appendingPathComponent("bin/pip").path

        // 3. Install pinned packages
        progressHandler(0.35, "Installing core MLX dependencies…")
        DispatchQueue.main.async { [weak self] in
            self?.status = .installing(progress: 0.35, step: "Installing MLX dependencies")
        }

        let basePackages = ["wheel", "pip", "setuptools"]
        try await runSubprocess(executable: venvPip, arguments: ["install", "--upgrade"] + basePackages)

        let mlxPackages = ["mlx>=0.22.0", "mlx-arsenal>=0.2.4", "mlx-lm>=0.31.0", "numpy", "safetensors", "huggingface_hub", "gguf", "soundfile", "pillow", "tqdm"]
        progressHandler(0.55, "Installing numerical & GGUF streaming packages…")
        DispatchQueue.main.async { [weak self] in
            self?.status = .installing(progress: 0.55, step: "Installing GGUF & Audio packages")
        }
        try await runSubprocess(executable: venvPip, arguments: ["install"] + mlxPackages)

        // 4. Install pinned ltx-2-mlx runtime packages
        progressHandler(0.75, "Configuring LTX-2.5 pipeline runtime…")
        DispatchQueue.main.async { [weak self] in
            self?.status = .installing(progress: 0.75, step: "Finalizing runtime packages")
        }

        // Developer-only override: an explicit parameter or the LTX2MLX_SOURCE_DIR
        // environment variable installs from a local source checkout instead of the
        // pinned public release. Deliberately no implicit path auto-discovery here —
        // a hardcoded developer-machine path has no place in shipped source, and every
        // real end-user install goes through the pinned repository spec below.
        let resolvedLocalSource: URL? = {
            if let localSourceDirectory { return localSourceDirectory }
            if let envPath = ProcessInfo.processInfo.environment["LTX2MLX_SOURCE_DIR"] {
                return URL(fileURLWithPath: envPath)
            }
            return nil
        }()

        if let sourceDir = resolvedLocalSource, fileManager.fileExists(atPath: sourceDir.path) {
            let corePkg = sourceDir.appendingPathComponent("packages/ltx-core-mlx").path
            let pipePkg = sourceDir.appendingPathComponent("packages/ltx-pipelines-mlx").path
            for pkg in [corePkg, pipePkg] {
                if fileManager.fileExists(atPath: pkg) {
                    try await runSubprocess(executable: venvPip, arguments: ["install", "-e", pkg, "--no-deps"])
                }
            }
        } else {
            // For production distributable, install from the pinned repository release.
            // ltx-2-mlx is a uv workspace monorepo: the repo root has no single
            // installable package (setuptools refuses it outright -- "Multiple
            // top-level packages discovered in a flat-layout: ['poc', 'packages']"),
            // so `pip install git+https://.../ltx-2-mlx.git@rev` on the bare repo
            // always fails, for any revision. Each package needs pip's VCS
            // subdirectory syntax, mirroring the editable dev-override path above.
            let pinnedBaseSpec = "git+\(LTX2MLXRuntimeManifest.pinnedRepoURL)@\(LTX2MLXRuntimeManifest.pinnedSourceRevision)"
            for subdirectory in ["packages/ltx-core-mlx", "packages/ltx-pipelines-mlx"] {
                let pinnedRepoSpec = "\(pinnedBaseSpec)#subdirectory=\(subdirectory)"
                try await runSubprocess(executable: venvPip, arguments: ["install", pinnedRepoSpec, "--no-deps"])
            }
        }

        // 5. Write runtime_manifest.json
        let manifest = LTX2MLXRuntimeManifest()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let manifestData = try encoder.encode(manifest)
        try manifestData.write(to: manifestURL)

        // 6. Capability verification — against the runtime just installed,
        // never a result cached for the previous one.
        progressHandler(0.95, "Verifying runtime capabilities…")
        invalidateCapabilityCache()
        let probed = probeCapabilities(executablePath: managedExecutableURL.path, fallbackManifest: manifest)
        guard probed.isCompatible else {
            let errorMsg = "Installed runtime failed capability verification: missing \(probed.missingCapabilities.joined(separator: ", "))"
            DispatchQueue.main.async { [weak self] in self?.status = .broken(reason: errorMsg) }
            throw LTXError.generationFailed(errorMsg)
        }

        // 7. Mark ready atomically
        let readyStatus = LTX2MLXRuntimeStatus.ready(executablePath: managedExecutableURL.path, manifest: probed)
        DispatchQueue.main.async { [weak self] in
            self?.status = readyStatus
        }
        progressHandler(1.0, "LTX-2.5 runtime successfully installed.")
    }

    private func runSubprocess(executable: String, arguments: [String]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let errPipe = Pipe()
        process.standardError = errPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw LTXError.generationFailed("Subprocess \(URL(fileURLWithPath: executable).lastPathComponent) failed: \(err)")
        }
    }
}

// MARK: - Capability probe cache

/// Caches `ltx-2-mlx` capability probe results and owns the probe process.
///
/// A probe launches the runtime's Python and waits for it, so it runs only on
/// a background queue. Guarantees:
///  - at most one probe process per runtime identity at a time (in-flight dedup);
///  - a result is reused until the runtime identity changes or the cache is
///    invalidated (explicit Refresh, runtime install/update);
///  - every probe is bounded by `timeout`, after which the process is killed;
///  - a failure is reused for `failureRetryInterval`, so a broken runtime
///    cannot turn a redraw loop into a process-spawn loop, then re-probed.
final class LTX2MLXCapabilityProbeCache: @unchecked Sendable {
    /// A healthy probe finishes in well under a second (0.1–0.2 s measured
    /// on a warm managed runtime); this only has to cover a cold first import.
    static let defaultTimeout: TimeInterval = 20
    static let failureRetryInterval: TimeInterval = 30

    /// Which on-disk runtime a probe result belongs to. The stamps change when
    /// the venv is recreated (Install / Update / Repair) or the executable is
    /// replaced, so a changed runtime is never answered from a stale entry.
    /// Edits inside an editable developer source checkout do not touch these
    /// files; use Refresh after such edits.
    struct Key: Hashable, Sendable {
        let executablePath: String
        let pythonPath: String
        let executableStamp: FileStamp?
        let pythonStamp: FileStamp?

        init(executablePath: String, pythonPath: String, fileManager: FileManager) {
            self.executablePath = executablePath
            self.pythonPath = pythonPath
            self.executableStamp = FileStamp(path: executablePath, fileManager: fileManager)
            self.pythonStamp = FileStamp(path: pythonPath, fileManager: fileManager)
        }
    }

    /// Identity of one file. `attributesOfItem` does not follow symlinks, which
    /// is what we want: a venv's `python3` is a symlink recreated with the venv.
    struct FileStamp: Hashable, Sendable {
        let fileNumber: UInt64
        let size: UInt64
        let modified: TimeInterval

        init?(path: String, fileManager: FileManager) {
            guard let attributes = try? fileManager.attributesOfItem(atPath: path) else { return nil }
            fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
            size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            modified = (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        }
    }

    enum Outcome: Equatable, Sendable {
        case capabilities([String])
        case failed(String)
    }

    private final class InFlight {
        let group = DispatchGroup()
        let generation: Int
        var outcome: Outcome?

        init(generation: Int) {
            self.generation = generation
            group.enter()
        }
    }

    private struct Entry {
        let outcome: Outcome
        let completedAt: Date
    }

    private final class LockedData: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func set(_ value: Data) { lock.lock(); data = value; lock.unlock() }
        func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
    }

    let timeout: TimeInterval
    var onProbeCompleted: (@Sendable () -> Void)?

    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]
    private var inFlight: [Key: InFlight] = [:]
    private var generation = 0
    private var launches = 0
    private var mainThreadLaunches = 0
    private let queue = DispatchQueue(label: "LTX2MLXCapabilityProbe", qos: .utility, attributes: .concurrent)

    init(timeout: TimeInterval = defaultTimeout) {
        self.timeout = timeout
    }

    /// Probe processes launched so far.
    var launchCount: Int { lock.lock(); defer { lock.unlock() }; return launches }
    /// Probe launches that happened on the main thread. Must stay 0.
    var mainThreadLaunchCount: Int { lock.lock(); defer { lock.unlock() }; return mainThreadLaunches }

    /// Non-blocking cache read. `isStale` marks a failure old enough to retry.
    func lookup(_ key: Key, now: Date = Date()) -> (outcome: Outcome?, isStale: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[key] else { return (nil, false) }
        if case .failed = entry.outcome {
            return (entry.outcome, now.timeIntervalSince(entry.completedAt) >= Self.failureRetryInterval)
        }
        return (entry.outcome, false)
    }

    /// Non-blocking: starts a background probe unless one is already running for `key`.
    func startProbeIfNeeded(_ key: Key, script: String) {
        _ = beginOrJoin(key, script: script)
    }

    /// Blocking read for background callers: the cached result, or the result
    /// of the one in-flight probe for `key`. Never call on the main thread.
    func outcome(for key: Key, script: String) -> Outcome {
        let cached = lookup(key)
        if let known = cached.outcome, !cached.isStale { return known }
        let flight = beginOrJoin(key, script: script)
        // The probe itself is bounded by `timeout` plus the kill grace below.
        guard flight.group.wait(timeout: .now() + timeout + 10) == .success else {
            return .failed("the runtime check did not finish")
        }
        lock.lock(); defer { lock.unlock() }
        return flight.outcome ?? .failed("the runtime check did not finish")
    }

    func invalidate() {
        lock.lock()
        generation += 1
        entries.removeAll()
        // Running probes finish on their own but can no longer store a result
        // or absorb a new request: the next request starts a fresh probe.
        inFlight.removeAll()
        lock.unlock()
    }

    private func beginOrJoin(_ key: Key, script: String) -> InFlight {
        lock.lock()
        if let existing = inFlight[key] {
            lock.unlock()
            return existing
        }
        let flight = InFlight(generation: generation)
        inFlight[key] = flight
        lock.unlock()

        queue.async { [self] in
            let result = runProbeProcess(pythonPath: key.pythonPath, script: script)
            lock.lock()
            flight.outcome = result
            if flight.generation == generation {
                entries[key] = Entry(outcome: result, completedAt: Date())
            }
            if inFlight[key] === flight { inFlight[key] = nil }
            let completion = onProbeCompleted
            lock.unlock()
            flight.group.leave()
            completion?()
        }
        return flight
    }

    private func runProbeProcess(pythonPath: String, script: String) -> Outcome {
        lock.lock()
        launches += 1
        let launchNumber = launches
        let onMain = Thread.isMainThread
        if onMain { mainThreadLaunches += 1 }
        lock.unlock()
        #if DEBUG
        print("[LTX2MLXRuntime] capability probe #\(launchNumber) launched (main thread: \(onMain))")
        if onMain { print("[LTX2MLXRuntime] WARNING: capability probe launched on the main thread") }
        #endif

        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = ["-c", script]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return .failed("the runtime's Python could not be started")
        }

        // Drain both pipes while the process runs: a full pipe buffer would
        // block the child, and the wait below would then only end at the timeout.
        let output = LockedData()
        let reads = DispatchGroup()
        reads.enter()
        queue.async {
            output.set(stdout.fileHandleForReading.readDataToEndOfFile())
            reads.leave()
        }
        queue.async {
            _ = stderr.fileHandleForReading.readDataToEndOfFile()
        }

        guard exited.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 2)
            }
            return .failed("the runtime check timed out after \(Int(timeout)) s")
        }
        _ = reads.wait(timeout: .now() + 5)

        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            return .failed("the runtime check exited with status \(process.terminationStatus)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: output.get()) as? [String: Any],
              let caps = json["capabilities"] as? [String] else {
            return .failed("the runtime check returned unreadable output")
        }
        return .capabilities(caps)
    }
}
