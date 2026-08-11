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

    /// The last film run outcome the render queue could not report. See
    /// `FilmRunEvent` for why watching `$queue` alone is not enough.
    @Published private(set) var lastFilmRunEvent: FilmRunEvent?

    private func emit(_ kind: FilmRunEvent.Kind, projectID: UUID) {
        lastFilmRunEvent = FilmRunEvent(projectID: projectID, kind: kind, at: Date())
    }

    private let historyManager: HistoryManager
    private let bridge = LTXBridge.shared
    private var processingTask: Task<Void, Never>?
    /// Film projects whose run should advance once the current take settles.
    private var completedProjectIDsAwaitingAdvance: Set<UUID> = []
    /// Prevents a second automatic assembly while one is already running.
    private var autoAssemblingProjectIDs: Set<UUID> = []
    
    nonisolated init(historyManager: HistoryManager) {
        self.historyManager = historyManager
    }
    
    // MARK: - Queue Management
    
    func addToQueue(_ request: GenerationRequest) {
        queue.append(requestForQueue(request))
        processNextIfNeeded()
    }
    
    func addBatch(_ requests: [GenerationRequest]) {
        queue.append(contentsOf: requests.map(requestForQueue))
        processNextIfNeeded()
    }

    /// Queue rows must not display stale manual values when a non-Custom
    /// preset is active. Resolve here so every producer (Generate, One Shot,
    /// Storyboard, Hybrid, History) shares the same preflight boundary.
    private func requestForQueue(_ request: GenerationRequest) -> GenerationRequest {
        guard FeatureFlags.isEnabled(.autoQualityV1) else { return request }
        return GenerationSettingsResolver.resolveForPreflight(request: request).request
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
        bridge.cancelActiveGeneration()
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
            var effectiveProfile: QualityProfile?
            var effectiveProfileReason = "Direct request parameters (Auto Quality disabled)"
            if FeatureFlags.isEnabled(.autoQualityV1) {
                let engine = AutoQualityEngine()
                let resolution = try GenerationSettingsResolver.resolve(
                    request: request,
                    engine: engine,
                    snapshot: MemoryMonitor.shared.snapshot()
                )
                effectiveRequest = resolution.request
                effectiveProfile = resolution.profile
                effectiveProfileReason = resolution.reason
                if resolution.profile != nil {
                    autoQualityEngine = engine
                    attemptProfiles = resolution.attemptLadder
                    statusMessage = "Auto Quality: \(resolution.profile!.displayName) — \(resolution.reason)"
                }
            }

            var result: (videoPath: String, seed: Int, enhancedPrompt: String?)
            var attemptIndex = 0
            while true {
                do {
                    let profileID = attemptProfiles.indices.contains(attemptIndex) ? attemptProfiles[attemptIndex].id : nil
                    let attemptStart = Date()
                    Self.logResolvedSettings(
                        effectiveRequest,
                        profile: attemptProfiles.indices.contains(attemptIndex) ? attemptProfiles[attemptIndex] : effectiveProfile,
                        reason: effectiveProfileReason,
                        attempt: attemptIndex + 1
                    )
                    result = try await runGeneration(effectiveRequest)
                    if attemptProfiles.indices.contains(attemptIndex) {
                        effectiveProfile = attemptProfiles[attemptIndex]
                    }
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
                    effectiveRequest = GenerationSettingsResolver.applying(profile: lower, to: request)
                    effectiveProfileReason = "\(effectiveProfileReason); runtime memory fallback to \(lower.id)"
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
            generationResult.preset = request.preset
            generationResult.effectiveProfileID = effectiveProfile?.id
            generationResult.effectiveProfileName = effectiveProfile?.displayName
            generationResult.effectiveProfileReason = effectiveProfileReason
            generationResult.requestedWidth = request.parameters.width
            generationResult.requestedHeight = request.parameters.height
            generationResult.requestedDurationSeconds = request.requestedDurationSeconds
            generationResult.targetDurationSeconds = request.targetDurationSeconds
            generationResult.audioEnabled = !effectiveRequest.disableAudio
            generationResult.generationSource = request.generationSource
            generationResult.filmProjectID = request.filmProjectID
            generationResult.shotID = request.shotID
            generationResult.takeID = request.takeID

            // Save to history
            historyManager.addResult(generationResult)

            // Film project linkage: mark the corresponding take completed.
            if FeatureFlags.isEnabled(.filmProjectV1), generationResult.takeID != nil {
                TakeGenerationCoordinator().recordCompletion(result: generationResult)
                if let projectID = generationResult.filmProjectID {
                    completedProjectIDsAwaitingAdvance.insert(projectID)
                }
            }
            
            // Update queue
            queue[index].status = .completed
            
            let outputDir = URL(fileURLWithPath: generationResult.videoPath).deletingLastPathComponent().path
            statusMessage = "Video saved to \(outputDir)"
            
        } catch where Task.isCancelled {
            recordCancellation(request: request, at: index)
        } catch is CancellationError {
            recordCancellation(request: request, at: index)
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

        // Auto Movie runs advance one shot at a time, so the next shot can only
        // be queued now that this one's output (and its continuity frame) exist.
        advanceFilmProjectRunsIfNeeded()
    }

    /// Continues automatic film-project runs after a take finishes: enqueue the
    /// next shot, or assemble once when the whole run is done. Store access
    /// stays on the main actor; only FFmpeg is moved off it.
    private func advanceFilmProjectRunsIfNeeded() {
        guard FeatureFlags.isEnabled(.filmProjectV1) else {
            completedProjectIDsAwaitingAdvance.removeAll()
            return
        }
        let projectIDs = completedProjectIDsAwaitingAdvance
        completedProjectIDsAwaitingAdvance.removeAll()
        let coordinator = AutoMovieRunCoordinator.shared

        for projectID in projectIDs {
            var pendingRequests: [GenerationRequest] = []
            let step = coordinator.advance(projectID: projectID) { pendingRequests = $0 }
            if !pendingRequests.isEmpty {
                addBatch(pendingRequests)
                continue
            }
            switch step {
            case .assembling:
                startAutoAssembly(projectID: projectID)
            case .idle:
                // Manual storyboards still get one automatic assembly when the
                // last shot lands.
                coordinator.autoSelectUnambiguousTakes(projectID: projectID)
                if let project = FilmProjectStore.shared.project(id: projectID),
                   coordinator.shouldAutoAssemble(project: project) {
                    startAutoAssembly(projectID: projectID)
                } else {
                    emit(.settled, projectID: projectID)
                }
            case .blocked(_, let reason):
                statusMessage = reason.userMessage
                emit(.blocked(reason.userMessage), projectID: projectID)
            case .shotFailed:
                statusMessage = "A shot failed; the movie was not assembled."
                emit(.shotFailed, projectID: projectID)
            default:
                break
            }
        }
    }

    private func startAutoAssembly(projectID: UUID) {
        let coordinator = AutoMovieRunCoordinator.shared
        guard !autoAssemblingProjectIDs.contains(projectID) else { return }
        guard let project = FilmProjectStore.shared.project(id: projectID),
              let signature = coordinator.assemblySignature(for: project) else {
            // Nothing assemblable. Say so, or a caller waiting on assembly —
            // the production queue — waits for an event that never comes.
            emit(.assemblyFailed("The movie could not be assembled."), projectID: projectID)
            return
        }
        let outputPath = coordinator.assemblyOutputPath(projectID: projectID)
        autoAssemblingProjectIDs.insert(projectID)
        statusMessage = "Assembling final movie…"
        Task { [weak self] in
            let outcome: Result<Void, Error> = await Task.detached {
                do {
                    try AutoMovieRunCoordinator.assembleBlocking(project: project, outputPath: outputPath)
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }.value
            guard let self else { return }
            self.autoAssemblingProjectIDs.remove(projectID)
            switch outcome {
            case .success:
                coordinator.recordAssemblySuccess(
                    projectID: projectID, signature: signature, outputPath: outputPath
                )
                self.statusMessage = "Final movie ready: \(outputPath)"
                self.emit(.assembled(path: outputPath), projectID: projectID)
            case .failure(let error):
                self.statusMessage = "Final assembly failed: \(error.localizedDescription)"
                self.emit(.assemblyFailed(error.localizedDescription), projectID: projectID)
            }
        }
    }

    private func recordCancellation(request: GenerationRequest, at index: Int) {
        queue[index].status = .cancelled
        if FeatureFlags.isEnabled(.filmProjectV1), request.takeID != nil {
            TakeGenerationCoordinator().recordCancellation(request: request)
        }
        error = nil
        statusMessage = "Generation cancelled"
    }

    /// Copy of a request with a quality profile applied (parameters + audio).
    /// Prompt, model, IDs and all other fields are preserved.
    nonisolated static func applying(profile: QualityProfile, to request: GenerationRequest) -> GenerationRequest {
        GenerationSettingsResolver.applying(profile: profile, to: request)
    }

    nonisolated static func logResolvedSettings(
        _ request: GenerationRequest,
        profile: QualityProfile?,
        reason: String,
        attempt: Int
    ) {
        let p = request.parameters
        let target = request.targetDurationSeconds.map { String(format: "%.3f", $0) } ?? "none"
        let requested = String(format: "%.3f", request.requestedDurationSeconds)
        print("[ResolvedGenerationSettings] source=\(request.generationSource ?? "unknown") attempt=\(attempt) preset=\(request.preset ?? "none") quality=\(request.qualityMode ?? "none") profile=\(profile?.id ?? "manual") reason=\(reason) width=\(p.width) height=\(p.height) frames=\(p.numFrames) fps=\(p.fps) steps=\(p.numInferenceSteps) audio=\(!request.disableAudio) targetDuration=\(target) requestedDuration=\(requested) model=\(request.modelId) seed=\(p.seed.map(String.init) ?? "random")")
    }
}
