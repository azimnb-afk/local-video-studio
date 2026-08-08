import Foundation
import SwiftUI
import Combine

@MainActor
class GenerationService: ObservableObject {
    @Published private(set) var queue: [GenerationRequest] = []
    @Published private(set) var currentRequest: GenerationRequest?
    @Published private(set) var progress: Double = 0
    @Published private(set) var statusMessage: String = ""
    @Published private(set) var isModelLoaded = false
    @Published private(set) var isProcessing = false
    @Published var error: LTXError?
    
    private let historyManager: HistoryManager
    private let bridge = LTXBridge.shared
    private var processingTask: Task<Void, Never>?
    
    nonisolated init(historyManager: HistoryManager) {
        self.historyManager = historyManager
    }
    
    // MARK: - Queue Management
    
    func addToQueue(_ request: GenerationRequest) {
        queue.append(request)
        processNextIfNeeded()
    }
    
    func addBatch(_ requests: [GenerationRequest]) {
        queue.append(contentsOf: requests)
        processNextIfNeeded()
    }
    
    func removeFromQueue(_ request: GenerationRequest) {
        queue.removeAll { $0.id == request.id }
    }
    
    func clearQueue() {
        queue.removeAll { $0.status == .pending }
    }
    
    func clearError() {
        error = nil
        statusMessage = ""
    }
    
    func cancelCurrent() {
        processingTask?.cancel()
        if var request = currentRequest {
            request.status = .cancelled
            currentRequest = nil
        }
        isProcessing = false
        progress = 0
        statusMessage = ""
    }
    
    func moveUp(_ request: GenerationRequest) {
        guard let index = queue.firstIndex(where: { $0.id == request.id }),
              index > 0 else { return }
        queue.swapAt(index, index - 1)
    }
    
    func moveDown(_ request: GenerationRequest) {
        guard let index = queue.firstIndex(where: { $0.id == request.id }),
              index < queue.count - 1 else { return }
        queue.swapAt(index, index + 1)
    }
    
    // MARK: - Model Management
    
    func loadModel() async {
        guard !isModelLoaded else { return }
        
        statusMessage = "Loading model..."
        isProcessing = true
        
        do {
            try await bridge.loadModel { [weak self] message in
                DispatchQueue.main.async {
                    self?.statusMessage = message
                }
            }
            isModelLoaded = bridge.isModelLoaded
            statusMessage = "Model ready"
        } catch let error as LTXError {
            self.error = error
            statusMessage = error.localizedDescription ?? "Unknown error"
        } catch {
            self.error = .modelLoadFailed(error.localizedDescription)
            statusMessage = error.localizedDescription
        }
        
        isProcessing = false
    }
    
    func unloadModel() async {
        await bridge.unloadModel()
        isModelLoaded = bridge.isModelLoaded
        statusMessage = "Model unloaded"
    }
    
    // MARK: - Processing
    
    private func processNextIfNeeded() {
        guard processingTask == nil,
              !isProcessing,
              let nextIndex = queue.firstIndex(where: { $0.status == .pending }) else {
            return
        }
        
        processingTask = Task {
            await processRequest(at: nextIndex)
            processingTask = nil
            processNextIfNeeded()
        }
    }
    
    private func processRequest(at index: Int) async {
        guard index < queue.count else { return }
        
        isProcessing = true
        progress = 0
        
        // Ensure Python packages (including mlx-video-with-audio min version) match the path in Settings — no manual Validate required.
        if let pythonPath = UserDefaults.standard.string(forKey: "pythonPath"), !pythonPath.isEmpty {
            statusMessage = "Checking Python environment..."
            let ensure = await PythonEnvironment.shared.ensureReadyForGeneration(path: pythonPath)
            if !ensure.success {
                queue[index].status = .failed
                error = .generationFailed(ensure.message)
                currentRequest = nil
                isProcessing = false
                progress = 0
                queue.removeAll { $0.status != .pending }
                return
            }
            if let details = ensure.details {
                PythonEnvironment.shared.configureForPythonKit(details: details)
            }
        } else {
            queue[index].status = .failed
            error = .pythonNotConfigured
            currentRequest = nil
            isProcessing = false
            progress = 0
            queue.removeAll { $0.status != .pending }
            return
        }
        
        // Load model if needed
        if !isModelLoaded {
            await loadModel()
            guard isModelLoaded else {
                isProcessing = false
                return
            }
            isProcessing = true
        }
        
        // Update status
        queue[index].status = .processing
        currentRequest = queue[index]
        let request = queue[index]
        let startTime = Date()
        
        // Generate output path - use user preference if set, otherwise default location
        let userOutputDir = UserDefaults.standard.string(forKey: "outputDirectory") ?? ""
        let outputDir: URL
        if userOutputDir.isEmpty {
            outputDir = historyManager.videosDirectory
        } else {
            outputDir = URL(fileURLWithPath: userOutputDir)
            // Ensure directory exists
            try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        }
        let filename = "\(request.id.uuidString).mp4"
        let outputPath = outputDir.appendingPathComponent(filename).path
        
        do {
            let progressCallback: (Double, String) -> Void = { [weak self] prog, message in
                DispatchQueue.main.async {
                    self?.progress = prog
                    self?.statusMessage = message
                }
            }

            var resolvedDescriptor: ModelDescriptor?
            let runGeneration: (GenerationRequest) async throws -> (videoPath: String, seed: Int, enhancedPrompt: String?) = { [bridge] req in
                if FeatureFlags.isEnabled(.modelRegistryV1) {
                    // Registry path: policy + verification enforced at the service
                    // layer, then routed through the adapter boundary. Official
                    // models still end up in the same LTXBridge fast path.
                    let descriptor: ModelDescriptor
                    do {
                        descriptor = try ModelRegistry.shared.validateForGeneration(modelID: req.modelId)
                    } catch let policyError as ModelPolicyError {
                        throw LTXError.generationFailed(policyError.userMessage)
                    }
                    guard let adapter = AdapterRegistry.shared.adapter(for: descriptor) else {
                        throw LTXError.generationFailed("No generation adapter supports model '\(descriptor.id)'.")
                    }
                    resolvedDescriptor = descriptor
                    return try await adapter.generate(
                        request: req,
                        model: descriptor,
                        outputPath: outputPath,
                        progressHandler: progressCallback
                    )
                } else {
                    // Legacy official fast path (all experimental flags OFF).
                    return try await bridge.generate(
                        request: req,
                        outputPath: outputPath,
                        progressHandler: progressCallback
                    )
                }
            }

            // Auto Quality: resolve a concrete profile and a fallback ladder.
            var effectiveRequest = request
            var attemptProfiles: [QualityProfile] = []
            var autoQualityEngine: AutoQualityEngine?
            if FeatureFlags.isEnabled(.autoQualityV1),
               let modeRaw = request.qualityMode,
               let mode = QualityMode(rawValue: modeRaw), mode != .advanced {
                let engine = AutoQualityEngine()
                if let resolution = try? engine.resolve(
                    mode: mode,
                    modelID: request.modelId,
                    snapshot: MemoryMonitor.shared.snapshot(),
                    audioRequested: !request.disableAudio
                ) {
                    autoQualityEngine = engine
                    attemptProfiles = resolution.attemptLadder
                    effectiveRequest = Self.applying(profile: resolution.profile, to: request)
                    statusMessage = "Auto Quality: \(resolution.profile.displayName) — \(resolution.reason)"
                }
            }

            var result: (videoPath: String, seed: Int, enhancedPrompt: String?)
            var attemptIndex = 0
            while true {
                do {
                    let profileID = attemptProfiles.indices.contains(attemptIndex) ? attemptProfiles[attemptIndex].id : nil
                    let attemptStart = Date()
                    result = try await runGeneration(effectiveRequest)
                    if let engine = autoQualityEngine, let profileID {
                        engine.recordOutcome(
                            modelID: request.modelId,
                            profileID: profileID,
                            succeeded: true,
                            wallSeconds: Date().timeIntervalSince(attemptStart)
                        )
                    }
                    break
                } catch {
                    // Fallback ladder: memory-related failures step down one
                    // profile, at most AutoQualityEngine.maxAttempts total. The
                    // backend subprocess has already exited (memory reclaimed).
                    if let engine = autoQualityEngine,
                       attemptProfiles.indices.contains(attemptIndex) {
                        engine.recordOutcome(
                            modelID: request.modelId,
                            profileID: attemptProfiles[attemptIndex].id,
                            succeeded: false
                        )
                    }
                    let nextIndex = attemptIndex + 1
                    guard autoQualityEngine != nil,
                          AutoQualityEngine.isMemoryRelatedFailure(error),
                          nextIndex < attemptProfiles.count,
                          nextIndex < AutoQualityEngine.maxAttempts else {
                        throw error
                    }
                    attemptIndex = nextIndex
                    let lower = attemptProfiles[attemptIndex]
                    effectiveRequest = Self.applying(profile: lower, to: request)
                    statusMessage = "Retrying with lower profile: \(lower.displayName)"
                }
            }

            GenerationFailureRecovery.clearAfterSuccessfulGeneration()
            
            // Create result
            let completedAt = Date()
            var generationResult = GenerationResult(
                id: UUID(),
                requestId: request.id,
                prompt: request.prompt,
                enhancedPrompt: result.enhancedPrompt,
                negativePrompt: request.negativePrompt,
                voiceoverText: request.voiceoverText,
                voiceoverSource: request.voiceoverSource,
                voiceoverVoice: request.voiceoverVoice,
                modelId: request.modelId,
                parameters: effectiveRequest.parameters,
                videoPath: result.videoPath,
                thumbnailPath: nil,
                audioPath: nil,
                musicPath: nil,
                musicGenre: request.musicGenre,
                sourceImagePath: request.sourceImagePath,
                createdAt: request.createdAt,
                completedAt: completedAt,
                duration: completedAt.timeIntervalSince(startTime),
                seed: result.seed
            )

            // Generate thumbnail and update result with path
            if let thumbnailPath = await historyManager.generateThumbnail(for: generationResult) {
                generationResult = GenerationResult(
                    id: generationResult.id,
                    requestId: generationResult.requestId,
                    prompt: generationResult.prompt,
                    enhancedPrompt: generationResult.enhancedPrompt,
                    negativePrompt: generationResult.negativePrompt,
                    voiceoverText: generationResult.voiceoverText,
                    voiceoverSource: generationResult.voiceoverSource,
                    voiceoverVoice: generationResult.voiceoverVoice,
                    modelId: generationResult.modelId,
                    parameters: generationResult.parameters,
                    videoPath: generationResult.videoPath,
                    thumbnailPath: thumbnailPath,
                    audioPath: generationResult.audioPath,
                    musicPath: generationResult.musicPath,
                    musicGenre: generationResult.musicGenre,
                    sourceImagePath: generationResult.sourceImagePath,
                    createdAt: generationResult.createdAt,
                    completedAt: generationResult.completedAt,
                    duration: generationResult.duration,
                    seed: generationResult.seed
                )
            }
            
            // Generate additional audio if requested
            // Note: Unified AV model already includes synchronized audio,
            // but users can still add voiceover or background music on top
            let audioService = AudioService.shared
            
            // Generate voiceover if text is provided
            if request.hasVoiceover {
                let requestModel = LTXModelCatalog.resolvedModel(id: request.modelId)
                let voiceoverNote = requestModel.supportsBuiltInAudio ? " (layering over built-in audio)" : ""
                statusMessage = "Generating voiceover\(voiceoverNote)..."
                do {
                    let source = AudioSource(rawValue: request.voiceoverSource) ?? .mlxAudio
                    generationResult = try await audioService.addAudioToVideo(
                        result: generationResult,
                        text: request.voiceoverText,
                        source: source,
                        voiceId: request.voiceoverVoice,
                        historyManager: historyManager
                    ) { [weak self] prog, msg in
                        DispatchQueue.main.async {
                            self?.statusMessage = msg
                        }
                    }
                } catch {
                    // Log error but don't fail the generation
                    print("Voiceover generation failed: \(error.localizedDescription)")
                }
            }
            
            // Generate music if enabled (duration read from actual video file)
            if request.hasMusic, let genreRaw = request.musicGenre, let genre = MusicGenre(rawValue: genreRaw) {
                statusMessage = "Generating background music..."
                do {
                    generationResult = try await audioService.addMusicToVideo(
                        result: generationResult,
                        genre: genre,
                        historyManager: historyManager
                    ) { [weak self] prog, msg in
                        DispatchQueue.main.async {
                            self?.statusMessage = msg
                        }
                    }
                } catch {
                    // Log error but don't fail the generation
                    print("Music generation failed: \(error.localizedDescription)")
                }
            }
            
            // Director-extension metadata (backward-compatible optional fields).
            // Applied last so intermediate rebuilds (thumbnail, voiceover, music)
            // cannot drop it.
            generationResult.effectiveWidth = (effectiveRequest.parameters.width / 64) * 64
            generationResult.effectiveHeight = (effectiveRequest.parameters.height / 64) * 64
            if let mediaInfo = MediaProbe.probe(path: generationResult.videoPath) {
                generationResult.actualWidth = mediaInfo.width
                generationResult.actualHeight = mediaInfo.height
                generationResult.actualFPS = mediaInfo.fps
                generationResult.actualDuration = mediaInfo.durationSeconds
            }
            generationResult.modelRevision = request.modelRevision ?? resolvedDescriptor?.revision
            generationResult.quantization = request.quantization ?? resolvedDescriptor?.quantization
            generationResult.qualityMode = request.qualityMode
            generationResult.filmProjectID = request.filmProjectID
            generationResult.shotID = request.shotID
            generationResult.takeID = request.takeID

            // Save to history
            historyManager.addResult(generationResult)
            
            // Update queue
            queue[index].status = .completed
            
            let outputDir = URL(fileURLWithPath: generationResult.videoPath).deletingLastPathComponent().path
            statusMessage = "Video saved to \(outputDir)"
            
        } catch is CancellationError {
            queue[index].status = .cancelled
            error = .cancelled
        } catch let err as LTXError {
            queue[index].status = .failed
            error = err
        } catch {
            queue[index].status = .failed
            self.error = .generationFailed(error.localizedDescription)
        }
        
        currentRequest = nil
        isProcessing = false
        progress = 0
        
        // Remove completed/failed/cancelled from queue
        queue.removeAll { $0.status != .pending }

    }

    /// Copy of a request with a quality profile applied (parameters + audio).
    /// Prompt, model, IDs and all other fields are preserved.
    nonisolated static func applying(profile: QualityProfile, to request: GenerationRequest) -> GenerationRequest {
        GenerationRequest(
            id: request.id,
            prompt: request.prompt,
            negativePrompt: request.negativePrompt,
            voiceoverText: request.voiceoverText,
            voiceoverSource: request.voiceoverSource,
            voiceoverVoice: request.voiceoverVoice,
            sourceImagePath: request.sourceImagePath,
            musicEnabled: request.musicEnabled,
            musicGenre: request.musicGenre,
            disableAudio: request.disableAudio || !profile.audioEnabled,
            gemmaRepetitionPenalty: request.gemmaRepetitionPenalty,
            gemmaTopP: request.gemmaTopP,
            modelId: request.modelId,
            textEncoderId: request.textEncoderId,
            parameters: profile.applied(to: request.parameters),
            createdAt: request.createdAt,
            status: request.status,
            modelRevision: request.modelRevision,
            quantization: request.quantization,
            qualityMode: request.qualityMode,
            adultMode: request.adultMode,
            filmProjectID: request.filmProjectID,
            shotID: request.shotID,
            takeID: request.takeID
        )
    }
}
