import Foundation

public enum SetupStatus: Equatable {
    case checking
    case ready
    case missing(String)
    case invalid(String)
    case unsupported(String)

    /// Only `.ready` is generation-safe. A missing model is a setup action,
    /// not a reason to start a generation that would unexpectedly download
    /// many gigabytes in the background.
    var allowsGenerationAttempt: Bool {
        switch self {
        case .ready:
            return true
        case .missing, .checking, .invalid, .unsupported:
            return false
        }
    }
}

public enum SetupRequirement: String, CaseIterable, Hashable {
    case python
    case ffmpeg
    case videoModel
    case textEncoder
    case localDirector
    case vision
    
    public var isRequired: Bool {
        switch self {
        case .python, .ffmpeg, .videoModel, .textEncoder:
            return true
        case .localDirector, .vision:
            return false
        }
    }
    
    public var displayName: String {
        switch self {
        case .python: return "Python Environment"
        case .ffmpeg: return "FFmpeg"
        case .videoModel: return "Video Model"
        case .textEncoder: return "Text Encoder"
        case .localDirector: return "Local Director (Ollama)"
        case .vision: return "Character Sheet Analysis"
        }
    }
}

public protocol PythonChecking {
    func check() async -> SetupStatus
}

public protocol FFmpegChecking {
    func check() async -> SetupStatus
}

public protocol ModelChecking {
    func checkVideoModel() async -> SetupStatus
    func checkTextEncoder() async -> SetupStatus
}

public protocol OptionalServiceChecking {
    func checkLocalDirector() async -> SetupStatus
    func checkVision() async -> SetupStatus
}

@MainActor
public class DependencyHealthManager: ObservableObject {
    public static let shared = DependencyHealthManager()
    
    @Published public private(set) var statuses: [SetupRequirement: SetupStatus] = [
        .python: .checking,
        .ffmpeg: .checking,
        .videoModel: .checking,
        .textEncoder: .checking,
        .localDirector: .checking,
        .vision: .checking
    ]
    
    /// Selected == Installed/Available == Ready for every requirement,
    /// including a text encoder / video model that is already downloaded.
    /// Used for the setup dashboard's own "fully ready" display, not for
    /// gating whether a generation attempt may start (see `canStartGeneration`).
    @Published public private(set) var isGenerationReady: Bool = false

    /// True when a generation attempt may be started.
    ///
    /// Missing model files must be prepared explicitly from Settings. This
    /// keeps generation from becoming an implicit download workflow for either
    /// the video model or its text encoder.
    @Published public private(set) var canStartGeneration: Bool = false

    @Published public private(set) var isChecking: Bool = false
    
    @Published public var showSetupWizard: Bool = false
    
    // Injectable dependencies for testing
    public var pythonChecker: PythonChecking
    public var ffmpegChecker: FFmpegChecking
    public var modelChecker: ModelChecking
    public var optionalServiceChecker: OptionalServiceChecking
    
    public init(
        pythonChecker: PythonChecking? = nil,
        ffmpegChecker: FFmpegChecking? = nil,
        modelChecker: ModelChecking? = nil,
        optionalServiceChecker: OptionalServiceChecking? = nil
    ) {
        // Will inject defaults in a moment
        self.pythonChecker = pythonChecker ?? DefaultPythonChecker()
        self.ffmpegChecker = ffmpegChecker ?? DefaultFFmpegChecker()
        self.modelChecker = modelChecker ?? DefaultModelChecker()
        self.optionalServiceChecker = optionalServiceChecker ?? DefaultOptionalServiceChecker()
    }
    
    public func refresh() async {
        isChecking = true

        let usesH3 = GenerationModelResolver.backend(
            for: UserDefaults.standard.string(forKey: LTXModelCatalog.selectedModelIDKey)
        ) == .minimaxH3
        
        // Timeout each task to 10 seconds to avoid permanent spinners
        async let pythonTask = usesH3
            ? SetupStatus.ready
            : (runWithTimeout(seconds: 15) { await self.pythonChecker.check() } ?? .invalid("Python check timed out"))
        async let ffmpegTask = runWithTimeout(seconds: 5) { await self.ffmpegChecker.check() } ?? .invalid("FFmpeg check timed out")
        async let videoModelTask = runWithTimeout(seconds: 5) { await self.modelChecker.checkVideoModel() } ?? .invalid("Model check timed out")
        async let textEncoderTask = usesH3
            ? SetupStatus.ready
            : (runWithTimeout(seconds: 5) { await self.modelChecker.checkTextEncoder() } ?? .invalid("Encoder check timed out"))
        async let directorTask = runWithTimeout(seconds: 5) { await self.optionalServiceChecker.checkLocalDirector() } ?? .missing("Ollama check timed out")
        async let visionTask = runWithTimeout(seconds: 5) { await self.optionalServiceChecker.checkVision() } ?? .missing("Vision check timed out")
        
        let pythonStatus = await pythonTask
        let ffmpegStatus = await ffmpegTask
        let videoModelStatus = await videoModelTask
        let textEncoderStatus = await textEncoderTask
        let directorStatus = await directorTask
        let visionStatus = await visionTask
        
        self.statuses = [
            .python: pythonStatus,
            .ffmpeg: ffmpegStatus,
            .videoModel: videoModelStatus,
            .textEncoder: textEncoderStatus,
            .localDirector: directorStatus,
            .vision: visionStatus
        ]

        self.isGenerationReady =
            pythonStatus == .ready &&
            ffmpegStatus == .ready &&
            videoModelStatus == .ready &&
            textEncoderStatus == .ready

        self.canStartGeneration =
            pythonStatus == .ready &&
            ffmpegStatus == .ready &&
            videoModelStatus == .ready &&
            textEncoderStatus == .ready

        isChecking = false
    }
    
    private func runWithTimeout<T>(seconds: TimeInterval, operation: @escaping () async -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask {
                return await operation()
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }
}
