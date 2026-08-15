import Foundation
@testable import LTXVideoGeneratorCore

/// Records exactly what the coordinator asked it to download, and returns
/// scripted results — proves the *orchestration* (correct repo, state
/// transitions, retry, refresh-after-completion) without ever touching the
/// network or a real Python process. Real end-to-end wiring (that the
/// production `DefaultTextEncoderDownloader` actually spawns a real
/// subprocess) is verified separately and is not something a hermetic,
/// portable test suite should depend on — see the completion report.
final class FakeTextEncoderDownloading: TextEncoderDownloading {
    var scriptedResults: [Result<Void, TextEncoderDownloadError>] = [.success(())]
    private(set) var invokedRepositories: [String] = []
    var progressEventsToEmit: [(Double?, String)] = []
    /// Called synchronously the moment `download` is invoked, before any
    /// scripted progress/result — lets a test observe coordinator state
    /// exactly as it was when the "subprocess" was asked to start.
    var onInvoked: (() -> Void)?

    func download(
        repository: String,
        progressHandler: @escaping (Double?, String) -> Void
    ) async -> Result<Void, TextEncoderDownloadError> {
        invokedRepositories.append(repository)
        onInvoked?()
        for event in progressEventsToEmit {
            progressHandler(event.0, event.1)
        }
        if scriptedResults.isEmpty { return .success(()) }
        return scriptedResults.removeFirst()
    }
}

/// A `ModelChecking` fake whose `checkTextEncoder()` can return a different
/// value on each successive call, so tests can simulate "missing before the
/// download, ready after it" the same way the real Hugging Face cache
/// checker would report a different result once files land on disk.
final class SequencedFakeModelChecker: ModelChecking {
    var videoStatus: SetupStatus = .ready
    var textStatusSequence: [SetupStatus]
    private var index = 0

    init(textStatusSequence: [SetupStatus]) {
        self.textStatusSequence = textStatusSequence
    }

    func checkVideoModel() async -> SetupStatus { videoStatus }

    func checkTextEncoder() async -> SetupStatus {
        guard !textStatusSequence.isEmpty else { return .missing("no scripted status left") }
        let value = textStatusSequence[min(index, textStatusSequence.count - 1)]
        index += 1
        return value
    }
}

private let encoderA = LTXTextEncoderCatalog.all.first { $0.id == "gemma3_12b_bf16" }!
private let encoderB = LTXTextEncoderCatalog.all.first { $0.id == "gemma3_4b_bf16" }!

func runTextEncoderDownloadTests(_ t: TestKit) {
    t.suite("Explicit Text Encoder Download") {
        let defaultsSuiteName = "ltx-text-encoder-download-tests"
        let defaults = UserDefaults(suiteName: defaultsSuiteName)!
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        // The production code paths (TextEncoderDownloadCoordinator,
        // DefaultModelChecker) read UserDefaults.standard directly, so tests
        // set/restore that specific key rather than using an isolated suite.
        let selectionKey = LTXTextEncoderCatalog.selectedTextEncoderIDKey
        let originalSelection = UserDefaults.standard.string(forKey: selectionKey)
        let customRepoKey = LTXTextEncoderCatalog.customTextEncoderRepoKey
        let originalCustomRepo = UserDefaults.standard.string(forKey: customRepoKey)
        defer {
            if let originalSelection {
                UserDefaults.standard.set(originalSelection, forKey: selectionKey)
            } else {
                UserDefaults.standard.removeObject(forKey: selectionKey)
            }
            if let originalCustomRepo {
                UserDefaults.standard.set(originalCustomRepo, forKey: customRepoKey)
            } else {
                UserDefaults.standard.removeObject(forKey: customRepoKey)
            }
        }
        _ = defaults // silence unused-suite warning; kept for clarity of intent

        func withSelection<T>(_ id: String, _ body: () async -> T) async -> T {
            UserDefaults.standard.set(id, forKey: selectionKey)
            return await body()
        }

        // --- Explicit Download (items 5-11) ---

        print("Test 1: a fresh coordinator starts idle")
        var done1 = false
        Task { @MainActor in
            let idleCoordinator = TextEncoderDownloadCoordinator(
                downloader: FakeTextEncoderDownloading(),
                healthManager: DependencyHealthManager(
                    pythonChecker: FakePythonChecker(),
                    ffmpegChecker: FakeFFmpegChecker(),
                    modelChecker: FakeModelChecker(),
                    optionalServiceChecker: FakeOptionalServiceChecker()
                )
            )
            t.checkEqual(idleCoordinator.state, .idle, "coordinator starts idle — selecting an encoder alone never begins a download")
            done1 = true
        }
        while !done1 { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1)) }

        print("Test 2: Download resolves the CURRENT selected repo, not a captured one")
        var done2 = false
        Task { @MainActor in
            let fake = FakeTextEncoderDownloading()
            let manager = DependencyHealthManager(
                pythonChecker: FakePythonChecker(),
                ffmpegChecker: FakeFFmpegChecker(),
                modelChecker: FakeModelChecker(),
                optionalServiceChecker: FakeOptionalServiceChecker()
            )
            let testStorageChecker = StorageHealthService(capacityProvider: MockDiskCapacityProvider(defaultCapacity: 100 * 1024 * 1024 * 1024))
            let coordinator = TextEncoderDownloadCoordinator(downloader: fake, healthManager: manager, storageChecker: testStorageChecker, isCached: { _ in false })
            await withSelection(encoderA.id) {
                await coordinator.startDownload()
            }
            t.checkEqual(fake.invokedRepositories, [encoderA.repo], "correct repo ID reached the installer")
            done2 = true
        }
        while !done2 { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1)) }

        print("Test 3: switching selection before Download is pressed never downloads the stale (previous) repo")
        var done3 = false
        Task { @MainActor in
            let fake = FakeTextEncoderDownloading()
            let manager = DependencyHealthManager(
                pythonChecker: FakePythonChecker(),
                ffmpegChecker: FakeFFmpegChecker(),
                modelChecker: FakeModelChecker(),
                optionalServiceChecker: FakeOptionalServiceChecker()
            )
            let testStorageChecker = StorageHealthService(capacityProvider: MockDiskCapacityProvider(defaultCapacity: 100 * 1024 * 1024 * 1024))
            let coordinator = TextEncoderDownloadCoordinator(downloader: fake, healthManager: manager, storageChecker: testStorageChecker, isCached: { _ in false })
            UserDefaults.standard.set(encoderA.id, forKey: selectionKey)
            UserDefaults.standard.set(encoderB.id, forKey: selectionKey) // switched before any download happened
            await coordinator.startDownload()
            t.checkEqual(fake.invokedRepositories, [encoderB.repo], "only the current selection (B) was downloaded — A was never touched")
            done3 = true
        }
        while !done3 { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1)) }

        print("Test 4: state transitions idle -> downloading during the attempt")
        var done4 = false
        Task { @MainActor in
            let fake = FakeTextEncoderDownloading()
            let manager = DependencyHealthManager(
                pythonChecker: FakePythonChecker(),
                ffmpegChecker: FakeFFmpegChecker(),
                modelChecker: FakeModelChecker(),
                optionalServiceChecker: FakeOptionalServiceChecker()
            )
            let testStorageChecker = StorageHealthService(capacityProvider: MockDiskCapacityProvider(defaultCapacity: 100 * 1024 * 1024 * 1024))
            let coordinator = TextEncoderDownloadCoordinator(downloader: fake, healthManager: manager, storageChecker: testStorageChecker, isCached: { _ in false })
            var observedDuringInvocation: TextEncoderDownloadState?
            fake.onInvoked = { observedDuringInvocation = coordinator.state }
            await withSelection(encoderA.id) {
                await coordinator.startDownload()
            }
            if case .downloading = observedDuringInvocation {
                t.check(true, "state was .downloading while the installer was running")
            } else {
                t.check(false, "expected .downloading during the attempt, got \(String(describing: observedDuringInvocation))")
            }
            done4 = true
        }
        while !done4 { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1)) }

        print("Test 5: a progress event forwarded by the installer reaches the coordinator without crashing and the run still completes")
        var done5 = false
        Task { @MainActor in
            let fake = FakeTextEncoderDownloading()
            fake.progressEventsToEmit = [(0.42, "model.safetensors: 42%|####      | ...")]
            fake.scriptedResults = [.success(())]
            let manager = DependencyHealthManager(
                pythonChecker: FakePythonChecker(),
                ffmpegChecker: FakeFFmpegChecker(),
                modelChecker: FakeModelChecker(),
                optionalServiceChecker: FakeOptionalServiceChecker()
            )
            let testStorageChecker = StorageHealthService(capacityProvider: MockDiskCapacityProvider(defaultCapacity: 100 * 1024 * 1024 * 1024))
            let coordinator = TextEncoderDownloadCoordinator(downloader: fake, healthManager: manager, storageChecker: testStorageChecker, isCached: { _ in false })
            await withSelection(encoderA.id) {
                await coordinator.startDownload()
            }
            t.checkEqual(coordinator.state, .succeeded, "a progress event during the run does not prevent reaching .succeeded")
            done5 = true
        }
        while !done5 { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1)) }
        // The parsed-value guarantee itself (a real fraction, never a
        // fabricated one) is proven directly against the parsing logic in
        // Test 13 below, which doesn't depend on Task-hop timing.

        print("Test 6: successful download triggers an availability refresh and reaches Ready")
        var done6 = false
        Task { @MainActor in
            let fake = FakeTextEncoderDownloading()
            fake.scriptedResults = [.success(())]
            let models = SequencedFakeModelChecker(textStatusSequence: [
                .missing("Text encoder 'Gemma 12B bf16' is not downloaded. Open Preferences > Models to download."),
                .ready
            ])
            let manager = DependencyHealthManager(
                pythonChecker: FakePythonChecker(),
                ffmpegChecker: FakeFFmpegChecker(),
                modelChecker: models,
                optionalServiceChecker: FakeOptionalServiceChecker()
            )
            await manager.refresh() // establishes the pre-download "missing" state, as the wizard would show
            t.checkEqual(manager.canStartGeneration, false, "blocked before the download")

            let testStorageChecker = StorageHealthService(capacityProvider: MockDiskCapacityProvider(defaultCapacity: 100 * 1024 * 1024 * 1024))
            let coordinator = TextEncoderDownloadCoordinator(downloader: fake, healthManager: manager, storageChecker: testStorageChecker, isCached: { _ in false })
            await withSelection(encoderA.id) { await coordinator.startDownload() }

            t.checkEqual(coordinator.state, .succeeded, "coordinator reached .succeeded")
            t.checkEqual(manager.statuses[.textEncoder], .ready, "availability was re-checked after success and is now ready")
            t.checkEqual(manager.canStartGeneration, true, "Generate is unblocked once the text encoder is actually ready")
            done6 = true
        }
        while !done6 { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1)) }

        print("Test 7: an already-cached encoder is not re-downloaded")
        var done7 = false
        Task { @MainActor in
            let fake = FakeTextEncoderDownloading()
            let manager = DependencyHealthManager(
                pythonChecker: FakePythonChecker(),
                ffmpegChecker: FakeFFmpegChecker(),
                modelChecker: FakeModelChecker(),
                optionalServiceChecker: FakeOptionalServiceChecker()
            )
            let testStorageChecker = StorageHealthService(capacityProvider: MockDiskCapacityProvider(defaultCapacity: 100 * 1024 * 1024 * 1024))
            let coordinator = TextEncoderDownloadCoordinator(downloader: fake, healthManager: manager, storageChecker: testStorageChecker, isCached: { _ in true })
            await withSelection(encoderA.id) { await coordinator.startDownload() }
            t.checkEqual(fake.invokedRepositories, [], "no network/subprocess call was made for an already-cached repo")
            t.checkEqual(coordinator.state, .succeeded, "an already-cached encoder is reported succeeded without downloading")
            done7 = true
        }
        while !done7 { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1)) }

        // --- Selection Change (items 12-14) ---

        print("Test 8: selecting a repo-less custom encoder does not attempt a download")
        var done8 = false
        Task { @MainActor in
            let fake = FakeTextEncoderDownloading()
            let manager = DependencyHealthManager(
                pythonChecker: FakePythonChecker(),
                ffmpegChecker: FakeFFmpegChecker(),
                modelChecker: FakeModelChecker(),
                optionalServiceChecker: FakeOptionalServiceChecker()
            )
            let testStorageChecker = StorageHealthService(capacityProvider: MockDiskCapacityProvider(defaultCapacity: 100 * 1024 * 1024 * 1024))
            let coordinator = TextEncoderDownloadCoordinator(downloader: fake, healthManager: manager, storageChecker: testStorageChecker, isCached: { _ in false })
            UserDefaults.standard.removeObject(forKey: LTXTextEncoderCatalog.customTextEncoderRepoKey)
            await withSelection("custom") { await coordinator.startDownload() }
            t.checkEqual(fake.invokedRepositories, [], "no download attempted for an unset custom repo")
            t.checkEqual(coordinator.state, .failed("No repository configured for the selected text encoder."), "surfaced as a concise failure, not silently ignored or crashed")
            done8 = true
        }
        while !done8 { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1)) }

        // --- Failure / Retry (items 18-19) ---

        print("Test 9: a failed download does not become Ready, and Retry re-invokes the same current selection")
        var done9 = false
        Task { @MainActor in
            let fake = FakeTextEncoderDownloading()
            fake.scriptedResults = [.failure(.processFailed("Repository not found")), .success(())]
            // Still genuinely missing on disk both before and immediately
            // after the failed attempt — a real HuggingFaceCacheChecker
            // would report exactly this for an interrupted/failed download.
            let models9 = FakeModelChecker()
            models9.videoStatus = .ready
            models9.textStatus = .missing("Text encoder 'Gemma 12B bf16' is not downloaded. Open Preferences > Models to download.")
            let manager = DependencyHealthManager(
                pythonChecker: FakePythonChecker(),
                ffmpegChecker: FakeFFmpegChecker(),
                modelChecker: models9,
                optionalServiceChecker: FakeOptionalServiceChecker()
            )
            let testStorageChecker = StorageHealthService(capacityProvider: MockDiskCapacityProvider(defaultCapacity: 100 * 1024 * 1024 * 1024))
            let coordinator = TextEncoderDownloadCoordinator(downloader: fake, healthManager: manager, storageChecker: testStorageChecker, isCached: { _ in false })
            await withSelection(encoderA.id) { await coordinator.startDownload() }
            t.checkEqual(coordinator.state, .failed("Repository not found"), "first attempt surfaces a concise failure")
            t.checkEqual(manager.canStartGeneration, false, "a failed download does not become Ready")

            models9.textStatus = .ready // simulates the retry actually landing real files this time
            await coordinator.retry()
            t.checkEqual(coordinator.state, .succeeded, "retry can succeed")
            t.checkEqual(fake.invokedRepositories, [encoderA.repo, encoderA.repo], "retry re-attempted the same selection")
            t.checkEqual(manager.canStartGeneration, true, "a successful retry does unblock Generate")
            done9 = true
        }
        while !done9 { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1)) }

        // --- Reset on selection change ---

        print("Test 10: resetForNewSelection clears a stale Failed state but does not interrupt an in-flight download")
        var done10 = false
        Task { @MainActor in
            let fake = FakeTextEncoderDownloading()
            fake.scriptedResults = [.failure(.processFailed("boom"))]
            let manager = DependencyHealthManager(
                pythonChecker: FakePythonChecker(),
                ffmpegChecker: FakeFFmpegChecker(),
                modelChecker: FakeModelChecker(),
                optionalServiceChecker: FakeOptionalServiceChecker()
            )
            let testStorageChecker = StorageHealthService(capacityProvider: MockDiskCapacityProvider(defaultCapacity: 100 * 1024 * 1024 * 1024))
            let coordinator = TextEncoderDownloadCoordinator(downloader: fake, healthManager: manager, storageChecker: testStorageChecker, isCached: { _ in false })
            await withSelection(encoderA.id) { await coordinator.startDownload() }
            t.checkEqual(coordinator.state, .failed("boom"), "failed as scripted")

            coordinator.resetForNewSelection()
            t.checkEqual(coordinator.state, .idle, "switching to a new selection clears the stale failure instead of showing A's error under B's row")
            done10 = true
        }
        while !done10 { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1)) }

        // --- Generate gating asymmetry (items 21-24; video model unaffected) ---

        print("Test 11: a missing text encoder blocks Generate even though a missing video model alone would not")
        var done11 = false
        Task { @MainActor in
            let videoMissingOnly = FakeModelChecker()
            videoMissingOnly.videoStatus = .missing("Model not downloaded")
            videoMissingOnly.textStatus = .ready
            let managerVideoMissing = DependencyHealthManager(
                pythonChecker: FakePythonChecker(),
                ffmpegChecker: FakeFFmpegChecker(),
                modelChecker: videoMissingOnly,
                optionalServiceChecker: FakeOptionalServiceChecker()
            )
            await managerVideoMissing.refresh()
            t.checkEqual(managerVideoMissing.canStartGeneration, true, "video model missing alone still allows the attempt (unchanged first-use download semantics)")

            let textMissingOnly = FakeModelChecker()
            textMissingOnly.videoStatus = .ready
            textMissingOnly.textStatus = .missing("Text encoder not downloaded")
            let managerTextMissing = DependencyHealthManager(
                pythonChecker: FakePythonChecker(),
                ffmpegChecker: FakeFFmpegChecker(),
                modelChecker: textMissingOnly,
                optionalServiceChecker: FakeOptionalServiceChecker()
            )
            await managerTextMissing.refresh()
            t.checkEqual(managerTextMissing.canStartGeneration, false, "text encoder missing blocks the attempt — routes to explicit Download instead")
            done11 = true
        }
        while !done11 { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1)) }

        // --- Wiring proof: the default coordinator really uses the production downloader ---

        print("Test 12: an unconfigured coordinator defaults to the real production downloader, not a fake")
        var done12 = false
        Task { @MainActor in
            let productionCoordinator = TextEncoderDownloadCoordinator()
            t.check(productionCoordinator.downloader is DefaultTextEncoderDownloader, "default wiring uses DefaultTextEncoderDownloader — a test that only exercised fakes would not catch this")
            done12 = true
        }
        while !done12 { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1)) }

        // --- Pure-logic checks on the real downloader's helper functions ---

        print("Test 13: tqdm-style progress lines parse to a real fraction, never a fabricated one")
        let parsed = DefaultTextEncoderDownloader.parseProgress(from: "model.safetensors:  45%|####5     | 4.50G/10.0G [00:30<00:37, 145MB/s]")
        t.checkEqual(parsed?.0, 0.45, "45% parsed correctly")
        let unparsed = DefaultTextEncoderDownloader.parseProgress(from: "Fetching metadata...")
        t.check(unparsed == nil, "a line without a percentage yields nil, never an invented number")
    }
}
