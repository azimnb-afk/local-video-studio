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

// MARK: - Film run outcome

/// A film run reaching a state the render queue cannot show.
///
/// Final assembly is why this type exists. It starts *after* the last take has
/// already left the render queue, so the render queue never publishes again.
/// A queue that watches only the renderer therefore waits forever for a movie
/// that finished minutes ago — and every job behind it never starts. The same
/// applies to a run that ends blocked: nothing further is enqueued, so nothing
/// further is published.
struct FilmRunEvent: Equatable {
    enum Kind: Equatable {
        case assembled(path: String)
        case assemblyFailed(String)
        case shotFailed
        case blocked(String)
        /// The run has nothing left to do and needs no assembly.
        case settled
    }

    let projectID: UUID
    let kind: Kind
    let at: Date
}

/// What the production queue should do with the film job it is running.
enum FilmJobProgress: Equatable {
    case running(current: Int, total: Int)
    case assembling
    case completed(outputPath: String)
    case failed(String)
}

/// Decides a film job's fate from the project plus the last thing the run
/// reported.
///
/// Pure and separate from the service so the rule can be checked without a GPU,
/// a renderer, or a main actor — which is what makes "the queue never stalls"
/// something the tests can actually hold the code to.
enum FilmJobDecider {

    static func decide(project: FilmProject, runOutcome: FilmRunEvent.Kind?) -> FilmJobProgress {
        let shots = project.shots
        guard !shots.isEmpty else {
            return .failed("This project has no shots.")
        }

        // A shot that failed with no completed take ends the run: there will be
        // no assembly, so waiting for one would stall the queue.
        let shotFailed = shots.contains { shot in
            shot.takes.contains { $0.status == .failed }
                && shot.selectedTake?.status != .completed
        }
        if shotFailed {
            return .failed("A shot failed; the movie was not assembled.")
        }

        // Rendered, not selected. A take is only *selected* when the whole run
        // ends, so counting selections reports "Shot 1 / N" for the entire
        // movie no matter how many shots have actually landed.
        let rendered = shots.filter { shot in
            shot.takes.contains { $0.status == .completed }
        }.count

        guard rendered == shots.count else {
            // Mid-run. An empty renderer here is not proof of anything: between
            // two shots the queue is momentarily empty while the run advances.
            if case .blocked(let reason)? = runOutcome { return .failed(reason) }
            return .running(current: min(rendered + 1, shots.count), total: shots.count)
        }

        if let assembled = project.assembledMoviePath, !assembled.isEmpty {
            return .completed(outputPath: assembled)
        }
        switch runOutcome {
        case .assemblyFailed(let reason):
            return .failed("Final assembly failed: \(reason)")
        case .settled:
            // The run says it is finished and there is no file. Holding the job
            // open would stall the queue on a movie that will never arrive.
            return .failed("Final assembly failed: the movie was not produced.")
        default:
            // Assembly is genuinely still in flight.
            return .assembling
        }
    }
}
