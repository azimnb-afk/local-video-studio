import Foundation
import Network

/// General-purpose localhost REST API (v1). OpenClaw is just one possible
/// client — the GUI never depends on this server, and the server is a thin
/// adapter over the same services the GUI uses.
///
/// Security: loopback-only bind, installation token auth, no CORS headers,
/// bounded request sizes, asset-ID indirection, max 20 variations, and the
/// single-flight GenerationService (concurrency stays 1).
@MainActor
final class LocalAPIServer: ObservableObject {
    static let shared = LocalAPIServer()

    @Published var isRunning = false
    @Published var port: UInt16 = 8421

    private var listener: NWListener?
    private var generationService: GenerationService?
    private var historyManager: HistoryManager?
    private let tokenStore = APIv1.TokenStore()
    private let assetStore = APIv1.AssetStore()
    /// jobID → request IDs (one per variation).
    private var jobs: [String: [UUID]] = [:]

    var installationToken: String { tokenStore.token }

    func start(generationService: GenerationService, historyManager: HistoryManager) {
        guard !isRunning else { return }
        guard FeatureFlags.isEnabled(.localAPIv1) else { return }
        self.generationService = generationService
        self.historyManager = historyManager
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            // Loopback only: refuse to bind on external interfaces.
            params.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host("127.0.0.1"),
                port: NWEndpoint.Port(rawValue: port)!
            )
            listener = try NWListener(using: params)
            listener?.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready: self?.isRunning = true
                    case .failed, .cancelled: self?.isRunning = false
                    default: break
                    }
                }
            }
            listener?.newConnectionHandler = { [weak self] connection in
                connection.start(queue: .global(qos: .userInitiated))
                self?.receive(connection, buffer: Data())
            }
            listener?.start(queue: .global(qos: .userInitiated))
        } catch {
            print("LocalAPIServer failed to start: \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    // MARK: HTTP plumbing

    private nonisolated func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var accumulated = buffer
            if let data { accumulated.append(data) }
            if accumulated.count > APIv1.maxRequestBytes {
                Self.respond(connection, status: 413, body: ["error": "Request too large"])
                return
            }
            if Self.isRequestComplete(accumulated) {
                Task { @MainActor in
                    self.route(accumulated, connection: connection)
                }
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                self.receive(connection, buffer: accumulated)
            }
        }
    }

    /// Complete when headers are present and the body has Content-Length bytes.
    nonisolated static func isRequestComplete(_ data: Data) -> Bool {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return false }
        guard let head = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) else { return false }
        let contentLength = head
            .components(separatedBy: "\r\n")
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)) } ?? 0
        return data.count - headerEnd.upperBound >= contentLength
    }

    // MARK: Routing

    private func route(_ data: Data, connection: NWConnection) {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) else {
            Self.respond(connection, status: 400, body: ["error": "Malformed request"])
            return
        }
        let lines = head.components(separatedBy: "\r\n")
        let requestParts = lines.first?.components(separatedBy: " ") ?? []
        guard requestParts.count >= 2 else {
            Self.respond(connection, status: 400, body: ["error": "Malformed request line"])
            return
        }
        let method = requestParts[0]
        let path = requestParts[1]
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let colon = line.firstIndex(of: ":") {
                headers[String(line[..<colon]).lowercased()] =
                    String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        let body = data[headerEnd.upperBound...]

        // Token auth on every endpoint.
        guard APIv1.authorize(headerValue: headers["authorization"] ?? headers["x-api-token"],
                              expectedToken: tokenStore.token) else {
            Self.respond(connection, status: 401, body: ["error": "Missing or invalid token"])
            return
        }

        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let reply = handle(method: method, path: path, json: json)
        Self.respond(connection, status: reply.status, body: reply.body)
    }

    func handle(method: String, path: String, json: [String: Any]?) -> APIv1.HTTPReply {
        switch (method, path) {
        case ("POST", "/v1/assets"):
            return handleAssetUpload(json)
        case ("POST", "/v1/jobs"):
            return handleCreateJob(json)
        case ("GET", let p) where p.hasPrefix("/v1/jobs/"):
            return handleGetJob(String(p.dropFirst("/v1/jobs/".count)))
        case ("DELETE", let p) where p.hasPrefix("/v1/jobs/"):
            return handleDeleteJob(String(p.dropFirst("/v1/jobs/".count)))
        case ("GET", "/v1/models"):
            return handleModels()
        case ("GET", "/v1/system"):
            return handleSystem()
        case ("GET", "/v1/history"):
            return handleHistory()
        default:
            return APIv1.HTTPReply(status: 404, body: ["error": "Not found"])
        }
    }

    // MARK: Endpoints

    private func handleAssetUpload(_ json: [String: Any]?) -> APIv1.HTTPReply {
        guard let json, let base64 = json["dataBase64"] as? String else {
            return APIv1.HTTPReply(status: 400, body: ["error": "Expected JSON body with dataBase64"])
        }
        guard let data = Data(base64Encoded: base64) else {
            return APIv1.HTTPReply(status: 400, body: ["error": "dataBase64 is not valid base64"])
        }
        guard data.count <= APIv1.maxAssetBytes else {
            return APIv1.HTTPReply(status: 413, body: ["error": "Asset exceeds \(APIv1.maxAssetBytes) bytes"])
        }
        // PNG/JPEG magic check — this API stores images only.
        let isPNG = data.starts(with: [0x89, 0x50, 0x4E, 0x47])
        let isJPEG = data.starts(with: [0xFF, 0xD8, 0xFF])
        guard isPNG || isJPEG else {
            return APIv1.HTTPReply(status: 415, body: ["error": "Only PNG or JPEG assets are accepted"])
        }
        do {
            let assetID = try assetStore.store(imageData: data)
            return APIv1.HTTPReply(status: 201, body: ["assetID": assetID])
        } catch {
            return APIv1.HTTPReply(status: 500, body: ["error": "Failed to store asset"])
        }
    }

    private func handleCreateJob(_ json: [String: Any]?) -> APIv1.HTTPReply {
        guard let json else {
            return APIv1.HTTPReply(status: 400, body: ["error": "Expected JSON body"])
        }
        guard let generationService else {
            return APIv1.HTTPReply(status: 503, body: ["error": "Generation service unavailable"])
        }
        do {
            let payload = try APIv1.parseJobPayload(json)
            var sourceImagePath: String?
            if let assetID = payload.assetID {
                guard let resolved = assetStore.path(forAssetID: assetID) else {
                    throw APIv1.ValidationError.invalidAssetID
                }
                sourceImagePath = resolved
            }
            let registry = ModelRegistry.shared
            let model = try APIv1.resolveModel(
                payload: payload,
                registry: registry,
                appAdultModeEnabled: registry.adultModeEnabled
            )
            let requests = APIv1.makeRequests(
                payload: payload,
                model: model,
                sourceImagePath: sourceImagePath,
                textEncoderID: LTXTextEncoderCatalog.selectedTextEncoder().id
            )
            let jobID = UUID().uuidString
            jobs[jobID] = requests.map(\.id)
            generationService.addBatch(requests)
            return APIv1.HTTPReply(status: 201, body: [
                "jobID": jobID,
                "requestIDs": requests.map { $0.id.uuidString },
                "model": model.id,
                "variations": requests.count,
                "status": "queued",
            ])
        } catch let error as APIv1.ValidationError {
            let message: String
            switch error {
            case .missingField(let f): message = "Missing required field: \(f)"
            case .invalidValue(let f): message = "Invalid value for: \(f)"
            case .variationsOutOfRange: message = "variations must be 1...\(APIv1.maxVariations)"
            case .unknownTask(let task): message = "Unknown task: \(task)"
            case .i2vRequiresAsset: message = "image_to_video requires input.assetID (upload via POST /v1/assets)"
            case .invalidAssetID: message = "Unknown or invalid assetID"
            case .policyRejected(let reason): message = reason
            }
            let status = { if case .policyRejected = error { return 403 } else { return 400 } }()
            return APIv1.HTTPReply(status: status, body: ["error": message])
        } catch {
            return APIv1.HTTPReply(status: 500, body: ["error": "Internal error"])
        }
    }

    private func handleGetJob(_ jobID: String) -> APIv1.HTTPReply {
        guard let requestIDs = jobs[jobID], let generationService, let historyManager else {
            return APIv1.HTTPReply(status: 404, body: ["error": "Job not found"])
        }
        var items: [[String: Any]] = []
        var completed = 0
        for requestID in requestIDs {
            if let result = historyManager.results.first(where: { $0.requestId == requestID }) {
                completed += 1
                var item: [String: Any] = [
                    "requestID": requestID.uuidString,
                    "state": "completed",
                    "seed": result.seed,
                    "outputPath": result.videoPath,
                    "modelID": result.modelId,
                ]
                if let revision = result.modelRevision { item["modelRevision"] = revision }
                if let quant = result.quantization { item["quantization"] = quant }
                if let w = result.actualWidth { item["actualWidth"] = w }
                if let h = result.actualHeight { item["actualHeight"] = h }
                if let fps = result.actualFPS { item["fps"] = fps }
                if let duration = result.actualDuration { item["duration"] = duration }
                items.append(item)
            } else if generationService.currentRequest?.id == requestID {
                items.append(["requestID": requestID.uuidString, "state": "running",
                              "progress": generationService.progress])
            } else if generationService.queue.contains(where: { $0.id == requestID }) {
                items.append(["requestID": requestID.uuidString, "state": "queued"])
            } else {
                items.append(["requestID": requestID.uuidString, "state": "failed_or_cancelled"])
            }
        }
        let state = completed == requestIDs.count ? "completed"
            : (items.contains { ($0["state"] as? String) == "running" } ? "running" : "queued")
        return APIv1.HTTPReply(status: 200, body: ["jobID": jobID, "state": state, "items": items])
    }

    private func handleDeleteJob(_ jobID: String) -> APIv1.HTTPReply {
        guard let requestIDs = jobs[jobID], let generationService else {
            return APIv1.HTTPReply(status: 404, body: ["error": "Job not found"])
        }
        var cancelled = 0
        for requestID in requestIDs {
            if let request = generationService.queue.first(where: { $0.id == requestID && $0.status == .pending }) {
                generationService.removeFromQueue(request)
                cancelled += 1
            }
        }
        return APIv1.HTTPReply(status: 200, body: ["jobID": jobID, "cancelledPending": cancelled])
    }

    private func handleModels() -> APIv1.HTTPReply {
        let registry = ModelRegistry.shared
        let models = registry.selectableModels().map { model -> [String: Any] in
            [
                "id": model.id,
                "displayName": model.displayName,
                "repository": model.repository,
                "official": model.isOfficial,
                "verified": model.runtime.verified,
                "classification": model.policy.contentClassification.rawValue,
                "quantization": model.quantization ?? "",
                "capabilities": [
                    "textToVideo": model.capabilities.textToVideo,
                    "imageToVideo": model.capabilities.imageToVideo,
                    "audio": model.capabilities.synchronizedAudio,
                ],
            ]
        }
        return APIv1.HTTPReply(status: 200, body: ["models": models, "adultMode": registry.adultModeEnabled])
    }

    private func handleSystem() -> APIv1.HTTPReply {
        let snapshot = MemoryMonitor.shared.snapshot()
        let hardware = HardwareProfiler.current()
        return APIv1.HTTPReply(status: 200, body: [
            "hardware": [
                "model": hardware.modelIdentifier,
                "chip": hardware.chipDescription,
                "memoryGB": hardware.physicalMemoryGB,
                "tier": hardware.memoryTier.rawValue,
            ],
            "memory": [
                "physicalGB": snapshot.physicalGB,
                "availableGB": snapshot.availableGB,
                "swapUsedGB": snapshot.swapUsedGB,
                "thermalState": snapshot.thermalState,
            ],
            "generator": [
                "processing": generationService?.isProcessing ?? false,
                "queueCount": generationService?.queue.count ?? 0,
            ],
        ])
    }

    private func handleHistory() -> APIv1.HTTPReply {
        let results = (historyManager?.results ?? []).prefix(100).map { result -> [String: Any] in
            var item: [String: Any] = [
                "id": result.id.uuidString,
                "prompt": result.prompt,
                "modelID": result.modelId,
                "seed": result.seed,
                "videoPath": result.videoPath,
                "completedAt": ISO8601DateFormatter().string(from: result.completedAt),
            ]
            if let w = result.actualWidth { item["actualWidth"] = w }
            if let h = result.actualHeight { item["actualHeight"] = h }
            if let duration = result.actualDuration { item["duration"] = duration }
            return item
        }
        return APIv1.HTTPReply(status: 200, body: ["history": Array(results)])
    }

    // MARK: Response

    private nonisolated static func respond(_ connection: NWConnection, status: Int, body: [String: Any]) {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 201: statusText = "Created"
        case 400: statusText = "Bad Request"
        case 401: statusText = "Unauthorized"
        case 403: statusText = "Forbidden"
        case 404: statusText = "Not Found"
        case 413: statusText = "Payload Too Large"
        case 415: statusText = "Unsupported Media Type"
        case 503: statusText = "Service Unavailable"
        default: statusText = "Error"
        }
        let jsonData = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
        // Deliberately NO Access-Control-Allow-Origin header (no CORS).
        var response = "HTTP/1.1 \(status) \(statusText)\r\n"
        response += "Content-Type: application/json\r\n"
        response += "Content-Length: \(jsonData.count)\r\n"
        response += "Connection: close\r\n\r\n"
        var payload = Data(response.utf8)
        payload.append(jsonData)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
