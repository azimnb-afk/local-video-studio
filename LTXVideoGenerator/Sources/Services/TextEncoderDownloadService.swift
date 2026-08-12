import Foundation

/// Explicit, user-initiated download state for the currently selected text
/// encoder. Selecting a different encoder never enters this state on its
/// own — only an explicit download action does.
public enum TextEncoderDownloadState: Equatable {
    case idle
    case downloading(progress: Double?, message: String)
    case succeeded
    case failed(String)
}

public enum TextEncoderDownloadError: Error, Equatable {
    case pythonNotConfigured
    case processFailed(String)

    /// A concise, user-facing message — never a raw Python traceback.
    var message: String {
        switch self {
        case .pythonNotConfigured:
            return "Python is not configured. Open Preferences to set it up."
        case .processFailed(let detail):
            return detail
        }
    }
}

public protocol TextEncoderDownloading {
    /// Downloads `repository` into the standard Hugging Face cache. Never
    /// invoked speculatively — only in direct response to an explicit user
    /// download action. `progressHandler` may be called with `progress: nil`
    /// when a percentage can't be parsed from the underlying tool's output;
    /// callers must not fabricate a percentage in that case.
    func download(
        repository: String,
        progressHandler: @escaping (Double?, String) -> Void
    ) async -> Result<Void, TextEncoderDownloadError>
}

/// Downloads via the same `huggingface_hub` primitive the Python backend
/// already relies on for its own first-use fallback download — this does
/// not introduce a new download engine, just an explicit, standalone way to
/// invoke the existing one outside of a full generation run.
public final class DefaultTextEncoderDownloader: TextEncoderDownloading {
    public init() {}

    public func download(
        repository: String,
        progressHandler: @escaping (Double?, String) -> Void
    ) async -> Result<Void, TextEncoderDownloadError> {
        guard let python = Self.resolvePythonExecutable() else {
            return .failure(.pythonNotConfigured)
        }

        let script = """
        import sys
        from huggingface_hub import snapshot_download
        try:
            snapshot_download(repo_id=\(Self.pythonStringLiteral(repository)))
            print("DOWNLOAD_OK")
        except Exception as e:
            print(f"DOWNLOAD_ERROR: {e}", file=sys.stderr)
            sys.exit(1)
        """

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: python)
                process.arguments = ["-c", script]

                var env: [String: String] = [:]
                let pythonBin = URL(fileURLWithPath: python).deletingLastPathComponent().path
                env["PATH"] = "\(pythonBin):/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
                env["HOME"] = ProcessInfo.processInfo.environment["HOME"] ?? ""
                env["USER"] = ProcessInfo.processInfo.environment["USER"] ?? ""
                env["TMPDIR"] = ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp"
                process.environment = env

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                var lastStderrLine = ""
                var explicitErrorLine: String?
                let lock = NSLock()

                stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
                    for rawLine in chunk.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                        let line = String(rawLine)
                        guard !line.isEmpty else { continue }
                        lock.lock()
                        lastStderrLine = line
                        // The script's own deliberate error marker is far more
                        // useful than whatever trailing line huggingface_hub's
                        // (often multi-line) exception happens to print last.
                        if explicitErrorLine == nil, line.hasPrefix("DOWNLOAD_ERROR: ") {
                            explicitErrorLine = String(line.dropFirst("DOWNLOAD_ERROR: ".count))
                        }
                        lock.unlock()
                        if let (progress, message) = Self.parseProgress(from: line) {
                            progressHandler(progress, message)
                        } else {
                            progressHandler(nil, line.trimmingCharacters(in: .whitespaces))
                        }
                    }
                }

                do {
                    try process.run()
                    process.waitUntilExit()
                    stderrPipe.fileHandleForReading.readabilityHandler = nil

                    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    let stdout = String(data: stdoutData, encoding: .utf8) ?? ""

                    if process.terminationStatus == 0, stdout.contains("DOWNLOAD_OK") {
                        continuation.resume(returning: .success(()))
                    } else {
                        lock.lock()
                        let detail: String
                        if let explicitErrorLine {
                            detail = explicitErrorLine
                        } else if !lastStderrLine.isEmpty {
                            detail = lastStderrLine
                        } else {
                            detail = "Download failed (exit code \(process.terminationStatus))."
                        }
                        lock.unlock()
                        continuation.resume(returning: .failure(.processFailed(detail)))
                    }
                } catch {
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(returning: .failure(.processFailed(error.localizedDescription)))
                }
            }
        }
    }

    /// Mirrors `LTXBridge`'s own saved-path -> executable resolution
    /// (`PythonEnvironment.shared`'s public path helpers), so this uses the
    /// exact same configured Python environment generation already does.
    static func resolvePythonExecutable() -> String? {
        guard let savedPath = UserDefaults.standard.string(forKey: "pythonPath"), !savedPath.isEmpty else {
            return nil
        }
        switch PythonEnvironment.shared.detectPathType(savedPath) {
        case .executable:
            return savedPath
        case .dylib:
            if let exec = PythonEnvironment.shared.dylibToExecutable(savedPath) {
                return exec
            }
            if let home = PythonEnvironment.shared.extractPythonHome(from: savedPath) {
                let standardExec = "\(home)/bin/python3"
                if FileManager.default.isExecutableFile(atPath: standardExec) {
                    return standardExec
                }
            }
            return nil
        case .unknown:
            return FileManager.default.isExecutableFile(atPath: savedPath) ? savedPath : nil
        }
    }

    /// Crude tqdm-style progress parse (e.g. "model.safetensors:  45%|...").
    /// Returns nil when no percentage is present — callers must not invent one.
    static func parseProgress(from line: String) -> (Double, String)? {
        guard let percentIndex = line.firstIndex(of: "%") else { return nil }
        let before = line[..<percentIndex]
        let numberPart: Substring
        if let lastSeparator = before.lastIndex(where: { $0 == " " || $0 == "\t" || $0 == ":" }) {
            numberPart = before[before.index(after: lastSeparator)...]
        } else {
            numberPart = before
        }
        guard let value = Double(numberPart.trimmingCharacters(in: .whitespaces)) else { return nil }
        return (max(0, min(1, value / 100.0)), line.trimmingCharacters(in: .whitespaces))
    }

    private static func pythonStringLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

/// Coordinates an explicit Text Encoder download for the setup UI. Always
/// resolves the *currently* selected encoder at the moment a download is
/// requested — never captures a stale selection from an earlier moment.
@MainActor
public final class TextEncoderDownloadCoordinator: ObservableObject {
    public static let shared = TextEncoderDownloadCoordinator()

    @Published public private(set) var state: TextEncoderDownloadState = .idle

    public var downloader: TextEncoderDownloading
    private var healthManager: DependencyHealthManager
    /// Injectable for testing; defaults to the real Hugging Face cache
    /// checker against `~/.cache/huggingface/hub` (same one everything else
    /// in the app uses).
    private var isCached: (String) -> Bool

    public init(
        downloader: TextEncoderDownloading? = nil,
        healthManager: DependencyHealthManager? = nil,
        isCached: ((String) -> Bool)? = nil
    ) {
        self.downloader = downloader ?? DefaultTextEncoderDownloader()
        self.healthManager = healthManager ?? .shared
        self.isCached = isCached ?? { HuggingFaceCacheChecker.isCached(repository: $0) }
    }

    /// Resets to `.idle` so a freshly-selected encoder doesn't show a stale
    /// failure/progress state left over from a previous encoder's attempt.
    public func resetForNewSelection() {
        if case .downloading = state { return } // don't interrupt an in-flight download
        state = .idle
    }

    public func startDownload() async {
        if case .downloading = state { return }

        let encoderID = UserDefaults.standard.string(forKey: LTXTextEncoderCatalog.selectedTextEncoderIDKey)
            ?? LTXTextEncoderCatalog.defaultTextEncoderID
        let encoder = LTXTextEncoderCatalog.resolvedTextEncoder(id: encoderID)

        guard !encoder.repo.isEmpty else {
            state = .failed("No repository configured for the selected text encoder.")
            return
        }

        // Re-check right before downloading — another process/app run may have
        // already cached it since the setup screen last refreshed.
        if isCached(encoder.repo) {
            state = .succeeded
            await healthManager.refresh()
            return
        }

        state = .downloading(progress: nil, message: "Starting download of \(encoder.repo)…")

        let capturedRepo = encoder.repo
        let result = await downloader.download(repository: capturedRepo) { [weak self] progress, message in
            Task { @MainActor in
                guard let self else { return }
                if case .downloading = self.state {
                    self.state = .downloading(progress: progress, message: message)
                }
            }
        }

        switch result {
        case .success:
            state = .succeeded
        case .failure(let error):
            state = .failed(error.message)
        }

        await healthManager.refresh()
    }

    public func retry() async {
        await startDownload()
    }
}
