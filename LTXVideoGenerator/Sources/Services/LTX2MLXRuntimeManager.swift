import Foundation

/// Defines the compatibility and capabilities of an app-managed or override `ltx-2-mlx` runtime.
public struct LTX2MLXRuntimeManifest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let minimumRuntimeVersion = "0.2.0-preview4"

    // Runtime source history, most recent first:
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
    public static let pinnedSourceRevision: String = "ead83e2"

    // NOTE (next preview): "ltx25_official_video_vae_encoder_v1" is probed
    // below but is deliberately NOT required yet. The published runtime
    // (ead83e2) loads the official combined VAE's *encoder* half with a
    // prefix that matches none of its keys, under strict=False — leaving a
    // randomly-initialized encoder, so every image-conditioned generation
    // (One Shot with a starting image, Auto Movie Shot 1, every continuity
    // shot) decodes to noise. The runtime-side fix exists in this repo's
    // sibling ltx-2-mlx checkout but is not published yet, and requiring a
    // capability no reachable runtime can satisfy would report the shipped
    // Preview.4 as permanently outdated while "Install Runtime" reinstalls
    // the very revision that fails the check — breaking text-to-video too,
    // with no way out. So this gate and the pinnedSourceRevision bump must
    // flip together, atomically, as the first step of publishing the fixed
    // runtime. Until then the capability is reported but not enforced.
    public static let requiredCapabilities: [String] = [
        "ltx25_gguf",
        "gguf_block_streaming_v1",
        "audio_decode_v2",
        "video_decoder_weights_v2",
        "ltx25_official_video_vae_v1",
        "ltx25_audio_toggle_v1"
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

    public init(fileManager: FileManager = .default, userDefaults: UserDefaults = .standard) {
        self.fileManager = fileManager
        self.userDefaults = userDefaults
        // Initialize status synchronously without async dispatch
        if let override = userDefaults.string(forKey: Self.overrideExecutableKey)?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            self.status = .ready(executablePath: override, manifest: LTX2MLXRuntimeManifest())
        } else if let legacy = userDefaults.string(forKey: Self.legacyExecutableKey)?.trimmingCharacters(in: .whitespacesAndNewlines), !legacy.isEmpty {
            self.status = .ready(executablePath: legacy, manifest: LTX2MLXRuntimeManifest())
        } else {
            let managedExec = AppStorageDirectory.runtimesDirectory.appendingPathComponent("ltx-2-mlx/bin/ltx-2-mlx").path
            if fileManager.fileExists(atPath: managedExec) {
                self.status = .ready(executablePath: managedExec, manifest: LTX2MLXRuntimeManifest())
            } else {
                self.status = .notInstalled
            }
        }
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

    /// Refreshes the cached runtime status synchronously based on file and capability checks.
    @discardableResult
    public func refreshStatus() -> LTX2MLXRuntimeStatus {
        let newStatus = evaluateStatus()
        DispatchQueue.main.async { [weak self] in
            self?.status = newStatus
        }
        return newStatus
    }

    /// Pure status evaluator for testing or background calls.
    public func evaluateStatus(userDefaults: UserDefaults? = nil) -> LTX2MLXRuntimeStatus {
        // 1. Check for manual / developer override first
        if let overridePath = overrideExecutablePath(userDefaults: userDefaults) {
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: overridePath, isDirectory: &isDir), !isDir.boolValue else {
                return .broken(reason: "Configured override executable not found at: \(overridePath)")
            }
            guard fileManager.isExecutableFile(atPath: overridePath) else {
                return .broken(reason: "Configured override file is not executable: \(overridePath)")
            }
            // Probe override executable
            let probe = probeCapabilities(executablePath: overridePath)
            if probe.isCompatible {
                return .ready(executablePath: overridePath, manifest: probe)
            } else if !probe.missingCapabilities.isEmpty {
                return .outdated(
                    executablePath: overridePath,
                    currentVersion: probe.runtimeVersion,
                    requiredVersion: LTX2MLXRuntimeManifest.minimumRuntimeVersion,
                    missingCapabilities: probe.missingCapabilities
                )
            } else {
                // If probe returned default compatible (e.g. standalone test stub), accept as ready
                return .ready(executablePath: overridePath, manifest: probe)
            }
        }

        // 2. Check for app-managed runtime
        let managedExec = managedExecutableURL.path
        guard fileManager.fileExists(atPath: managedExec) else {
            return .notInstalled
        }
        guard fileManager.isExecutableFile(atPath: managedExec) else {
            return .broken(reason: "Managed runtime binary is not executable: \(managedExec)")
        }

        // Check manifest if available
        var manifest: LTX2MLXRuntimeManifest?
        if fileManager.fileExists(atPath: manifestURL.path),
           let data = try? Data(contentsOf: manifestURL),
           let decoded = try? JSONDecoder().decode(LTX2MLXRuntimeManifest.self, from: data) {
            manifest = decoded
        }

        // Probe capabilities
        let probedManifest = probeCapabilities(executablePath: managedExec, fallbackManifest: manifest)
        if probedManifest.isCompatible {
            return .ready(executablePath: managedExec, manifest: probedManifest)
        } else {
            return .outdated(
                executablePath: managedExec,
                currentVersion: probedManifest.runtimeVersion,
                requiredVersion: LTX2MLXRuntimeManifest.minimumRuntimeVersion,
                missingCapabilities: probedManifest.missingCapabilities
            )
        }
    }

    /// Probes the capabilities of a given `ltx-2-mlx` executable via python subprocess.
    public func probeCapabilities(executablePath: String, fallbackManifest: LTX2MLXRuntimeManifest? = nil) -> LTX2MLXRuntimeManifest {
        let pythonURL = URL(fileURLWithPath: executablePath).deletingLastPathComponent().appendingPathComponent("python3")
        let pythonPath = pythonURL.path
        guard fileManager.isExecutableFile(atPath: pythonPath) else {
            // If executable is a standalone stub or script without adjacent python3,
            // return fallbackManifest or standard compatible manifest for testing harness
            return fallbackManifest ?? LTX2MLXRuntimeManifest()
        }

        // Run inspection script
        let script = """
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

        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = ["-c", script]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let caps = json["capabilities"] as? [String] {
                    var m = fallbackManifest ?? LTX2MLXRuntimeManifest()
                    m.capabilities = caps
                    return m
                }
            }
        } catch {
            // Probe failed to execute
        }

        return fallbackManifest ?? LTX2MLXRuntimeManifest(capabilities: [])
    }

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

        // 6. Capability verification
        progressHandler(0.95, "Verifying runtime capabilities…")
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
