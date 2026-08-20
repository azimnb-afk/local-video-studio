import Foundation

/// Stable product identity and renderer-scoped configuration for the MiniMax
/// H3 experimental renderer. Filesystem locations are user configuration,
/// never model identity and never compiled-in machine-specific paths.
enum MiniMaxH3Configuration {
    static let modelID = "minimax_h3_fl2va_2bit_te"
    static let displayName = "MiniMax H3 (Experimental)"
    static let expectedServerModelID = "MiniMax-H3-FL2VA-MLX-Serve-2bit-text-encoder"

    static let modelDirectoryKey = "minimaxH3ModelDirectory"
    static let runtimeExecutablePathKey = "minimaxH3RuntimeExecutablePath"
    static let endpointKey = "minimaxH3Endpoint"
    static let lastReadinessStateKey = "minimaxH3LastReadinessState"
    static let lastReadinessDetailKey = "minimaxH3LastReadinessDetail"
    static let defaultEndpoint = "http://127.0.0.1:11235"

    struct Snapshot: Codable, Equatable {
        var modelDirectory: String?
        var runtimeExecutablePath: String?
        var endpoint: String

        static func current(userDefaults: UserDefaults = .standard) -> Snapshot {
            Snapshot(
                modelDirectory: nonEmpty(userDefaults.string(forKey: modelDirectoryKey)),
                runtimeExecutablePath: nonEmpty(userDefaults.string(forKey: runtimeExecutablePathKey)),
                endpoint: nonEmpty(userDefaults.string(forKey: endpointKey)) ?? defaultEndpoint
            )
        }

        private static func nonEmpty(_ value: String?) -> String? {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    /// H3 must remain local-only. A configurable endpoint is accepted only
    /// when its host is an explicit loopback address.
    static func endpointURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw),
              url.scheme == "http",
              let host = url.host?.lowercased(),
              host == "127.0.0.1" || host == "localhost" || host == "::1",
              url.port != nil else {
            return nil
        }
        return url
    }
}

enum MiniMaxH3RuntimeState: String, Codable, Equatable {
    case notConfigured
    case notRunning
    case starting
    case ready
    case wrongModel
    case broken
}

enum MiniMaxH3ServerOwnership: String, Codable, Equatable {
    case externallyRunning
    case appOwned
}

struct MiniMaxH3RuntimeStatus: Equatable {
    var state: MiniMaxH3RuntimeState
    var ownership: MiniMaxH3ServerOwnership?
    var detail: String
    var loadedModelID: String?

    var isReady: Bool { state == .ready }
}

protocol MiniMaxH3HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

final class MiniMaxH3URLSessionTransport: MiniMaxH3HTTPTransport {
    private let session: URLSession

    init(timeout: TimeInterval = 3_600) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        session = URLSession(configuration: configuration)
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MiniMaxH3Error.invalidHTTPResponse
        }
        return (data, http)
    }
}

enum MiniMaxH3Error: Error, LocalizedError, Equatable {
    case invalidEndpoint
    case runtimeNotConfigured(String)
    case runtimeNotRunning(String)
    case runtimeStartFailed(String)
    case serverUnhealthy(String)
    case wrongModel(expected: String, actual: String?)
    case requestRejected(status: Int, message: String)
    case invalidHTTPResponse
    case malformedResponse(String)
    case invalidBase64(String)
    case invalidFramePayload(expected: Int, actual: Int)
    case invalidAudioPayload(String)
    case invalidSourceImage(String)
    case unsupportedCapability(String)
    case ffmpegUnavailable
    case muxFailed(exitCode: Int, message: String)
    case outputMissing
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "The MiniMax H3 endpoint must be an explicit localhost HTTP URL with a port."
        case .runtimeNotConfigured(let detail): return "MiniMax H3 is not configured. \(detail)"
        case .runtimeNotRunning(let detail): return "MiniMax H3 is not running. \(detail)"
        case .runtimeStartFailed(let detail): return "MiniMax H3 runtime could not start. \(detail)"
        case .serverUnhealthy(let detail): return "MiniMax H3 server is unhealthy. \(detail)"
        case .wrongModel(let expected, let actual):
            let found = actual ?? "none"
            return "MiniMax H3 server has the wrong model loaded (expected \(expected), found \(found))."
        case .requestRejected(let status, let message):
            return "MiniMax H3 request failed with HTTP \(status): \(message)"
        case .invalidHTTPResponse: return "MiniMax H3 returned an invalid HTTP response."
        case .malformedResponse(let detail): return "MiniMax H3 returned malformed JSON. \(detail)"
        case .invalidBase64(let field): return "MiniMax H3 returned invalid base64 data for \(field)."
        case .invalidFramePayload(let expected, let actual):
            return "MiniMax H3 returned an invalid RGB frame payload (expected \(expected) bytes, received \(actual))."
        case .invalidAudioPayload(let detail): return "MiniMax H3 returned invalid PCM audio. \(detail)"
        case .invalidSourceImage(let detail): return "MiniMax H3 could not prepare the starting image. \(detail)"
        case .unsupportedCapability(let detail): return "MiniMax H3 does not support \(detail) in this model pack."
        case .ffmpegUnavailable: return "FFmpeg is required to mux MiniMax H3 video and audio but was not found."
        case .muxFailed(let exitCode, let message): return "MiniMax H3 mux failed with exit code \(exitCode): \(message)"
        case .outputMissing: return "MiniMax H3 completed but no playable MP4 was created."
        case .cancelled: return "MiniMax H3 generation was cancelled."
        }
    }
}

/// Owns only servers launched by this app instance. A compatible server that
/// was already listening is reused and is never terminated by app cleanup.
final class MiniMaxH3RuntimeManager: @unchecked Sendable {
    static let shared = MiniMaxH3RuntimeManager()

    private let lock = NSLock()
    private var ownedProcess: Process?
    private var ownedEndpoint: String?
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func status(
        snapshot: MiniMaxH3Configuration.Snapshot,
        transport: MiniMaxH3HTTPTransport = MiniMaxH3URLSessionTransport(timeout: 8)
    ) async -> MiniMaxH3RuntimeStatus {
        guard let baseURL = MiniMaxH3Configuration.endpointURL(snapshot.endpoint) else {
            return MiniMaxH3RuntimeStatus(
                state: .broken, ownership: nil,
                detail: MiniMaxH3Error.invalidEndpoint.localizedDescription,
                loadedModelID: nil)
        }

        do {
            var healthRequest = URLRequest(url: baseURL.appendingPathComponent("health"))
            healthRequest.httpMethod = "GET"
            let (healthData, healthResponse) = try await transport.data(for: healthRequest)
            guard (200..<300).contains(healthResponse.statusCode),
                  let health = try? JSONSerialization.jsonObject(with: healthData) as? [String: Any],
                  (health["status"] as? String)?.lowercased() == "ok" else {
                return MiniMaxH3RuntimeStatus(
                    state: .broken, ownership: ownership(for: snapshot.endpoint),
                    detail: "The /health check did not report ok.", loadedModelID: nil)
            }

            var modelsRequest = URLRequest(url: baseURL.appendingPathComponent("v1/models"))
            modelsRequest.httpMethod = "GET"
            let (modelsData, modelsResponse) = try await transport.data(for: modelsRequest)
            guard (200..<300).contains(modelsResponse.statusCode),
                  let object = try? JSONSerialization.jsonObject(with: modelsData) else {
                return MiniMaxH3RuntimeStatus(
                    state: .broken, ownership: ownership(for: snapshot.endpoint),
                    detail: "The /v1/models response was unreadable.", loadedModelID: nil)
            }

            let models = Self.modelEntries(from: object)
            if let exact = models.first(where: { $0.id == MiniMaxH3Configuration.expectedServerModelID }) {
                if exact.isReady {
                    return MiniMaxH3RuntimeStatus(
                        state: .ready, ownership: ownership(for: snapshot.endpoint),
                        detail: "Ready", loadedModelID: exact.id)
                }
                return MiniMaxH3RuntimeStatus(
                    state: .starting, ownership: ownership(for: snapshot.endpoint),
                    detail: "The expected model is still loading.", loadedModelID: exact.id)
            }
            return MiniMaxH3RuntimeStatus(
                state: .wrongModel, ownership: ownership(for: snapshot.endpoint),
                detail: "A server is healthy, but the expected H3 model is not ready.",
                loadedModelID: models.first?.id)
        } catch {
            let configured = snapshot.modelDirectory != nil && snapshot.runtimeExecutablePath != nil
            return MiniMaxH3RuntimeStatus(
                state: configured ? .notRunning : .notConfigured,
                ownership: nil,
                detail: configured
                    ? "No MiniMax H3 server is listening at the configured endpoint."
                    : "Set the H3 model directory and mlx-serve executable, or start a compatible external server.",
                loadedModelID: nil)
        }
    }

    func ensureReady(
        snapshot: MiniMaxH3Configuration.Snapshot,
        progress: @escaping (Double, String) -> Void = { _, _ in }
    ) async throws -> MiniMaxH3RuntimeStatus {
        let initial = await status(snapshot: snapshot)
        if initial.isReady { return initial }
        if initial.state == .wrongModel {
            throw MiniMaxH3Error.wrongModel(
                expected: MiniMaxH3Configuration.expectedServerModelID,
                actual: initial.loadedModelID)
        }
        if initial.state == .broken || initial.state == .starting {
            throw MiniMaxH3Error.serverUnhealthy(initial.detail)
        }
        guard MiniMaxH3Configuration.endpointURL(snapshot.endpoint) != nil else {
            throw MiniMaxH3Error.invalidEndpoint
        }
        guard let runtime = snapshot.runtimeExecutablePath,
              fileManager.isExecutableFile(atPath: runtime) else {
            throw MiniMaxH3Error.runtimeNotConfigured("Select an executable mlx-serve runtime.")
        }
        guard let model = snapshot.modelDirectory,
              directoryExists(model) else {
            throw MiniMaxH3Error.runtimeNotConfigured("Select the local MiniMax H3 model directory.")
        }

        try startOwnedServer(runtime: runtime, model: model, endpoint: snapshot.endpoint)
        progress(0.01, "Starting the MiniMax H3 local server…")

        do {
            for _ in 0..<300 {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 1_000_000_000)
                let current = await status(snapshot: snapshot)
                if current.isReady { return current }
                if current.state == .wrongModel {
                    stopOwnedServer()
                    throw MiniMaxH3Error.wrongModel(
                        expected: MiniMaxH3Configuration.expectedServerModelID,
                        actual: current.loadedModelID)
                }
                if !ownedServerIsRunning {
                    throw MiniMaxH3Error.runtimeStartFailed("The mlx-serve process exited before becoming ready.")
                }
            }
        } catch is CancellationError {
            stopOwnedServer()
            throw MiniMaxH3Error.cancelled
        }
        stopOwnedServer()
        throw MiniMaxH3Error.runtimeStartFailed("Timed out while loading the configured model.")
    }

    func stopOwnedServer() {
        lock.lock()
        let process = ownedProcess
        ownedProcess = nil
        ownedEndpoint = nil
        lock.unlock()
        if let process, process.isRunning {
            process.terminate()
        }
    }

    private var ownedServerIsRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ownedProcess?.isRunning == true
    }

    private func ownership(for endpoint: String) -> MiniMaxH3ServerOwnership {
        lock.lock()
        defer { lock.unlock() }
        if ownedEndpoint == endpoint, ownedProcess?.isRunning == true { return .appOwned }
        return .externallyRunning
    }

    private func startOwnedServer(runtime: String, model: String, endpoint: String) throws {
        guard let url = MiniMaxH3Configuration.endpointURL(endpoint), let port = url.port else {
            throw MiniMaxH3Error.invalidEndpoint
        }
        lock.lock()
        if let existing = ownedProcess, existing.isRunning {
            lock.unlock()
            return
        }
        lock.unlock()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: runtime)
        process.arguments = Self.serverArguments(modelDirectory: model, port: port)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw MiniMaxH3Error.runtimeStartFailed(error.localizedDescription)
        }
        lock.lock()
        ownedProcess = process
        ownedEndpoint = endpoint
        lock.unlock()
    }

    static func serverArguments(modelDirectory: String, port: Int) -> [String] {
        [
            "--model", modelDirectory,
            "--serve",
            "--host", "127.0.0.1",
            "--port", String(port),
            "--timeout", "0",
        ]
    }

    private func directoryExists(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private struct ModelEntry {
        var id: String
        var isReady: Bool
    }

    private static func modelEntries(from object: Any) -> [ModelEntry] {
        let dictionaries: [[String: Any]]
        if let root = object as? [String: Any], let data = root["data"] as? [[String: Any]] {
            dictionaries = data
        } else if let array = object as? [[String: Any]] {
            dictionaries = array
        } else if let root = object as? [String: Any] {
            dictionaries = [root]
        } else {
            dictionaries = []
        }
        return dictionaries.compactMap { entry in
            guard let id = (entry["id"] ?? entry["model"] ?? entry["name"]) as? String else { return nil }
            let loaded = entry["loaded"] as? Bool ?? true
            let state = (entry["state"] as? String)?.lowercased()
            let ready = entry["ready"] as? Bool ?? (state == nil || state == "ready")
            return ModelEntry(id: id, isReady: loaded && ready)
        }
    }
}
