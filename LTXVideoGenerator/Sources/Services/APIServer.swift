import Foundation
import Network

@MainActor
class APIServer: ObservableObject {
    static let shared = APIServer()
    
    @Published var isRunning = false
    @Published var port: UInt16 = 8420
    
    private var listener: NWListener?
    private var generationServiceRef: GenerationService?
    
    private init() {}
    
    func start(generationService: GenerationService) {
        guard !isRunning else { return }
        
        self.generationServiceRef = generationService
        
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            
            listener?.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        self?.isRunning = true
                        print("API Server running on http://localhost:\(self?.port ?? 8420)")
                    case .failed(let error):
                        print("API Server failed: \(error)")
                        self?.isRunning = false
                    case .cancelled:
                        self?.isRunning = false
                    default:
                        break
                    }
                }
            }
            
            listener?.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    self?.handleConnection(connection)
                }
            }
            
            listener?.start(queue: .global(qos: .userInitiated))
        } catch {
            print("Failed to start API server: \(error)")
        }
    }
    
    func stop() {
        listener?.cancel()
        listener = nil
        generationServiceRef = nil
        isRunning = false
    }
    
    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        receiveRequest(connection)
    }
    
    private func receiveRequest(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            if let data = data, !data.isEmpty {
                Task { @MainActor in
                    self?.processHTTPRequest(data, connection: connection)
                }
            }
            
            if isComplete || error != nil {
                connection.cancel()
            }
        }
    }
    
    private func processHTTPRequest(_ data: Data, connection: NWConnection) {
        guard let generationService = generationServiceRef else {
            sendResponse(connection, status: 500, body: ["error": "Service not available"])
            return
        }
        guard let request = String(data: data, encoding: .utf8) else {
            sendResponse(connection, status: 400, body: ["error": "Invalid request"])
            return
        }
        
        let lines = request.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendResponse(connection, status: 400, body: ["error": "Invalid request"])
            return
        }
        
        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else {
            sendResponse(connection, status: 400, body: ["error": "Invalid request"])
            return
        }
        
        let method = parts[0]
        let path = parts[1]
        
        // Extract body for POST requests
        var body: [String: Any]?
        if method == "POST", let bodyStart = request.range(of: "\r\n\r\n") {
            let bodyString = String(request[bodyStart.upperBound...])
            if let bodyData = bodyString.data(using: .utf8) {
                body = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
            }
        }
        
        // Route requests
        switch (method, path) {
        case ("GET", "/"):
            sendResponse(connection, status: 200, body: [
                "service": "Local Video Studio",
                "version": "1.0.5",
                "endpoints": [
                    "GET /status": "Server and generation status",
                    "GET /queue": "Current generation queue",
                    "POST /generate": "Submit generation request (optional model_id, text_encoder_id)",
                    "DELETE /queue/:id": "Cancel a queued request"
                ]
            ])
            
        case ("GET", "/status"):
            let status: [String: Any] = [
                "server": "running",
                "model_loaded": generationService.isModelLoaded,
                "queue_count": generationService.queue.count,
                "current_progress": generationService.progress
            ]
            sendResponse(connection, status: 200, body: status)
            
        case ("GET", "/queue"):
            let queue = generationService.queue.map { request -> [String: Any] in
                let model = LTXModelCatalog.resolvedModel(id: request.modelId)
                let textEncoder = LTXTextEncoderCatalog.resolvedTextEncoder(id: request.textEncoderId)
                return [
                    "id": request.id.uuidString,
                    "prompt": request.prompt,
                    "status": request.status.rawValue,
                    "created_at": ISO8601DateFormatter().string(from: request.createdAt),
                    "model": [
                        "id": model.id,
                        "repo": model.repo,
                        "display_name": model.displayName,
                    ],
                    "text_encoder": [
                        "id": textEncoder.id,
                        "repo": textEncoder.repo,
                        "display_name": textEncoder.displayName,
                    ],
                    "parameters": [
                        "width": request.parameters.width,
                        "height": request.parameters.height,
                        "num_frames": request.parameters.numFrames,
                        "fps": request.parameters.fps,
                        "num_inference_steps": request.parameters.numInferenceSteps,
                        "guidance_scale": request.parameters.guidanceScale
                    ]
                ]
            }
            sendResponse(connection, status: 200, body: ["queue": queue])
            
        case ("POST", "/generate"):
            guard let body = body,
                  let prompt = body["prompt"] as? String else {
                sendResponse(connection, status: 400, body: ["error": "Missing required field: prompt"])
                return
            }
            
            let negativePrompt = body["negative_prompt"] as? String ?? ""
            let voiceoverText = body["voiceover_text"] as? String ?? ""
            let voiceoverSource = body["voiceover_source"] as? String ?? "mlx-audio"
            let voiceoverVoice = body["voiceover_voice"] as? String ?? "af_heart"
            let musicEnabled = body["music_enabled"] as? Bool ?? false
            let musicGenre = body["music_genre"] as? String
            let qualityMode = (body["quality"] as? String).flatMap(QualityMode.init(rawValue:)) ?? .auto
            let targetDuration = body["duration"] as? Double
            let requestedModelID = body["model_id"] as? String
            let requestedModelRepo = body["model_repo"] as? String
            let requestedTextEncoderID = body["text_encoder_id"] as? String
            let requestedTextEncoderRepo = body["text_encoder_repo"] as? String
            // Resolution goes through the same boundary the app's own
            // workflows use, so an API caller asking for a model this build
            // cannot run gets an error instead of a video quietly generated by
            // a different checkpoint.
            let requestedIdentifier = requestedModelID
                ?? requestedModelRepo.flatMap { LTXModelCatalog.model(repo: $0)?.id }
                ?? LTXModelCatalog.selectedModel().id
            let resolvedModel: LTXModel
            switch GenerationModelResolver.resolve(modelID: requestedIdentifier) {
            case .runnable(let runnable):
                resolvedModel = runnable.model
            case .unsupported(let reason):
                sendResponse(connection, status: 400, body: ["error": reason.userMessage])
                return
            }
            let resolvedTextEncoder: LTXTextEncoder
            if let requestedTextEncoderID, let byID = LTXTextEncoderCatalog.textEncoder(id: requestedTextEncoderID) {
                resolvedTextEncoder = byID
            } else if let requestedTextEncoderRepo, let byRepo = LTXTextEncoderCatalog.textEncoder(repo: requestedTextEncoderRepo) {
                resolvedTextEncoder = byRepo
            } else {
                resolvedTextEncoder = LTXTextEncoderCatalog.selectedTextEncoder()
            }
            
            var params = GenerationParameters.default
            if let p = body["parameters"] as? [String: Any] {
                if let width = p["width"] as? Int { params.width = width }
                if let height = p["height"] as? Int { params.height = height }
                if let numFrames = p["num_frames"] as? Int { params.numFrames = numFrames }
                if let fps = p["fps"] as? Int { params.fps = fps }
                if let steps = p["num_inference_steps"] as? Int { params.numInferenceSteps = steps }
                if let guidance = p["guidance_scale"] as? Double { params.guidanceScale = guidance }
                if let seed = p["seed"] as? Int { params.seed = seed }
            }
            if let targetDuration {
                params.numFrames = PromptCompiler.frameCount(forSeconds: targetDuration, fps: params.fps)
            }
            
            let request = GenerationRequest(
                prompt: prompt,
                negativePrompt: negativePrompt,
                voiceoverText: voiceoverText,
                voiceoverSource: voiceoverSource,
                voiceoverVoice: voiceoverVoice,
                musicEnabled: musicEnabled,
                musicGenre: musicGenre,
                modelId: resolvedModel.id,
                textEncoderId: resolvedTextEncoder.id,
                parameters: params,
                qualityMode: qualityMode.rawValue,
                preset: GenerationPreset.resolving(presetRaw: nil, qualityModeRaw: qualityMode.rawValue).rawValue,
                targetDurationSeconds: targetDuration,
                generationSource: "legacyREST"
            )
            
            generationService.addToQueue(request)
            sendResponse(connection, status: 201, body: [
                "id": request.id.uuidString,
                "status": "queued",
                "model_id": request.modelId,
                "model_repo": resolvedModel.repo,
                "text_encoder_id": request.textEncoderId,
                "text_encoder_repo": resolvedTextEncoder.repo,
                "message": "Generation request added to queue"
            ])
            
        case ("DELETE", _) where path.hasPrefix("/queue/"):
            let idString = String(path.dropFirst("/queue/".count))
            guard let uuid = UUID(uuidString: idString) else {
                sendResponse(connection, status: 400, body: ["error": "Invalid ID format"])
                return
            }
            
            if let request = generationService.queue.first(where: { $0.id == uuid }) {
                generationService.removeFromQueue(request)
                sendResponse(connection, status: 200, body: ["status": "cancelled"])
            } else {
                sendResponse(connection, status: 404, body: ["error": "Request not found"])
            }
            
        default:
            sendResponse(connection, status: 404, body: ["error": "Not found"])
        }
    }
    
    private func sendResponse(_ connection: NWConnection, status: Int, body: [String: Any]) {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 201: statusText = "Created"
        case 400: statusText = "Bad Request"
        case 404: statusText = "Not Found"
        case 500: statusText = "Internal Server Error"
        default: statusText = "Unknown"
        }
        
        let jsonData = (try? JSONSerialization.data(withJSONObject: body, options: .prettyPrinted)) ?? Data()
        let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"
        
        let response = """
        HTTP/1.1 \(status) \(statusText)\r
        Content-Type: application/json\r
        Content-Length: \(jsonData.count)\r
        Access-Control-Allow-Origin: *\r
        Connection: close\r
        \r
        \(jsonString)
        """
        
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
