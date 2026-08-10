import Foundation

/// One unit of work in the global production queue.
///
/// The queue is deliberately coarse. `GenerationService` already renders one
/// request at a time, and an Auto Movie already chains its own shots, so the
/// thing that was missing was never a second renderer — it was an outer layer
/// that keeps two *movies* from interleaving their shots, survives a relaunch,
/// and remembers what the user asked for at the moment they asked for it.
enum ProductionJobKind: String, Codable, Equatable {
    case generate
    case oneShot
    case storyboard
    case autoMovie

    var displayName: String {
        switch self {
        case .generate: return "Generate"
        case .oneShot: return "One Shot"
        case .storyboard: return "Storyboard"
        case .autoMovie: return "Auto Movie"
        }
    }
}

enum ProductionJobState: String, Codable, Equatable {
    case waiting
    case running
    case completed
    case failed
    case cancelled
    /// The app quit while this job was running. The render subprocess died with
    /// it, so the job is never silently resumed or reported complete.
    case interrupted

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled, .interrupted: return true
        case .waiting, .running: return false
        }
    }

    var displayName: String {
        switch self {
        case .waiting: return "Waiting"
        case .running: return "Running"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        case .interrupted: return "Interrupted"
        }
    }
}

/// What the user asked for, frozen at enqueue time.
///
/// A waiting job must not change because the user kept editing afterwards, so
/// everything the run needs is captured here rather than read live. Images are
/// referenced by project-relative managed path, never copied as bytes — the
/// paths are stable because the managed copies are owned by the project.
struct ProductionJobSnapshot: Codable, Equatable {
    var prompt: String = ""
    var brief: String = ""
    /// Film-project jobs (Storyboard, Auto Movie) point at their project.
    var projectID: UUID?
    var settings: GenerationParameters?
    var modelID: String?
    var textEncoderID: String?
    var preset: String?
    var qualityMode: String?
    var audioEnabled: Bool?
    var targetDurationSeconds: Double?
    var seed: Int?
    var batchCount: Int = 1
    var directorMode: String?
    /// Managed, project-relative. Resolved again at execution time so a file
    /// deleted while the job waited fails the job instead of silently changing
    /// what the movie opens on.
    var openingReferenceRelativePath: String?
    var characterAnchorCharacterID: UUID?
    var characterAnchorAssetID: UUID?
    /// Requests already built by a mode that constructs them up front. Kept
    /// verbatim so a queued job renders exactly what was queued.
    var pendingRequests: [GenerationRequest] = []
}

struct ProductionJob: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var kind: ProductionJobKind
    var title: String
    var state: ProductionJobState = .waiting
    var snapshot: ProductionJobSnapshot
    var createdAt: Date = Date()
    var startedAt: Date?
    var finishedAt: Date?
    /// Why a failed job failed, shown in the queue rather than swallowed.
    var failureReason: String?
    /// Coarse progress for the panel: "Shot 2 / 4", "Generation 3 / 10".
    var progressCurrent: Int?
    var progressTotal: Int?
    var stageDescription: String?
    /// Where the result ended up, so Completed can offer to open it.
    var outputPath: String?

    var progressText: String? {
        if let stageDescription, !stageDescription.isEmpty { return stageDescription }
        guard let progressCurrent, let progressTotal, progressTotal > 0 else { return nil }
        return "\(progressCurrent) / \(progressTotal)"
    }

    /// Actions the queue panel should offer for this job's state.
    var canReorder: Bool { state == .waiting }
    var canCancel: Bool { state == .running || state == .waiting }
    var canRetry: Bool { state == .failed || state == .cancelled }
    var canRestart: Bool { state == .interrupted }
}
