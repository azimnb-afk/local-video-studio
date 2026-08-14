import Foundation
@testable import LTXVideoGeneratorCore

func runQueueCancellationTests(_ t: TestKit) {

    let tmpRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("LTXTests-cancel-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpRoot) }

    func makeStore(_ name: String) -> ProductionQueueStore {
        ProductionQueueStore(fileURL: tmpRoot.appendingPathComponent("\(name).json"))
    }

    func job(_ kind: ProductionJobKind, _ title: String) -> ProductionJob {
        ProductionJob(kind: kind, title: title, snapshot: ProductionJobSnapshot())
    }

    final class TestRunnerSpy {
        private(set) var startedIDs: [UUID] = []
        var outcome: ProductionQueueCoordinator.StartOutcome = .started

        func run(_ job: ProductionJob) -> ProductionQueueCoordinator.StartOutcome {
            if case .started = outcome {
                startedIDs.append(job.id)
            }
            return outcome
        }
    }

    // MARK: - TEST 1: Waiting Job Cancellation
    t.suite("Waiting Job Cancellation — never executes cancelled jobs") {
        let store = makeStore("waiting-cancel")
        let runner = TestRunnerSpy()
        let coord = ProductionQueueCoordinator(store: store)
        coord.runner = { runner.run($0) }

        let jobA = coord.enqueue(job(.generate, "Job A"))
        let jobB = coord.enqueue(job(.generate, "Job B"))
        let jobC = coord.enqueue(job(.generate, "Job C"))

        t.checkEqual(coord.activeJobID, jobA.id, "Job A is immediately active/running")
        t.checkEqual(runner.startedIDs, [jobA.id], "Only Job A has been started")

        // Cancel Job B while it is waiting
        coord.cancel(jobID: jobB.id)
        store.flush()

        let loadedAfterCancel = store.load()
        let stateB = loadedAfterCancel.first(where: { $0.id == jobB.id })?.state
        t.checkEqual(stateB, .cancelled, "Job B state transitioned to cancelled in store")

        // Complete Job A -> coordinator should skip B and start C
        coord.markCompleted(jobID: jobA.id)

        t.checkEqual(coord.activeJobID, jobC.id, "Coordinator skipped cancelled Job B and started Job C")
        t.checkEqual(runner.startedIDs, [jobA.id, jobC.id], "Job B was never invoked by runner (0 invocations)")

        // Complete Job C
        coord.markCompleted(jobID: jobC.id)
        t.check(coord.activeJobID == nil, "Queue finished all work and is idle")
    }

    // MARK: - TEST 2: Running Job Cancellation
    t.suite("Running Job Cancellation — transitions state and clears active slot") {
        let store = makeStore("running-cancel")
        let runner = TestRunnerSpy()
        let coord = ProductionQueueCoordinator(store: store)
        coord.runner = { runner.run($0) }

        let jobA = coord.enqueue(job(.generate, "Running Job A"))
        t.checkEqual(coord.activeJobID, jobA.id, "Job A is active")
        t.checkEqual(coord.jobs.first?.state, .running, "Job A is in running state")

        // Cancel running Job A
        coord.cancel(jobID: jobA.id)

        t.check(coord.activeJobID == nil, "Active slot cleared after cancelling running job")
        let updatedJobA = coord.jobs.first(where: { $0.id == jobA.id })
        t.checkEqual(updatedJobA?.state, .cancelled, "Job A state marked cancelled")
        t.check(updatedJobA?.finishedAt != nil, "Job A has finishedAt timestamp")
    }

    // MARK: - TEST 3: Cancel Then Next Job Starts
    t.suite("Queue Recovery — cancelling active job immediately advances to next waiting job") {
        let store = makeStore("cancel-next")
        let runner = TestRunnerSpy()
        let coord = ProductionQueueCoordinator(store: store)
        coord.runner = { runner.run($0) }

        let jobA = coord.enqueue(job(.generate, "Job A (to cancel)"))
        let jobB = coord.enqueue(job(.generate, "Job B (to complete)"))

        t.checkEqual(coord.activeJobID, jobA.id, "Job A is running")

        // Cancel Job A
        coord.cancel(jobID: jobA.id)

        t.checkEqual(coord.activeJobID, jobB.id, "Job B immediately became active after Job A cancellation")
        t.checkEqual(runner.startedIDs, [jobA.id, jobB.id], "Both jobs were dispatched sequentially")

        // Complete Job B
        coord.markCompleted(jobID: jobB.id)
        t.check(coord.activeJobID == nil, "Queue idle after Job B completion")
        t.checkEqual(coord.jobs.first(where: { $0.id == jobB.id })?.state, .completed, "Job B completed normally")
    }

    // MARK: - TEST 4: ProcessCancellationTracker — Exact Process Targeting
    t.suite("ProcessCancellationTracker — exact process instance targeting & idempotency") {
        let tracker = ProcessCancellationTracker()

        t.check(!tracker.isCancelled, "Initial state is not cancelled")
        t.check(!tracker.hasActiveProcess, "No initial active process")

        // Calling cancel with no process is safe and returns false
        let cancelledWithoutProc = tracker.cancel()
        t.check(!cancelledWithoutProc, "Cancel on empty tracker returns false")
        t.check(tracker.isCancelled, "Tracker records cancelled intent")

        tracker.reset()
        t.check(!tracker.isCancelled, "Reset clears cancelled flag")

        // Mock Process registration
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["10"]

        try? process.run()
        if process.isRunning {
            tracker.register(process)
            t.check(tracker.hasActiveProcess, "Tracker sees active running process")

            let cancelResult = tracker.cancel()
            t.check(cancelResult, "Cancel returns true for running process")
            t.check(tracker.isCancelled, "Tracker isCancelled is true")

            // Wait briefly for SIGTERM exit
            process.waitUntilExit()
            t.check(!process.isRunning, "Process terminated gracefully via SIGTERM")

            tracker.unregister(process)
            t.check(!tracker.hasActiveProcess, "Unregister clears process reference")
        }
    }

    // MARK: - TEST 5: Race Condition Hardening
    t.suite("Cancellation Race Conditions — double cancel & terminal protection") {
        let store = makeStore("race-conditions")
        let coord = ProductionQueueCoordinator(store: store)
        var runCount = 0
        coord.runner = { _ in runCount += 1; return .started }

        let jobA = coord.enqueue(job(.generate, "Job A"))
        coord.markCompleted(jobID: jobA.id)

        t.checkEqual(coord.jobs.first?.state, .completed, "Job A is completed")

        // Cancel on an already-completed job should be a safe no-op
        coord.cancel(jobID: jobA.id)
        t.checkEqual(coord.jobs.first?.state, .completed, "Completed job remains completed after cancel request")

        // Double cancel on a waiting job
        let jobB = coord.enqueue(job(.generate, "Job B"))
        coord.cancel(jobID: jobB.id)
        t.checkEqual(coord.jobs.first(where: { $0.id == jobB.id })?.state, .cancelled, "First cancel marks cancelled")
        coord.cancel(jobID: jobB.id)
        t.checkEqual(coord.jobs.first(where: { $0.id == jobB.id })?.state, .cancelled, "Second cancel is safe no-op")
    }
}
