import Foundation
@testable import LTXVideoGeneratorCore

/// Regression cover for the One Shot / Generate model picker's data path.
///
/// The picker renders `ModelReadinessStore.pickerModels(selectedID:)`, which
/// delegates to `ModelReadinessStore.composePickerRows(...)` — a
/// `nonisolated static` pure function extracted specifically so tests can
/// drive the *exact* production algorithm against fixture data, rather than
/// asserting against a hand-reimplemented mirror. A mirror is exactly how a
/// real regression went uncaught: this file used to re-implement a
/// "ready-only" filter that matched `pickerModels()`'s old behavior, so when
/// `pickerModels()` was changed the tests kept passing against their own
/// stale copy of the old rule instead of the real one.
///
/// Two production steps, both fixture-injectable:
///   ModelRegistry.selectableModels()          — which models are registered
///   ModelReadinessResolver.evaluateAll(...)   — each one's current status
/// combined by the real `ModelReadinessStore.composePickerRows`.
///
/// --------------------------------------------------------------------
/// CORE PRODUCT RULE (2026-09-18, MAKE_MODEL_PICKER_VISIBILITY_INDEPENDENT_
/// FROM_RUNTIME_READINESS): "Generate画面から選択できないユーザー向けモデル
/// は、ユーザーにとって存在しない。" The inverse holds too — a registered,
/// user-facing model must NEVER disappear from the picker just because its
/// runtime happens to be busy, stopped, or mid-load of a sibling tier.
/// VISIBLE / SELECTABLE / GENERATABLE_NOW are three separate questions:
///   REGISTERED user-facing model -> VISIBLE (always; this file's core check)
///   CONFIGURED (has weights/model dir/runtime)  -> SELECTABLE (row enabled)
///   runtime readiness (`canGenerate`)           -> GENERATABLE_NOW / status text
/// Readiness must only ever change a row's status label and whether it's
/// selectable — never whether the row exists at all.
///
/// Earlier motivating defect (still guarded by PICKER_1): `minimax_h3_
/// fl2va_2bit_te` rendered as "MiniMax H3 (Experimental)", the family name
/// rather than the Standard tier's own name, so there was no row matching
/// the name the user was told to select.
func runOneShotModelPickerTests(_ t: TestKit) {

    /// Thin wrapper around the real, `nonisolated` production algorithm —
    /// not a reimplementation. `ModelReadinessStore.pickerModels(selectedID:)`
    /// itself cannot be called from a fixture-isolated test because it's
    /// `@MainActor` and hard-wired to `ModelRegistry.shared` /
    /// `UserDefaults.standard`; `composePickerRows` is the exact same logic
    /// extracted to take injected registry/state/descriptor instead.
    func pickerRows(
        registry: ModelRegistry,
        states: [String: ModelReadiness],
        selectedID: String
    ) -> [(model: ModelDescriptor, readiness: ModelReadiness)] {
        ModelReadinessStore.composePickerRows(
            registered: registry.selectableModels(),
            states: states,
            selectedID: selectedID,
            descriptor: { registry.descriptor(id: $0) }
        )
    }

    /// A directory that satisfies every filesystem gate in `evaluateH3`:
    /// an existing model folder containing `config.json`, and an executable
    /// standing in for the managed mlx-serve runtime.
    func makeH3Fixture() -> (root: URL, modelDir: String, runtime: String) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OneShotPickerTests-\(UUID().uuidString)", isDirectory: true)
        let modelDir = root.appendingPathComponent("H3-Pack", isDirectory: true)
        try? FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: modelDir.appendingPathComponent("config.json").path,
            contents: Data(#"{"tasks":["t2va","fl2va"]}"#.utf8))
        let runtime = root.appendingPathComponent("mlx-serve")
        FileManager.default.createFile(
            atPath: runtime.path, contents: Data("#!/bin/sh\n".utf8),
            attributes: [.posixPermissions: 0o755])
        return (root, modelDir.path, runtime.path)
    }

    /// Defaults with a Ready H3 Standard, and nothing else H3 configured.
    /// `readinessModelID` is which model's own per-model key
    /// (`lastReadinessStateKey(for:)`) receives `readinessState` — the two
    /// can never cross-contaminate another H3 tier's key by construction.
    func makeDefaults(
        suite: String,
        modelDir: String,
        runtime: String,
        readinessState: String? = MiniMaxH3RuntimeState.ready.rawValue,
        readinessModelID: String? = MiniMaxH3Configuration.standardModelID
    ) -> UserDefaults {
        let d = UserDefaults(suiteName: suite)!
        d.set(modelDir, forKey: MiniMaxH3Configuration.standardModelDirectoryKey)
        d.set(runtime, forKey: MiniMaxH3Configuration.runtimeExecutablePathKey)
        d.set("http://127.0.0.1:11236", forKey: MiniMaxH3Configuration.endpointKey)
        if let readinessState, let readinessModelID {
            d.set(readinessState, forKey: MiniMaxH3Configuration.lastReadinessStateKey(for: readinessModelID))
        }
        return d
    }

    /// Fully configures all three H3 tiers (own model directory each) with
    /// an explicit readiness state per tier, so the three can be driven
    /// through Ready / WrongModel / Stopped combinations independently.
    func makeAllThreeH3Defaults(
        suite: String,
        modelDir: String,
        runtime: String,
        standardState: MiniMaxH3RuntimeState,
        highQualityState: MiniMaxH3RuntimeState,
        referenceState: MiniMaxH3RuntimeState
    ) -> UserDefaults {
        let d = UserDefaults(suiteName: suite)!
        d.set(modelDir, forKey: MiniMaxH3Configuration.standardModelDirectoryKey)
        d.set(modelDir, forKey: MiniMaxH3Configuration.highQualityModelDirectoryKey)
        d.set(modelDir, forKey: MiniMaxH3Configuration.referenceModelDirectoryKey)
        d.set(runtime, forKey: MiniMaxH3Configuration.runtimeExecutablePathKey)
        d.set("http://127.0.0.1:11236", forKey: MiniMaxH3Configuration.endpointKey)
        d.set(standardState.rawValue,
              forKey: MiniMaxH3Configuration.lastReadinessStateKey(for: MiniMaxH3Configuration.standardModelID))
        d.set(highQualityState.rawValue,
              forKey: MiniMaxH3Configuration.lastReadinessStateKey(for: MiniMaxH3Configuration.highQualityModelID))
        d.set(referenceState.rawValue,
              forKey: MiniMaxH3Configuration.lastReadinessStateKey(for: MiniMaxH3Configuration.referenceModelID))
        return d
    }

    t.suite("One Shot Model Picker — H3 Standard availability") {
        let standardID = MiniMaxH3Configuration.standardModelID
        let hqID = MiniMaxH3Configuration.highQualityModelID

        // ---------------------------------------------------------------
        // 1. Standard H3 registered + Ready -> appears in One Shot options
        // ---------------------------------------------------------------
        do {
            let fx = makeH3Fixture()
            let suite = "OneShotPicker-\(UUID().uuidString)"
            let d = makeDefaults(suite: suite, modelDir: fx.modelDir, runtime: fx.runtime)
            defer {
                d.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: fx.root)
            }
            let registry = ModelRegistry(userDefaults: d)
            let selectable = registry.selectableModels()
            t.check(selectable.contains { $0.id == standardID },
                    "PICKER_1 H3 Standard is present in selectableModels()")

            let states = Dictionary(uniqueKeysWithValues:
                ModelReadinessResolver.evaluateAll(models: selectable, userDefaults: d)
                    .map { ($0.modelID, $0) })
            t.checkEqual(states[standardID]?.status, .ready, "PICKER_1 H3 Standard resolves Ready")
            t.checkEqual(states[standardID]?.canGenerate, true, "PICKER_1 H3 Standard canGenerate")

            let rows = pickerRows(registry: registry, states: states, selectedID: standardID)
            t.check(rows.contains { $0.model.id == standardID },
                    "PICKER_1 H3 Standard appears in One Shot picker rows")

            // The defect this file exists for: the row must name the tier
            // distinctly, so a user can tell it apart from the other two H3
            // tiers. Assert against the live constant, not a hardcoded
            // substring, so this test does not have to be hand-edited again
            // on the next rename.
            let label = rows.first { $0.model.id == standardID }?.model.selectionDisplayName ?? ""
            t.checkEqual(label, MiniMaxH3Configuration.standardDisplayName,
                         "PICKER_1 H3 Standard row names the Standard tier (got: \(label))")
            t.check(label != MiniMaxH3Configuration.highQualityDisplayName,
                    "PICKER_1 Standard label is distinct from High Quality")
            t.check(label != MiniMaxH3Configuration.referenceDisplayName,
                    "PICKER_1 Standard label is distinct from Reference")
        }

        // ---------------------------------------------------------------
        // 2. Standard H3 not configured -> still VISIBLE (never omitted),
        // but not selectable. This replaces the old "Ready-only policy"
        // assertion: visibility is unconditional now; only selectability
        // depends on configuration.
        // ---------------------------------------------------------------
        do {
            let suite = "OneShotPicker-\(UUID().uuidString)"
            // No model directory configured at all.
            let d = UserDefaults(suiteName: suite)!
            defer { d.removePersistentDomain(forName: suite) }
            let registry = ModelRegistry(userDefaults: d)
            let selectable = registry.selectableModels()
            t.check(selectable.contains { $0.id == standardID },
                    "PICKER_2 unconfigured H3 Standard is still registered")

            let states = Dictionary(uniqueKeysWithValues:
                ModelReadinessResolver.evaluateAll(models: selectable, userDefaults: d)
                    .map { ($0.modelID, $0) })
            t.checkEqual(states[standardID]?.status, .notConfigured,
                         "PICKER_2 unconfigured H3 Standard is notConfigured")
            t.checkEqual(states[standardID]?.canGenerate, false, "PICKER_2 cannot generate yet")
            t.checkEqual(states[standardID]?.status.isConfigured, false,
                         "PICKER_2 notConfigured is correctly not selectable")

            let rows = pickerRows(registry: registry, states: states, selectedID: "ltx23_distilled_q4")
            let row = rows.first { $0.model.id == standardID }
            t.check(row != nil, "PICKER_2 unconfigured H3 Standard is still a VISIBLE picker row")
            t.checkEqual(row?.readiness.status.isConfigured, false,
                         "PICKER_2 the row is present but not selectable (disabled)")
        }

        // ---------------------------------------------------------------
        // 3. HQ Ready -> appears as a selectable model
        // ---------------------------------------------------------------
        do {
            let fx = makeH3Fixture()
            let suite = "OneShotPicker-\(UUID().uuidString)"
            let d = makeDefaults(suite: suite, modelDir: fx.modelDir, runtime: fx.runtime,
                                 readinessModelID: hqID)
            d.set(fx.modelDir, forKey: MiniMaxH3Configuration.highQualityModelDirectoryKey)
            defer {
                d.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: fx.root)
            }
            let registry = ModelRegistry(userDefaults: d)
            let selectable = registry.selectableModels()
            let states = Dictionary(uniqueKeysWithValues:
                ModelReadinessResolver.evaluateAll(models: selectable, userDefaults: d)
                    .map { ($0.modelID, $0) })
            t.checkEqual(states[hqID]?.status, .ready, "PICKER_3 configured HQ resolves Ready")
            let rows = pickerRows(registry: registry, states: states, selectedID: hqID)
            t.check(rows.contains { $0.model.id == hqID },
                    "PICKER_3 Ready HQ appears as a selectable model")
        }

        // ---------------------------------------------------------------
        // 4. HQ Ending Image capability -> remains false / unverified
        // ---------------------------------------------------------------
        t.checkEqual(H3EndingImageCapability.supportsEndingImage(modelID: hqID), false,
                     "PICKER_4 HQ Ending Image support stays FALSE even when HQ is selectable")
        t.check(H3EndingImageCapability.unsupportedReason(modelID: hqID) != nil,
                "PICKER_4 HQ has a user-facing unsupported reason")

        // ---------------------------------------------------------------
        // 4b. All three H3 tiers Ready together -> all three are picker rows
        // at once. MODEL_ADDITION_GATE regression: adding MiniMax H3
        // Reference must never make Standard or High Quality disappear
        // from the One Shot / Generate picker, and vice versa. The three
        // models share one runtime/endpoint but each has its OWN readiness
        // key (MiniMaxH3Configuration.lastReadinessStateKey(for:)), so
        // recording all three Ready cannot collide into one shared slot.
        // ---------------------------------------------------------------
        do {
            let refID = MiniMaxH3Configuration.referenceModelID
            let fx = makeH3Fixture()
            let suite = "OneShotPicker-\(UUID().uuidString)"
            let d = makeAllThreeH3Defaults(
                suite: suite, modelDir: fx.modelDir, runtime: fx.runtime,
                standardState: .ready, highQualityState: .ready, referenceState: .ready)
            defer {
                d.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: fx.root)
            }
            let registry = ModelRegistry(userDefaults: d)
            let selectable = registry.selectableModels()
            for id in [standardID, hqID, refID] {
                t.check(selectable.contains { $0.id == id },
                        "PICKER_4b \(id) is registered in selectableModels()")
            }
            let states = Dictionary(uniqueKeysWithValues:
                ModelReadinessResolver.evaluateAll(models: selectable, userDefaults: d)
                    .map { ($0.modelID, $0) })
            for id in [standardID, hqID, refID] {
                t.checkEqual(states[id]?.status, .ready,
                             "PICKER_4b \(id) resolves Ready from its own key, undisturbed by the other two")
            }
            let rows = pickerRows(registry: registry, states: states, selectedID: standardID)
            let rowIDs = Set(rows.map(\.model.id))
            for id in [standardID, hqID, refID] {
                t.check(rowIDs.contains(id),
                        "PICKER_4b \(id) is a One Shot picker row simultaneously with the other two H3 tiers")
            }
        }

        // ---------------------------------------------------------------
        // 5. LTX Ready -> remains selectable normally
        // ---------------------------------------------------------------
        do {
            let fx = makeH3Fixture()
            let suite = "OneShotPicker-\(UUID().uuidString)"
            let d = makeDefaults(suite: suite, modelDir: fx.modelDir, runtime: fx.runtime)
            defer {
                d.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: fx.root)
            }
            let registry = ModelRegistry(userDefaults: d)
            let selectable = registry.selectableModels()
            let ltxIDs = selectable.filter { $0.architecture.modelFamily == "LTX" }.map(\.id)
            t.check(!ltxIDs.isEmpty, "PICKER_5 LTX models remain registered alongside H3")
            // Adding H3 to the list must not displace the LTX entries.
            t.check(selectable.contains { $0.id == "ltx23_distilled_q4" },
                    "PICKER_5 official LTX-2.3 Distilled Q4 stays in selectableModels()")
        }

        // ---------------------------------------------------------------
        // 6. LTX Ending Image capability -> false
        // ---------------------------------------------------------------
        t.checkEqual(H3EndingImageCapability.supportsEndingImage(modelID: "ltx23_distilled_q4"), false,
                     "PICKER_6 LTX Ending Image support is FALSE")
        t.checkEqual(H3EndingImageCapability.supportsEndingImage(modelID: "ltx25_experimental"), false,
                     "PICKER_6 LTX-2.5 Ending Image support is FALSE")

        // ---------------------------------------------------------------
        // 7. custom LTX selected -> the picker is the FULL registered set,
        // never narrowed to "ready" or to the saved selection. This is the
        // direct replacement for the old "not narrowed to the saved
        // selection alone" test, whose own expectation used to be "== the
        // Ready set" — that Ready-only expectation was the bug.
        // ---------------------------------------------------------------
        do {
            let fx = makeH3Fixture()
            let suite = "OneShotPicker-\(UUID().uuidString)"
            let d = makeDefaults(suite: suite, modelDir: fx.modelDir, runtime: fx.runtime)
            defer {
                d.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: fx.root)
            }
            let registry = ModelRegistry(userDefaults: d)
            let selectable = registry.selectableModels()
            let states = Dictionary(uniqueKeysWithValues:
                ModelReadinessResolver.evaluateAll(models: selectable, userDefaults: d)
                    .map { ($0.modelID, $0) })

            // A custom-profile id that is selected but not registered here: the
            // worst case for "the saved selection narrows the list".
            let customSelection = "custom_profile_18D42D14-6616-476C-8C96-015156D34B8A"
            let rows = pickerRows(registry: registry, states: states, selectedID: customSelection)
            t.check(rows.contains { $0.model.id == standardID },
                    "PICKER_7 a selected custom LTX profile does not remove H3 Standard")
            // Corrected policy: the rows are exactly the FULL registered set
            // (visibility is unconditional). An unregistered saved selection
            // adds nothing (it isn't a real descriptor), so it neither adds
            // nor subtracts a row.
            t.checkEqual(rows.map(\.model.id).sorted(), selectable.map(\.id).sorted(),
                         "PICKER_7 the picker shows every registered model, not a readiness-filtered subset")
            t.check(!rows.contains { $0.model.id == customSelection },
                    "PICKER_7 an unregistered saved selection adds no phantom row")
        }

        // ---------------------------------------------------------------
        // 8. saved unconfigured model -> stays visible AND disabled, and
        // does not hide any other registered model either.
        // ---------------------------------------------------------------
        do {
            let suite = "OneShotPicker-\(UUID().uuidString)"
            let d = UserDefaults(suiteName: suite)!   // nothing H3 configured
            defer { d.removePersistentDomain(forName: suite) }
            let registry = ModelRegistry(userDefaults: d)
            let selectable = registry.selectableModels()
            let states = Dictionary(uniqueKeysWithValues:
                ModelReadinessResolver.evaluateAll(models: selectable, userDefaults: d)
                    .map { ($0.modelID, $0) })

            let rows = pickerRows(registry: registry, states: states, selectedID: standardID)
            let row = rows.first { $0.model.id == standardID }
            t.check(row != nil, "PICKER_8 an unconfigured *selected* model is shown")
            t.checkEqual(row?.readiness.status.isConfigured, false,
                         "PICKER_8 that row is disabled (not configured), not selectable")
            // The corrected policy: every OTHER registered model is also
            // present, not just the selected one.
            t.checkEqual(rows.map(\.model.id).sorted(), selectable.map(\.id).sorted(),
                         "PICKER_8 the picker is the full registered set, selection included exactly once")
        }

        // ---------------------------------------------------------------
        // 9. readiness refresh -> the row's STATUS changes, but the row is
        // never removed. This replaces the old assertion that a no-longer-
        // Ready model "drops" from the picker — that was the bug this whole
        // task fixes.
        // ---------------------------------------------------------------
        do {
            let fx = makeH3Fixture()
            let suite = "OneShotPicker-\(UUID().uuidString)"
            let d = makeDefaults(suite: suite, modelDir: fx.modelDir, runtime: fx.runtime)
            defer {
                d.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: fx.root)
            }
            let registry = ModelRegistry(userDefaults: d)
            let selectable = registry.selectableModels()

            let before = Dictionary(uniqueKeysWithValues:
                ModelReadinessResolver.evaluateAll(models: selectable, userDefaults: d)
                    .map { ($0.modelID, $0) })
            t.checkEqual(before[standardID]?.canGenerate, true, "PICKER_9 Ready before the change")
            t.check(pickerRows(registry: registry, states: before, selectedID: "ltx23_distilled_q4")
                        .contains { $0.model.id == standardID },
                    "PICKER_9 visible before the change")

            // Simulate Settings recording a failed re-check. Re-evaluating the
            // same models must reflect it in STATUS, not in visibility.
            d.set(MiniMaxH3RuntimeState.failed.rawValue,
                  forKey: MiniMaxH3Configuration.lastReadinessStateKey(for: standardID))
            d.set("probe failed",
                  forKey: MiniMaxH3Configuration.lastReadinessDetailKey(for: standardID))
            let after = Dictionary(uniqueKeysWithValues:
                ModelReadinessResolver.evaluateAll(models: selectable, userDefaults: d)
                    .map { ($0.modelID, $0) })
            t.checkEqual(after[standardID]?.canGenerate, false, "PICKER_9 not Ready after the change")
            let afterRows = pickerRows(registry: registry, states: after, selectedID: "ltx23_distilled_q4")
            let afterRow = afterRows.first { $0.model.id == standardID }
            t.check(afterRow != nil,
                    "PICKER_9 the model STAYS VISIBLE after becoming unready — only its status changes")
            t.checkEqual(afterRow?.readiness.status.isConfigured, true,
                         "PICKER_9 a failed health probe is still a configured (selectable) H3 model — only .notConfigured-family statuses disable the row")
            t.checkEqual(afterRow?.readiness.canGenerate, false,
                         "PICKER_9 canGenerate correctly reflects the failure for status/labeling purposes")

            // And back again, so the picker's status recovers without a
            // defaults reset — the row was never gone to begin with.
            d.set(MiniMaxH3RuntimeState.ready.rawValue,
                  forKey: MiniMaxH3Configuration.lastReadinessStateKey(for: standardID))
            let recovered = Dictionary(uniqueKeysWithValues:
                ModelReadinessResolver.evaluateAll(models: selectable, userDefaults: d)
                    .map { ($0.modelID, $0) })
            t.checkEqual(recovered[standardID]?.canGenerate, true,
                         "PICKER_9 status recovers once readiness is repaired")
            t.check(pickerRows(registry: registry, states: recovered, selectedID: "ltx23_distilled_q4")
                        .contains { $0.model.id == standardID },
                    "PICKER_9 still visible after recovery (it was visible the entire time)")
        }

        // ---------------------------------------------------------------
        // 10. selected model is never silently replaced
        // ---------------------------------------------------------------
        do {
            let fx = makeH3Fixture()
            let suite = "OneShotPicker-\(UUID().uuidString)"
            let d = makeDefaults(suite: suite, modelDir: fx.modelDir, runtime: fx.runtime)
            defer {
                d.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: fx.root)
            }
            let registry = ModelRegistry(userDefaults: d)
            let selectable = registry.selectableModels()
            let states = Dictionary(uniqueKeysWithValues:
                ModelReadinessResolver.evaluateAll(models: selectable, userDefaults: d)
                    .map { ($0.modelID, $0) })

            let selectedBefore = d.string(forKey: LTXModelCatalog.selectedModelIDKey)
            _ = pickerRows(registry: registry, states: states, selectedID: "ltx23_distilled_q4")
            t.checkEqual(d.string(forKey: LTXModelCatalog.selectedModelIDKey), selectedBefore,
                         "PICKER_10 composing the picker never writes a model selection")

            // Even with a Ready H3 Standard available, an unknown saved
            // selection is preserved rather than swapped for a valid one.
            let rows = pickerRows(registry: registry, states: states, selectedID: "totally_unknown_model")
            t.check(!rows.contains { $0.model.id == "totally_unknown_model" },
                    "PICKER_10 an unregistered selection is not fabricated as a row")
            t.checkEqual(d.string(forKey: LTXModelCatalog.selectedModelIDKey), selectedBefore,
                         "PICKER_10 an unknown selection is not rewritten to H3 Standard")
        }

        // ---------------------------------------------------------------
        // 12 (Phase 12). Selecting Standard enables the Ending Image predicate
        // ---------------------------------------------------------------
        t.checkEqual(H3EndingImageCapability.supportsEndingImage(modelID: standardID), true,
                     "PICKER_12 selecting H3 Standard makes Ending Image supported")
        t.checkEqual(H3EndingImageCapability.unsupportedReason(modelID: standardID), nil,
                     "PICKER_12 H3 Standard has no unsupported reason")
    }

    // =====================================================================
    // PICKER_VISIBILITY — explicit regression suite for MAKE_MODEL_PICKER_
    // VISIBILITY_INDEPENDENT_FROM_RUNTIME_READINESS. Every case exercises
    // the real `ModelReadinessStore.composePickerRows` (via `pickerRows`
    // above), never a mirror.
    // =====================================================================
    t.suite("PICKER_VISIBILITY — H3 models never disappear due to runtime state") {
        let standardID = MiniMaxH3Configuration.standardModelID
        let hqID = MiniMaxH3Configuration.highQualityModelID
        let refID = MiniMaxH3Configuration.referenceModelID
        let allThree = [standardID, hqID, refID]

        func assertAllThreeVisible(
            _ registry: ModelRegistry,
            _ states: [String: ModelReadiness],
            _ label: String,
            selectedID: String = MiniMaxH3Configuration.standardModelID
        ) {
            let rows = pickerRows(registry: registry, states: states, selectedID: selectedID)
            let rowIDs = Set(rows.map(\.model.id))
            for id in allThree {
                t.check(rowIDs.contains(id), "\(label): \(id) is visible")
            }
        }

        // PICKER_VISIBILITY_1: all three Ready -> 3/3 visible
        do {
            let fx = makeH3Fixture()
            let suite = "PickerVis-\(UUID().uuidString)"
            let d = makeAllThreeH3Defaults(
                suite: suite, modelDir: fx.modelDir, runtime: fx.runtime,
                standardState: .ready, highQualityState: .ready, referenceState: .ready)
            defer {
                d.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: fx.root)
            }
            let registry = ModelRegistry(userDefaults: d)
            let selectable = registry.selectableModels()
            let states = Dictionary(uniqueKeysWithValues:
                ModelReadinessResolver.evaluateAll(models: selectable, userDefaults: d).map { ($0.modelID, $0) })
            assertAllThreeVisible(registry, states, "PICKER_VISIBILITY_1 (all Ready)")
        }

        // PICKER_VISIBILITY_2: Standard=Ready, Quality=WrongModel, Reference=Stopped -> 3/3 visible
        do {
            let fx = makeH3Fixture()
            let suite = "PickerVis-\(UUID().uuidString)"
            let d = makeAllThreeH3Defaults(
                suite: suite, modelDir: fx.modelDir, runtime: fx.runtime,
                standardState: .ready, highQualityState: .wrongModel, referenceState: .notRunning)
            defer {
                d.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: fx.root)
            }
            let registry = ModelRegistry(userDefaults: d)
            let selectable = registry.selectableModels()
            let states = Dictionary(uniqueKeysWithValues:
                ModelReadinessResolver.evaluateAll(models: selectable, userDefaults: d).map { ($0.modelID, $0) })
            t.checkEqual(states[standardID]?.status, .ready, "PICKER_VISIBILITY_2 Standard is Ready")
            t.checkEqual(states[hqID]?.status, .serverModelMismatch, "PICKER_VISIBILITY_2 Quality is WrongModel")
            t.checkEqual(states[refID]?.status, .serverNotRunning, "PICKER_VISIBILITY_2 Reference is Stopped")
            assertAllThreeVisible(registry, states, "PICKER_VISIBILITY_2 (Ready/WrongModel/Stopped)")
            // And the two non-Ready tiers must still be SELECTABLE (configured).
            t.checkEqual(states[hqID]?.status.isConfigured, true,
                         "PICKER_VISIBILITY_2 WrongModel Quality stays selectable")
            t.checkEqual(states[refID]?.status.isConfigured, true,
                         "PICKER_VISIBILITY_2 Stopped Reference stays selectable")
        }

        // PICKER_VISIBILITY_3: Standard=WrongModel, Quality=Ready, Reference=Stopped -> 3/3 visible
        do {
            let fx = makeH3Fixture()
            let suite = "PickerVis-\(UUID().uuidString)"
            let d = makeAllThreeH3Defaults(
                suite: suite, modelDir: fx.modelDir, runtime: fx.runtime,
                standardState: .wrongModel, highQualityState: .ready, referenceState: .notRunning)
            defer {
                d.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: fx.root)
            }
            let registry = ModelRegistry(userDefaults: d)
            let selectable = registry.selectableModels()
            let states = Dictionary(uniqueKeysWithValues:
                ModelReadinessResolver.evaluateAll(models: selectable, userDefaults: d).map { ($0.modelID, $0) })
            assertAllThreeVisible(registry, states, "PICKER_VISIBILITY_3 (WrongModel/Ready/Stopped)", selectedID: hqID)
        }

        // PICKER_VISIBILITY_4: Standard=Stopped, Quality=WrongModel, Reference=Ready -> 3/3 visible
        do {
            let fx = makeH3Fixture()
            let suite = "PickerVis-\(UUID().uuidString)"
            let d = makeAllThreeH3Defaults(
                suite: suite, modelDir: fx.modelDir, runtime: fx.runtime,
                standardState: .notRunning, highQualityState: .wrongModel, referenceState: .ready)
            defer {
                d.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: fx.root)
            }
            let registry = ModelRegistry(userDefaults: d)
            let selectable = registry.selectableModels()
            let states = Dictionary(uniqueKeysWithValues:
                ModelReadinessResolver.evaluateAll(models: selectable, userDefaults: d).map { ($0.modelID, $0) })
            assertAllThreeVisible(registry, states, "PICKER_VISIBILITY_4 (Stopped/WrongModel/Ready)", selectedID: refID)
        }

        // PICKER_VISIBILITY_5: all three Stopped -> 3/3 visible
        do {
            let fx = makeH3Fixture()
            let suite = "PickerVis-\(UUID().uuidString)"
            let d = makeAllThreeH3Defaults(
                suite: suite, modelDir: fx.modelDir, runtime: fx.runtime,
                standardState: .notRunning, highQualityState: .notRunning, referenceState: .notRunning)
            defer {
                d.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: fx.root)
            }
            let registry = ModelRegistry(userDefaults: d)
            let selectable = registry.selectableModels()
            let states = Dictionary(uniqueKeysWithValues:
                ModelReadinessResolver.evaluateAll(models: selectable, userDefaults: d).map { ($0.modelID, $0) })
            assertAllThreeVisible(registry, states, "PICKER_VISIBILITY_5 (all Stopped)")
        }

        // PICKER_VISIBILITY_6: readiness refresh before/after -> model IDs unchanged
        do {
            let fx = makeH3Fixture()
            let suite = "PickerVis-\(UUID().uuidString)"
            let d = makeAllThreeH3Defaults(
                suite: suite, modelDir: fx.modelDir, runtime: fx.runtime,
                standardState: .ready, highQualityState: .ready, referenceState: .ready)
            defer {
                d.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: fx.root)
            }
            let registry = ModelRegistry(userDefaults: d)
            let selectable = registry.selectableModels()
            let statesBefore = Dictionary(uniqueKeysWithValues:
                ModelReadinessResolver.evaluateAll(models: selectable, userDefaults: d).map { ($0.modelID, $0) })
            let idsBefore = Set(pickerRows(registry: registry, states: statesBefore, selectedID: standardID).map(\.model.id))

            // Simulate a refresh cycle that flips every H3 tier's state.
            d.set(MiniMaxH3RuntimeState.wrongModel.rawValue,
                  forKey: MiniMaxH3Configuration.lastReadinessStateKey(for: standardID))
            d.set(MiniMaxH3RuntimeState.notRunning.rawValue,
                  forKey: MiniMaxH3Configuration.lastReadinessStateKey(for: hqID))
            d.set(MiniMaxH3RuntimeState.failed.rawValue,
                  forKey: MiniMaxH3Configuration.lastReadinessStateKey(for: refID))
            let statesAfter = Dictionary(uniqueKeysWithValues:
                ModelReadinessResolver.evaluateAll(models: selectable, userDefaults: d).map { ($0.modelID, $0) })
            let idsAfter = Set(pickerRows(registry: registry, states: statesAfter, selectedID: standardID).map(\.model.id))

            t.checkEqual(idsBefore, idsAfter, "PICKER_VISIBILITY_6 model ID set is unchanged across a readiness refresh")
            for id in allThree {
                t.check(idsAfter.contains(id), "PICKER_VISIBILITY_6 \(id) still visible after refresh")
            }
        }

        // PICKER_VISIBILITY_7: A -> B -> C -> A selection -> 3/3 visible every time
        do {
            let fx = makeH3Fixture()
            let suite = "PickerVis-\(UUID().uuidString)"
            let d = makeAllThreeH3Defaults(
                suite: suite, modelDir: fx.modelDir, runtime: fx.runtime,
                standardState: .ready, highQualityState: .wrongModel, referenceState: .notRunning)
            defer {
                d.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: fx.root)
            }
            let registry = ModelRegistry(userDefaults: d)
            let selectable = registry.selectableModels()
            let states = Dictionary(uniqueKeysWithValues:
                ModelReadinessResolver.evaluateAll(models: selectable, userDefaults: d).map { ($0.modelID, $0) })

            for (step, selection) in [standardID, hqID, refID, standardID].enumerated() {
                let rows = pickerRows(registry: registry, states: states, selectedID: selection)
                let rowIDs = Set(rows.map(\.model.id))
                for id in allThree {
                    t.check(rowIDs.contains(id), "PICKER_VISIBILITY_7 step \(step) (selected \(selection)): \(id) visible")
                }
            }
        }

        // PICKER_VISIBILITY_8: app-lifecycle-equivalent store rebuild -> 3/3 visible.
        // `ModelReadinessStore` itself is a MainActor singleton and can't be
        // pointed at a fixture, but the meaningful behavior under test — a
        // fresh registry + a fresh readiness evaluation, exactly what
        // relaunching the app produces — is fully exercised here.
        do {
            let fx = makeH3Fixture()
            let suite = "PickerVis-\(UUID().uuidString)"
            let d = makeAllThreeH3Defaults(
                suite: suite, modelDir: fx.modelDir, runtime: fx.runtime,
                standardState: .ready, highQualityState: .ready, referenceState: .ready)
            defer {
                d.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: fx.root)
            }
            // Fresh ModelRegistry instance (mirrors process relaunch reseeding).
            let freshRegistry = ModelRegistry(userDefaults: d)
            let freshSelectable = freshRegistry.selectableModels()
            let freshStates = Dictionary(uniqueKeysWithValues:
                ModelReadinessResolver.evaluateAll(models: freshSelectable, userDefaults: d).map { ($0.modelID, $0) })
            assertAllThreeVisible(freshRegistry, freshStates, "PICKER_VISIBILITY_8 (fresh store/registry)")
        }
    }

    // =====================================================================
    // PICKER_RUNTIME_STATE_REGRESSION_TEST — general guard, not H3-specific.
    // The set of visible picker IDs must never shrink because of a runtime/
    // readiness state change alone. Only an actual registry change (a model
    // removed, or explicitly feature-disabled) may shrink it. Future model
    // additions inherit this guard automatically since it iterates whatever
    // `selectableModels()` currently returns.
    // =====================================================================
    t.suite("PICKER_RUNTIME_STATE_REGRESSION_TEST — visible IDs never shrink from readiness alone") {
        let fx = makeH3Fixture()
        let suite = "PickerRuntimeGuard-\(UUID().uuidString)"
        let d = makeAllThreeH3Defaults(
            suite: suite, modelDir: fx.modelDir, runtime: fx.runtime,
            standardState: .ready, highQualityState: .ready, referenceState: .ready)
        defer {
            d.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: fx.root)
        }
        let registry = ModelRegistry(userDefaults: d)
        let selectable = registry.selectableModels()
        let registeredIDs = Set(selectable.map(\.id))

        func visibleIDs(_ states: [String: ModelReadiness]) -> Set<String> {
            Set(pickerRows(registry: registry, states: states, selectedID: MiniMaxH3Configuration.standardModelID)
                .map(\.model.id))
        }

        let everyState: [MiniMaxH3RuntimeState] = [.notConfigured, .notRunning, .starting, .ready, .wrongModel, .failed, .broken]
        for standardState in everyState {
            for hqState in everyState {
                d.set(standardState.rawValue,
                      forKey: MiniMaxH3Configuration.lastReadinessStateKey(for: MiniMaxH3Configuration.standardModelID))
                d.set(hqState.rawValue,
                      forKey: MiniMaxH3Configuration.lastReadinessStateKey(for: MiniMaxH3Configuration.highQualityModelID))
                let states = Dictionary(uniqueKeysWithValues:
                    ModelReadinessResolver.evaluateAll(models: selectable, userDefaults: d).map { ($0.modelID, $0) })
                let visible = visibleIDs(states)
                t.checkEqual(visible, registeredIDs,
                             "GUARD standard=\(standardState.rawValue) hq=\(hqState.rawValue): visible IDs == registered IDs")
            }
        }
    }
}
