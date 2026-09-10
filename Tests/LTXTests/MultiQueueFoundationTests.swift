import Foundation
@testable import LTXVideoGeneratorCore

/// Phase 24/25 coverage for the multi-queue shared foundation.
///
/// These drive the real production types — `CandidateExpander`,
/// `RunProvenanceStamper`, `RunRetryPlanner`, `SeedAllocator` — rather than a
/// re-implementation of their rules.
func runMultiQueueFoundationTests(_ t: TestKit) {

    func makeRequest(
        seed: Int? = nil,
        endingImagePath: String? = nil,
        endingImageContentHash: String? = nil
    ) -> GenerationRequest {
        GenerationRequest(
            prompt: "a woman raises her hand",
            sourceImagePath: "/tmp/start.png",
            endingImagePath: endingImagePath,
            endingImageContentHash: endingImageContentHash,
            modelId: MiniMaxH3Configuration.standardModelID,
            parameters: GenerationParameters(
                numInferenceSteps: 15, guidanceScale: 3,
                width: 512, height: 288, numFrames: 73, fps: 24,
                seed: seed, vaeTilingMode: "auto", imageStrength: 1),
            preset: MiniMaxH3Preset.custom.rawValue,
            generationSource: "oneShot")
    }

    t.suite("Multi-queue — seed allocation") {
        // 4. normal multi-run seeds differ
        let seeds = SeedAllocator.allocate(count: 64)
        t.checkEqual(seeds.count, 64, "SEED_1 allocates the requested count")
        t.checkEqual(Set(seeds).count, 64, "SEED_2 every allocated seed is distinct")
        t.check(seeds.allSatisfy { $0 >= 0 && $0 < SeedAllocator.upperBound },
                "SEED_3 seeds stay inside the range every backend already used")
        t.checkEqual(SeedAllocator.allocate(count: 0), [], "SEED_4 zero count is empty")

        // The defect this allocator replaces: `base + index` collides across
        // nested indices (run 1 shot 3 == run 3 shot 1).
        let additive = (1...3).flatMap { run in (1...3).map { shot in 1000 + run + shot } }
        t.check(Set(additive).count < additive.count,
                "SEED_5 the additive base+index form does collide (why it is not used)")
    }

    t.suite("Multi-queue — candidate expansion") {
        // 1. count = 1 behaves like a single submit
        let single = CandidateExpander.expand(makeRequest(), count: 1)
        t.checkEqual(single.count, 1, "EXPAND_1 count=1 yields exactly one run")
        t.check(single[0].parameters.seed != nil, "EXPAND_1 that run still gets a frozen seed")

        // 2/3. count = N -> N independent runs with unique ids
        let base = makeRequest()
        let many = CandidateExpander.expand(base, count: 5)
        t.checkEqual(many.count, 5, "EXPAND_2 count=N yields exactly N runs")
        t.checkEqual(Set(many.map(\.id)).count, 5, "EXPAND_3 run ids are unique")
        t.checkEqual(Set(many.compactMap(\.parameters.seed)).count, 5,
                     "EXPAND_4 candidate seeds are distinct")
        t.checkEqual(many.map(\.batchIndex), [0, 1, 2, 3, 4], "EXPAND_5 batch index orders the runs")
        t.checkEqual(Set(many.compactMap(\.batchID)).count, 1, "EXPAND_6 one batch id for the submit")
        t.check(many.allSatisfy { $0.attemptNumber == 1 }, "EXPAND_7 every run starts at attempt 1")

        // Everything that defines *what* is made must be shared verbatim.
        t.check(many.allSatisfy { $0.prompt == base.prompt }, "EXPAND_8 prompt shared")
        t.check(many.allSatisfy { $0.modelId == base.modelId }, "EXPAND_8 model shared")
        t.check(many.allSatisfy { $0.preset == base.preset }, "EXPAND_8 preset shared")
        t.check(many.allSatisfy { $0.sourceImagePath == base.sourceImagePath },
                "EXPAND_8 starting image shared")
        t.check(many.allSatisfy { $0.disableAudio == base.disableAudio },
                "EXPAND_8 audio policy shared")

        // Frozen policy (checkpoint Correction 2): an explicit seed is honoured
        // by every candidate. Asking for a seed is asking to reproduce a
        // condition, so varying some of them would answer a different question.
        let pinned = CandidateExpander.expand(makeRequest(seed: 4242), count: 3)
        t.checkEqual(pinned.compactMap(\.parameters.seed), [4242, 4242, 4242],
                     "EXPAND_9 an explicit seed is used by every candidate")
        t.checkEqual(Set(pinned.map(\.id)).count, 3,
                     "EXPAND_9 they remain independent runs")
    }

    t.suite("Multi-queue — H3 First+Last regression across candidates") {
        // Phase 25: every candidate must keep the Ending Image and its hash.
        let hash = "9880f3b93b5ae97007889fc6c0b10fe160f8a2452c0b3011365d27f4af1342fb"
        let base = makeRequest(endingImagePath: "/tmp/e2e_last.png", endingImageContentHash: hash)
        let candidates = CandidateExpander.expand(base, count: 2)

        t.check(candidates.allSatisfy { $0.endingImagePath == "/tmp/e2e_last.png" },
                "H3_MQ_1 every candidate keeps the ending image path")
        t.check(candidates.allSatisfy { $0.endingImageContentHash == hash },
                "H3_MQ_2 every candidate keeps the submission-time content hash")
        t.check(candidates.allSatisfy(\.hasEndingImage),
                "H3_MQ_3 every candidate still reports an ending image")
        t.check(candidates.allSatisfy {
            H3EndingImageValidator.validateAtSubmission(
                modelID: $0.modelId,
                startImagePath: $0.sourceImagePath,
                endingImagePath: $0.endingImagePath) == nil
        }, "H3_MQ_4 every candidate still passes submission validation")
        t.checkEqual(Set(candidates.compactMap(\.parameters.seed)).count, 2,
                     "H3_MQ_5 but the candidates still differ by seed")
    }

    t.suite("Multi-queue — submission stamping") {
        var snapshot = ProductionJobSnapshot()
        snapshot.pendingRequests = [makeRequest(), makeRequest()]
        let job = ProductionJob(kind: .oneShot, title: "t", snapshot: snapshot)
        let stamped = RunProvenanceStamper.stamp(job)

        t.checkEqual(stamped.snapshot.snapshotVersion, RunProvenanceStamper.currentSnapshotVersion,
                     "STAMP_1 snapshot is versioned")
        t.check(stamped.snapshot.batchID != nil, "STAMP_2 batch identity assigned")
        t.checkEqual(stamped.snapshot.batchCount, 2, "STAMP_3 batch count matches the runs")
        t.check(stamped.snapshot.pendingRequests.allSatisfy { $0.parameters.seed != nil },
                "STAMP_4 no run reaches the queue without a frozen seed")
        t.check(stamped.snapshot.pendingRequests.allSatisfy { $0.attemptNumber == 1 },
                "STAMP_5 runs start at attempt 1")

        // Idempotent: re-stamping must not re-roll a seed or renumber a run.
        let restamped = RunProvenanceStamper.stamp(stamped)
        t.checkEqual(restamped.snapshot.pendingRequests.map(\.parameters.seed),
                     stamped.snapshot.pendingRequests.map(\.parameters.seed),
                     "STAMP_6 re-stamping preserves frozen seeds")
        t.checkEqual(restamped.snapshot.batchID, stamped.snapshot.batchID,
                     "STAMP_6 re-stamping preserves the batch id")
    }

    t.suite("Multi-queue — retry vs retake") {
        let requests = CandidateExpander.expand(makeRequest(), count: 3)
        let (a, b, c) = (requests[0], requests[1], requests[2])

        // Correction C: A completed, B failed, C never started.
        let outcomes = [
            RunOutcomeRecord(runID: a.id, outcome: .completed, outputPath: "/tmp/a.mp4"),
            RunOutcomeRecord(runID: b.id, outcome: .failed, failureReason: "backend error"),
        ]
        let plan = RunRetryPlanner.plan(requests: requests, outcomes: outcomes)

        t.checkEqual(plan.skippedRunIDs, [a.id], "RETRY_1 the completed candidate is NOT regenerated")
        t.checkEqual(plan.requestsToRun.map(\.id), [b.id, c.id],
                     "RETRY_2 the failed and the never-started candidates are retried")
        t.checkEqual(plan.preservedOutcomes.map(\.runID), [a.id],
                     "RETRY_3 the completed outcome is carried forward for a second retry")

        // 5. Retry preserves seed and every frozen input.
        let retriedB = plan.requestsToRun[0]
        t.checkEqual(retriedB.parameters.seed, b.parameters.seed, "RETRY_4 retry preserves the seed")
        t.checkEqual(retriedB.id, b.id, "RETRY_5 retry keeps the same logical run id")
        t.checkEqual(retriedB.attemptNumber, 2, "RETRY_6 retry raises the attempt number")
        t.checkEqual(retriedB.sourceImagePath, b.sourceImagePath, "RETRY_7 frozen inputs unchanged")
        t.checkEqual(retriedB.prompt, b.prompt, "RETRY_7 frozen prompt unchanged")

        // A batch where everything already succeeded has nothing to retry.
        let allDone = requests.map { RunOutcomeRecord(runID: $0.id, outcome: .completed) }
        t.check(RunRetryPlanner.plan(requests: requests, outcomes: allDone).isEmpty,
                "RETRY_8 a fully-successful batch has no work left")

        // 6. Retake is a different operation: new Take, new seed, old one intact.
        let retake = CandidateExpander.expand(makeRequest(), count: 1)[0]
        t.check(retake.id != b.id, "RETAKE_1 retake is a new run, not a new attempt")
        t.check(retake.parameters.seed != b.parameters.seed, "RETAKE_2 retake gets a new seed")
        t.checkEqual(b.attemptNumber, 1, "RETAKE_3 the original take is not mutated")
    }

    t.suite("Multi-queue — legacy decoding") {
        // 8/9. A request persisted before multi-queue must still decode, with
        // run identity absent rather than invented.
        let legacy = """
        {"id":"\(UUID().uuidString)","prompt":"legacy","negativePrompt":"",
         "voiceoverText":"","voiceoverSource":"mlx-audio","voiceoverVoice":"af_heart",
         "musicEnabled":false,"disableAudio":false,"gemmaRepetitionPenalty":1.2,
         "gemmaTopP":0.9,"modelId":"ltx23_distilled_q4","textEncoderId":"gemma3_12b_4bit",
         "parameters":{"numInferenceSteps":15,"guidanceScale":3,"width":512,"height":288,
         "numFrames":73,"fps":24,"vaeTilingMode":"auto","imageStrength":1},
         "createdAt":0,"status":"pending","customModelsEnabled":false}
        """
        let decoder = JSONDecoder()
        let decoded = try? decoder.decode(GenerationRequest.self, from: Data(legacy.utf8))
        t.check(decoded != nil, "LEGACY_1 a pre-multi-queue request still decodes")
        t.checkEqual(decoded?.batchID, nil, "LEGACY_2 batch identity stays absent, not invented")
        t.checkEqual(decoded?.attemptNumber, nil, "LEGACY_3 attempt stays absent")
        t.checkEqual(decoded?.parameters.seed, nil, "LEGACY_4 no seed was fabricated on decode")

        // Migration happens exactly once, at the enqueue boundary.
        if let decoded {
            let stamped = RunProvenanceStamper.stampRequest(decoded, batchID: UUID(), batchIndex: 0)
            t.check(stamped.parameters.seed != nil, "LEGACY_5 enqueue freezes a seed for it")
            t.checkEqual(stamped.attemptNumber, 1, "LEGACY_6 enqueue gives it attempt 1")
        }

        // A version-1 snapshot decodes with an empty ledger rather than failing.
        var snapshot = ProductionJobSnapshot()
        t.checkEqual(snapshot.snapshotVersion, 1, "LEGACY_7 default snapshot version is the legacy one")
        t.checkEqual(snapshot.runOutcomes, [], "LEGACY_8 legacy snapshots have no run ledger")
        snapshot.runOutcomes = [RunOutcomeRecord(runID: UUID(), outcome: .completed)]
        t.checkEqual(snapshot.completedRunIDs.count, 1, "LEGACY_9 completed run ids derive from the ledger")

        // Regression: adding a defaulted field to the snapshot makes the
        // synthesised decoder demand its key, which would silently drop every
        // queue record an older build wrote — the user's whole waiting queue.
        let legacySnapshot = "{\"prompt\":\"old job\",\"brief\":\"\",\"batchCount\":1,\"pendingRequests\":[]}"
        let decodedSnapshot = try? decoder.decode(
            ProductionJobSnapshot.self, from: Data(legacySnapshot.utf8))
        t.check(decodedSnapshot != nil,
                "LEGACY_10 a queue snapshot written before multi-queue still decodes")
        t.checkEqual(decodedSnapshot?.prompt, "old job", "LEGACY_10 its content survives")
        t.checkEqual(decodedSnapshot?.snapshotVersion, 1,
                     "LEGACY_11 it reads as version 1, not as the current version")
        t.checkEqual(decodedSnapshot?.runOutcomes, [], "LEGACY_12 with an empty run ledger")
        t.checkEqual(decodedSnapshot?.batchID, nil, "LEGACY_13 and no invented batch identity")
    }

    // MARK: - Checkpoint corrections

    t.suite("Multi-queue — queue snapshot is the execution authority") {
        let requests = CandidateExpander.expand(makeRequest(), count: 3)
        let (a, b, c) = (requests[0], requests[1], requests[2])

        // 1/2. Partial retry decided purely from persisted queue state.
        // History is deliberately not consulted anywhere in this path, so this
        // holds with History unavailable, deleted or corrupt.
        var snapshot = ProductionJobSnapshot()
        snapshot.pendingRequests = requests
        snapshot.runOutcomes = [
            RunOutcomeRecord(runID: a.id, outcome: .completed, outputPath: "/tmp/a.mp4"),
            RunOutcomeRecord(runID: b.id, outcome: .failed, failureReason: "backend error"),
        ]
        let plan = RunRetryPlanner.plan(
            requests: snapshot.pendingRequests, outcomes: snapshot.runOutcomes)
        t.checkEqual(plan.skippedRunIDs, [a.id],
                     "QSTATE_1 a run recorded completed in the snapshot is not re-rendered")
        t.checkEqual(plan.requestsToRun.map(\.id), [b.id, c.id],
                     "QSTATE_2 failed and never-started runs are retried")
        t.checkEqual(snapshot.completedRunIDs, [a.id],
                     "QSTATE_3 completion derives from the snapshot ledger")

        // A crash between rendering and writing History: the queue recorded the
        // completion, so restart must not regenerate it.
        var crashed = ProductionJobSnapshot()
        crashed.pendingRequests = requests
        crashed.runOutcomes = [RunOutcomeRecord(runID: a.id, outcome: .completed)]
        t.check(!RunRetryPlanner.plan(requests: crashed.pendingRequests,
                                      outcomes: crashed.runOutcomes)
                    .requestsToRun.contains { $0.id == a.id },
                "QSTATE_4 restart does not repeat a completed run whose History write was lost")

        // A run interrupted mid-flight is retryable, not assumed finished.
        let interrupted = RunOutcomeRecord(runID: c.id, outcome: .interrupted)
        t.check(interrupted.outcome.needsExecution,
                "QSTATE_5 an interrupted run still needs execution")
        t.check(!RunOutcomeRecord(runID: a.id, outcome: .completed).outcome.needsExecution,
                "QSTATE_6 a completed run does not")
        t.checkEqual(RunOutcomeRecord.Outcome(GenerationStatus.processing), .running,
                     "QSTATE_7 run state maps from the existing GenerationStatus")
    }

    t.suite("Multi-queue — frozen seed policy") {
        // 3. AUTO count=3 -> 3 distinct seeds
        let auto = CandidateExpander.expand(makeRequest(seed: nil), count: 3)
        t.checkEqual(Set(auto.compactMap(\.parameters.seed)).count, 3,
                     "SEEDPOL_1 auto seed gives every candidate its own")

        // 4. EXPLICIT seed=12345 count=3 -> 12345 / 12345 / 12345
        let explicit = CandidateExpander.expand(makeRequest(seed: 12345), count: 3)
        t.checkEqual(explicit.compactMap(\.parameters.seed), [12345, 12345, 12345],
                     "SEEDPOL_2 an explicit seed is honoured by every candidate")
        t.checkEqual(Set(explicit.map(\.id)).count, 3,
                     "SEEDPOL_3 they are still independent runs")

        // count=1 explicit seed -> exact user seed
        let one = CandidateExpander.expand(makeRequest(seed: 777), count: 1)
        t.checkEqual(one[0].parameters.seed, 777, "SEEDPOL_4 count=1 uses the exact user seed")

        // 5/6. Retry same seed, Retake new seed.
        let outcomes = [RunOutcomeRecord(runID: explicit[0].id, outcome: .failed)]
        let retried = RunRetryPlanner.plan(requests: [explicit[0]], outcomes: outcomes)
        t.checkEqual(retried.requestsToRun[0].parameters.seed, 12345,
                     "SEEDPOL_5 retry keeps the persisted seed")
        t.checkEqual(retried.requestsToRun[0].attemptNumber, 2,
                     "SEEDPOL_5 and raises the attempt")
        let retake = CandidateExpander.expand(makeRequest(seed: nil), count: 1)[0]
        t.check(retake.parameters.seed != 12345, "SEEDPOL_6 a retake draws a new seed")
    }

    t.suite("Multi-queue — legacy nil seed migrated once") {
        // 7. A pre-multi-queue request retried twice must not get two seeds.
        var legacy = makeRequest(seed: nil)
        legacy.parameters.seed = nil
        legacy.batchID = nil
        legacy.attemptNumber = nil

        let first = RunRetryPlanner.plan(
            requests: [legacy],
            outcomes: [RunOutcomeRecord(runID: legacy.id, outcome: .failed)])
        let migrated = first.requestsToRun[0]
        t.check(migrated.parameters.seed != nil,
                "LEGACYSEED_1 a legacy run gets a concrete seed at retry")
        t.check(migrated.batchID != nil, "LEGACYSEED_2 and batch identity")

        // Second retry starts from the persisted (migrated) request.
        let second = RunRetryPlanner.plan(
            requests: [migrated],
            outcomes: [RunOutcomeRecord(runID: migrated.id, outcome: .failed)])
        t.checkEqual(second.requestsToRun[0].parameters.seed, migrated.parameters.seed,
                     "LEGACYSEED_3 the migrated seed is reused, not re-rolled")
        t.checkEqual(second.requestsToRun[0].attemptNumber, (migrated.attemptNumber ?? 1) + 1,
                     "LEGACYSEED_4 attempts keep counting")
    }

    t.suite("Multi-queue — run-local take selection") {
        let runA = UUID(), runB = UUID()
        let shot1 = UUID(), shot2 = UUID()
        let takeA1 = UUID(), takeB1 = UUID()

        var map = RunLocalTakeMap()
        map.adopt(runID: runA, shotID: shot1, takeID: takeA1)
        map.adopt(runID: runB, shotID: shot1, takeID: takeB1)

        // 8. No cross-run leakage: there is no key by which B reaches A.
        t.checkEqual(map.take(runID: runA, shotID: shot1), takeA1, "RUNLOCAL_1 run A sees its own take")
        t.checkEqual(map.take(runID: runB, shotID: shot1), takeB1, "RUNLOCAL_2 run B sees its own take")
        t.check(map.take(runID: runA, shotID: shot1) != map.take(runID: runB, shotID: shot1),
                "RUNLOCAL_3 the two runs resolve to different takes")
        t.checkEqual(map.take(runID: UUID(), shotID: shot1), nil,
                     "RUNLOCAL_4 an unknown run resolves to nothing, never to another run's take")

        // 9. A global selection change cannot alter a resolved dependency.
        var depA = ResolvedShotDependency(runID: runA, upstreamShotID: shot1)
        _ = depA.resolve(using: map, assetPath: { _ in "/tmp/a1.mp4" }, contentHash: { _ in "hashA1" })
        t.checkEqual(depA.resolvedTakeID, takeA1, "RUNLOCAL_5 run A shot 2 resolves to A1")
        t.checkEqual(depA.resolvedContentHash, "hashA1", "RUNLOCAL_6 and records the content hash")

        var depB = ResolvedShotDependency(runID: runB, upstreamShotID: shot1)
        _ = depB.resolve(using: map, assetPath: { _ in "/tmp/b1.mp4" }, contentHash: { _ in "hashB1" })
        t.checkEqual(depB.resolvedTakeID, takeB1, "RUNLOCAL_7 run B shot 2 resolves to B1")

        // The upstream shot is retaken and the run re-adopts. An already
        // resolved downstream dependency keeps the take it was made from.
        let takeA1b = UUID()
        map.readopt(runID: runA, shotID: shot1, takeID: takeA1b)
        t.checkEqual(map.take(runID: runA, shotID: shot1), takeA1b,
                     "RUNLOCAL_8 the run adopts the retake for future work")
        t.checkEqual(depA.resolvedTakeID, takeA1,
                     "RUNLOCAL_9 but an already-resolved dependency is not mutated")
        t.checkEqual(depB.resolvedTakeID, takeB1, "RUNLOCAL_10 and run B is untouched")

        // A dependency cannot resolve before its own run has produced anything.
        var depUnready = ResolvedShotDependency(runID: UUID(), upstreamShotID: shot1)
        t.check(!depUnready.resolve(using: map, assetPath: { _ in nil }, contentHash: { _ in nil }),
                "RUNLOCAL_11 a run with no upstream output waits rather than borrowing one")
        t.check(!depUnready.isResolved, "RUNLOCAL_12 and stays unresolved")
        _ = shot2
    }

    t.suite("Multi-queue — shared count control") {
        // 10. One shared source for label, choices, validation, a11y text.
        t.checkEqual(MultiQueueCount.Unit.generation.label, "生成数", "UI_1 Generate/One Shot unit")
        t.checkEqual(MultiQueueCount.Unit.work.label, "作品数", "UI_2 Storyboard/Auto Movie unit")
        t.check(MultiQueueCount.generationChoices.contains(1), "UI_3 count=1 is offerable")
        t.check([3, 5, 10, 20].allSatisfy(MultiQueueCount.generationChoices.contains),
                "UI_4 Generate's existing choices are preserved")
        t.checkEqual(MultiQueueCount.choices(for: .generation), MultiQueueCount.generationChoices,
                     "UI_5 both surfaces read the same list")

        // Validation clamps a stale or hand-edited preference onto the set.
        t.check(MultiQueueCount.choices(for: .generation)
                    .contains(MultiQueueCount.validated(7, unit: .generation)),
                "UI_6 an off-list count is clamped onto the offered set")
        t.checkEqual(MultiQueueCount.validated(5, unit: .generation), 5,
                     "UI_7 a valid count is left alone")
        t.checkEqual(MultiQueueCount.validated(0, unit: .work), 1,
                     "UI_8 a nonsense count falls back to one")

        t.check(MultiQueueCount.accessibilityLabel(count: 3, unit: .generation).contains("生成数"),
                "UI_9 accessibility text names the unit")
        // The film summary must not hide run grouping behind a bare shot total.
        let summary = MultiQueueCount.summary(count: 3, unit: .work, shotsPerWork: 5)
        t.check(summary.contains("3") && summary.contains("5") && summary.contains("15"),
                "UI_10 the work summary shows works, shots per work and the total")
        t.check(summary.contains("作品"), "UI_11 and keeps the works visible, not just 15 generations")
    }
}
