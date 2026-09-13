import Foundation
import CryptoKit
@testable import LTXVideoGeneratorCore

/// Opt-in acceptance probe for the Auto Movie Opening Reference.
///
/// The hermetic suites in `MovieRunTests` build their own `FilmProject` in
/// memory. That proves the logic, but it cannot prove that a project the app
/// actually wrote to disk — with a real managed Opening Reference asset and a
/// real compiled prompt — freezes the way the user expects. This probe closes
/// that gap by running the *production* submission path
/// (`MovieRunSubmission.makeJob`) against a real profile directory.
///
/// It is read-only: the store is opened on the real Projects directory, and
/// `makeJob` neither writes nor enqueues. Nothing is added to the user's queue.
///
/// Opt-in, like `--probe-director-cancellation-acceptance`, because it depends
/// on machine-local state that CI does not have. It skips (never fails) when
/// the profile or a suitable project is absent.
///
/// Run:
///   swift run LTXTests --probe-opening-reference-acceptance
///   swift run LTXTests --probe-opening-reference-acceptance --profile personal
func runRealOpeningReferenceAcceptanceProbe(_ t: TestKit) {
    t.suite("REAL PROFILE ACCEPTANCE — Auto Movie Opening Reference reaches every work") {

        // Dev by default: the probe must never reach into Personal unless the
        // operator says so explicitly.
        let args = CommandLine.arguments
        let profileFolder: String = {
            guard let i = args.firstIndex(of: "--profile"), i + 1 < args.count else {
                return "LocalVideoStudioDev"
            }
            return args[i + 1] == "personal" ? "LocalVideoStudio" : "LocalVideoStudioDev"
        }()

        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let projectsDirectory = support
            .appendingPathComponent(profileFolder)
            .appendingPathComponent("Projects")

        guard FileManager.default.fileExists(atPath: projectsDirectory.path) else {
            print("⚠️ [SKIP] No \(profileFolder) profile on this machine.")
            return
        }

        let store = FilmProjectStore(projectsDirectory: projectsDirectory)

        // Newest project that actually carries an Opening Reference and shots:
        // that is the shape this probe exists to check.
        let candidates = store.projects.values
            .filter { $0.openingReferenceImage != nil && !$0.shots.isEmpty }
            .sorted { $0.updatedAt > $1.updatedAt }

        guard let project = candidates.first else {
            print("⚠️ [SKIP] No project in \(profileFolder) has an Opening Reference and shots.")
            return
        }

        guard let reference = project.openingReferenceImage else { return }
        let relativePath = reference.projectRelativePath

        print("🎬 [PROBE] project=\(project.id) title=\(project.title)")
        print("🎬 [PROBE] shots=\(project.shots.count) openingReference=\(relativePath)")

        // The bytes the user actually chose, as they sit on disk right now.
        guard let absolute = MovieRunRequestBuilder.resolveFrozenAssetPath(
            relativePath, projectID: project.id, store: store),
              let referenceData = FileManager.default.contents(atPath: absolute) else {
            t.check(false, "REAL_OPENING_REFERENCE_ON_DISK")
            return
        }
        let referenceHash = SHA256.hash(data: referenceData)
            .map { String(format: "%02x", $0) }.joined()
        print("🎬 [PROBE] reference sha256=\(referenceHash)")
        t.check(true, "REAL_OPENING_REFERENCE_ON_DISK")

        // ---------------------------------------------------------------
        // The production submission path, at 作品数 = 3.
        // ---------------------------------------------------------------
        let workCount = 3
        guard let job = try? MovieRunSubmission.makeJob(
            project: project,
            workCount: workCount,
            directorMode: "auto",
            store: store,
            contentHash: { H3EndingImageCapability.contentHash(ofFileAt: $0) }) else {
            t.check(false, "REAL_COUNT3_JOB_BUILT")
            return
        }
        t.check(true, "REAL_COUNT3_JOB_BUILT")

        let runs = job.snapshot.movieRuns
        t.checkEqual(runs.count, workCount, "REAL_COUNT3_RUN_COUNT")
        t.checkEqual(job.snapshot.batchCount, workCount, "REAL_COUNT3_BATCH_COUNT")

        guard runs.count == workCount else { return }

        // Every run must start from the *same frozen* Opening Reference.
        var firstShotPaths: [String?] = []
        var firstShotSources: [String] = []
        var prompts: [String] = []
        var seedVectors: [[Int]] = []
        var resolvedFirstFrames: [String] = []

        for run in runs {
            let ordered = run.orderedShots
            guard let first = ordered.first else { continue }
            firstShotSources.append("\(first.startSource)")
            firstShotPaths.append(first.explicitStartImageRelativePath)
            prompts.append(first.compiledPrompt)
            seedVectors.append(ordered.map(\.seed))

            // The request the renderer would actually receive.
            if let request = MovieRunRequestBuilder.makeRequest(
                run: run,
                shotID: first.id,
                parameters: GenerationParameters(
                    numInferenceSteps: 15, guidanceScale: 3, width: 768, height: 512,
                    numFrames: 121, fps: 24, seed: nil,
                    vaeTilingMode: "auto", imageStrength: 1),
                resolveAsset: { path, projectID in
                    MovieRunRequestBuilder.resolveFrozenAssetPath(
                        path, projectID: projectID, store: store)
                }),
               let source = request.sourceImagePath {
                resolvedFirstFrames.append(source)
            }
        }

        t.checkEqual(Set(firstShotSources),
            Set(["explicitImage"]), "REAL_COUNT3_FIRST_SHOT_START_SOURCE")

        t.checkEqual(Set(firstShotPaths.map { $0 ?? "" }),
            Set([relativePath]), "REAL_COUNT3_FIRST_IMAGE_FREEZE")

        // One freeze, copied — not three independent reads of a mutable project.
        t.checkEqual(Set(prompts).count, 1, "REAL_COUNT3_PLAN_SHARED_PROMPT")
        t.checkEqual(Set(runs.map { $0.plan.shots.count }).count, 1, "REAL_COUNT3_PLAN_SHARED_SHOT_COUNT")
        t.checkEqual(Set(runs.map { $0.batchID }).count, 1, "REAL_COUNT3_PLAN_SHARED_BATCH_ID")
        t.checkEqual(Set(runs.map(\.batchIndex)), Set(0..<workCount), "REAL_COUNT3_BATCH_INDICES_DISTINCT")

        // Independent seeds: same composition, different candidate.
        t.checkEqual(Set(seedVectors).count, workCount, "REAL_COUNT3_SEEDS_INDEPENDENT")

        // Every run's first request resolves to the same real file, and that
        // file is byte-identical to the image the user chose.
        t.checkEqual(resolvedFirstFrames.count, workCount, "REAL_COUNT3_REQUEST_BUILT")
        t.checkEqual(Set(resolvedFirstFrames).count, 1, "REAL_COUNT3_REQUEST_PATHS_IDENTICAL")

        var allBytesMatch = !resolvedFirstFrames.isEmpty
        for path in resolvedFirstFrames {
            guard let data = FileManager.default.contents(atPath: path) else {
                allBytesMatch = false
                continue
            }
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            if hash != referenceHash { allBytesMatch = false }
        }
        t.check(allBytesMatch, "REAL_COUNT3_REQUEST_BYTES_MATCH_USER_IMAGE")

        if let sample = resolvedFirstFrames.first {
            print("🎬 [PROBE] every work's Shot 1 --image → \(sample)")
        }
        print("🎬 [PROBE] seeds per work: \(seedVectors)")
        print("🎬 [PROBE] shot-1 prompt (\(prompts.first?.count ?? 0) chars): "
              + "\(prompts.first?.prefix(120) ?? "")…")

        // ---------------------------------------------------------------
        // Prompt policy, measured on the real compiled prompt.
        // ---------------------------------------------------------------
        let appearanceMarkers = [
            "Face:", "Hair:", "Eyes:", "Age impression:", "Build:", "Complexion:",
            "Distinctive features:", "Current costume:", "Accessories:", "Continuity:"
        ]
        let firstPrompt = prompts.first ?? ""
        let leaked = appearanceMarkers.filter { firstPrompt.contains($0) }
        t.checkEqual(leaked, [], "REAL_COUNT3_NO_APPEARANCE_DUMP")
        if !leaked.isEmpty {
            print("🎬 [PROBE] leaked appearance markers: \(leaked)")
        }

        // ---------------------------------------------------------------
        // The frozen content hash, on the real project.
        // ---------------------------------------------------------------
        let frozenHash = runs.first?.orderedShots.first?.explicitStartImageContentHash
        t.check(frozenHash != nil, "REAL_PROJECT_HASH_NON_NIL")
        t.checkEqual(frozenHash, referenceHash, "REAL_PROJECT_HASH_MATCHES_BYTES")
        t.checkEqual(
            Set(runs.compactMap { $0.orderedShots.first?.explicitStartImageContentHash }).count,
            1, "REAL_COUNT3_HASH_SHARED")
        print("🎬 [PROBE] frozen content hash=\(frozenHash ?? "nil")")

        // ---------------------------------------------------------------
        // Fail-closed, proven on a *copy*. The user's real asset is never
        // mutated: the project is duplicated into scratch, and the copy's
        // start image is edited after freezing.
        // ---------------------------------------------------------------
        let scratchRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpeningRefProbe-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratchRoot) }

        let scratchStore = FilmProjectStore(projectsDirectory: scratchRoot)
        guard let scratchAsset = scratchStore.managedProjectAssetURL(
            projectID: project.id, relativePath: relativePath) else {
            t.check(false, "MUTATED_FILE_FAIL_CLOSED")
            return
        }
        try? FileManager.default.createDirectory(
            at: scratchAsset.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? referenceData.write(to: scratchAsset)

        func scratchResolve(_ path: String, _ projectID: UUID) -> String? {
            MovieRunRequestBuilder.resolveFrozenAssetPath(
                path, projectID: projectID, store: scratchStore)
        }
        let scratchParams = GenerationParameters(
            numInferenceSteps: 15, guidanceScale: 3, width: 768, height: 512,
            numFrames: 121, fps: 24, seed: nil, vaeTilingMode: "auto", imageStrength: 1)

        guard let scratchJob = try? MovieRunSubmission.makeJob(
            project: project, workCount: 1, directorMode: "auto", store: scratchStore,
            contentHash: { H3EndingImageCapability.contentHash(ofFileAt: $0) }),
              let scratchRun = scratchJob.snapshot.movieRuns.first,
              let scratchShot = scratchRun.orderedShots.first else {
            t.check(false, "MUTATED_FILE_FAIL_CLOSED")
            return
        }

        t.check(MovieRunRequestBuilder.makeRequest(
            run: scratchRun, shotID: scratchShot.id,
            parameters: scratchParams, resolveAsset: scratchResolve) != nil,
            "SCRATCH_COPY_RENDERS_BEFORE_MUTATION")

        // Now edit the copy's bytes, exactly as a user editing the image while
        // the work waits in the queue would.
        var mutated = referenceData
        mutated.append(contentsOf: Array("MUTATED".utf8))
        try? mutated.write(to: scratchAsset)
        let mutatedBytes = FileManager.default.contents(atPath: scratchAsset.path)
        t.check(mutatedBytes != referenceData, "SCRATCH_COPY_ACTUALLY_MUTATED")

        t.checkEqual(MovieRunRequestBuilder.makeRequest(
            run: scratchRun, shotID: scratchShot.id,
            parameters: scratchParams, resolveAsset: scratchResolve), nil,
            "MUTATED_FILE_FAIL_CLOSED")

        // Failing closed is only useful if the user is told why. Check the
        // reason the queue would actually show, on the real project's own
        // Opening Reference filename.
        let refusal = RunDispatchRefusal.classify(
            run: scratchRun, shotID: scratchShot.id, resolveAsset: scratchResolve)
        let realName = URL(fileURLWithPath: absolute).lastPathComponent
        t.checkEqual(refusal.shotState, ShotRunState.State.failed,
                     "MUTATED_FILE_USER_VISIBLE the shot fails explicitly")
        t.check(refusal.message.contains("変更されています"),
                "MUTATED_FILE_USER_VISIBLE and says the image changed")
        t.check(refusal.message.contains(realName),
                "MUTATED_FILE_USER_VISIBLE naming the user's own file")
        t.check(!refusal.message.contains("/"),
                "MUTATED_FILE_USER_VISIBLE without leaking the library path")
        print("🎬 [PROBE] queue would show: \(refusal.message)")

        // And a deleted one is worded differently from a changed one.
        try? FileManager.default.removeItem(at: scratchAsset)
        let deletedRefusal = RunDispatchRefusal.classify(
            run: scratchRun, shotID: scratchShot.id, resolveAsset: scratchResolve)
        t.check(deletedRefusal.message.contains("見つかりません"),
                "MISSING_FILE_USER_VISIBLE a deleted image says it cannot be found")
        t.check(deletedRefusal.message != refusal.message,
                "MISSING_FILE_USER_VISIBLE distinct from the changed-image wording")
        print("🎬 [PROBE] deleted would show: \(deletedRefusal.message)")

        // And the user's real asset is untouched by all of the above.
        let stillOriginal = FileManager.default.contents(atPath: absolute)
            .map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
        t.checkEqual(stillOriginal, referenceHash, "USER_ASSET_UNMODIFIED")
    }
}
