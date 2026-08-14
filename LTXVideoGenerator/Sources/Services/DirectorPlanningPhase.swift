import Foundation

/// Discrete, user-explainable phases for Local Director planning.
/// Never displays raw chain-of-thought, `<think>` tokens, or fabricated percentages.
public enum DirectorPlanningPhase: String, Codable, Equatable, Sendable {
    case idle
    case preparing
    case structuredPlanning
    case textProtocolPlanning
    case parsing
    case applying
    case cancelling
    case completed
    case cancelled
    case failed

    public var displayName: String {
        switch self {
        case .idle:
            return "Idle"
        case .preparing:
            return "Preparing Local Director…"
        case .structuredPlanning:
            return "Structured planning…"
        case .textProtocolPlanning:
            return "Trying compatible Text Protocol…"
        case .parsing:
            return "Parsing director plan…"
        case .applying:
            return "Applying storyboard…"
        case .cancelling:
            return "Cancelling…"
        case .completed:
            return "Plan ready"
        case .cancelled:
            return "Planning cancelled"
        case .failed:
            return "Planning failed"
        }
    }

    public var isActive: Bool {
        switch self {
        case .preparing, .structuredPlanning, .textProtocolPlanning, .parsing, .applying, .cancelling:
            return true
        case .idle, .completed, .cancelled, .failed:
            return false
        }
    }
}

/// Thread-safe cancellation and task ownership handle for long-running Director planning.
/// Ensures cancellation intent immediately stops network requests and prevents fallback execution.
public final class DirectorPlanningHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var _isCancelled = false
    private var activeTask: Task<Void, Never>?
    private var activeURLSessionTask: URLSessionTask?

    public init() {}

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isCancelled
    }

    public func cancel() {
        lock.lock()
        _isCancelled = true
        let task = activeTask
        let urlTask = activeURLSessionTask
        lock.unlock()

        task?.cancel()
        urlTask?.cancel()
    }

    public func registerTask(_ task: Task<Void, Never>) {
        lock.lock()
        activeTask = task
        let shouldCancel = _isCancelled
        lock.unlock()

        if shouldCancel {
            task.cancel()
        }
    }

    public func registerURLSessionTask(_ task: URLSessionTask) {
        lock.lock()
        activeURLSessionTask = task
        let shouldCancel = _isCancelled
        lock.unlock()

        if shouldCancel {
            task.cancel()
        }
    }

    public func checkCancellation() throws {
        if isCancelled || Task.isCancelled {
            throw DirectorError.cancelled
        }
    }
}
