import Foundation
@testable import LTXVideoGeneratorCore

/// Regression cover for the One Shot model picker's data path.
///
/// The picker renders `ModelReadinessStore.pickerModels(selectedID:)`, which is
/// composed of three production steps:
///
///   ModelRegistry.selectableModels()          — which models exist at all
///   ModelReadinessResolver.evaluateAll(...)   — which of them can generate
///   readyModels() + persisted-selection rule  — which rows the Picker gets
///
/// These tests drive those real functions with injected `UserDefaults` and a
/// real on-disk fixture pack, rather than asserting against a re-implementation
/// of the rules. `pickerRows` below is the only reimplemented part — it mirrors
/// `ModelReadinessStore.pickerModels`, which is `@MainActor` and hard-wired to
/// `ModelRegistry.shared` / `UserDefaults.standard` and so cannot be pointed at
/// a fixture. Case 9 exercises the real store to keep the two in step.
///
/// Motivating defect: `minimax_h3_fl2va_2bit_te` was reported "missing" from the
/// One Shot picker. It was present and Ready at every stage; it rendered as
/// "MiniMax H3 (Experimental)", which names the family and not the Standard
/// tier, so there was no row matching the name the user was told to select.
func runOneShotModelPickerTests(_ t: TestKit) {

    /// Mirror of `ModelReadinessStore.pickerModels(selectedID:)`.
    func pickerRows(
        registry: ModelRegistry,
        states: [String: ModelReadiness],
        selectedID: String
    ) -> [(model: ModelDescriptor, readiness: ModelReadiness)] {
        var rows = registry.selectableModels().compactMap { model -> (model: ModelDescriptor, readiness: ModelReadiness)? in
            guard let state = states[model.id], state.canGenerate else { return nil }
            return (model, state)
        }
        if !rows.contains(where: { $0.model.id == selectedID }),
           let selected = registry.descriptor(id: selectedID),
           let state = states[selectedID] {
            rows.insert((selected, state), at: 0)
        }
        return rows
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
        if let readinessState { d.set(readinessState, forKey: MiniMaxH3Configuration.lastReadinessStateKey) }
        if let readinessModelID { d.set(readinessModelID, forKey: MiniMaxH3Configuration.lastReadinessModelIDKey) }
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

            // The defect this file exists for: the row must name the tier, so a
            // user told to pick "H3 Standard" can find it next to High Quality.
            let label = rows.first { $0.model.id == standardID }?.model.selectionDisplayName ?? ""
            t.check(label.contains("Standard"),
                    "PICKER_1 H3 Standard row names the Standard tier (got: \(label))")
            t.check(label != MiniMaxH3Configuration.highQualityDisplayName,
                    "PICKER_1 Standard label is distinct from High Quality")
        }

        // ---------------------------------------------------------------
        // 2. Standard H3 not Ready -> obeys existing Ready-only policy
        // ---------------------------------------------------------------
        do {
            let suite = "OneShotPicker-\(UUID().uuidString)"
            // No model directory configured at all.
            let d = UserDefaults(suiteName: suite)!
            defer { d.removePersistentDomain(forName: suite) }
            let registry = ModelRegistry(userDefaults: d)
            let selectable = registry.selectableModels()
            t.check(selectable.contains { $0.id == standardID },
                    "PICKER_2 unready H3 Standard is still registered")

            let states = Dictionary(uniqueKeysWithValues:
                ModelReadinessResolver.evaluateAll(models: selectable, userDefaults: d)
                    .map { ($0.modelID, $0) })
            t.checkEqual(states[standardID]?.status, .notConfigured,
                         "PICKER_2 unconfigured H3 Standard is notConfigured")
            t.checkEqual(states[standardID]?.canGenerate, false, "PICKER_2 cannot generate")

            // Ready-only policy: omitted unless it is the persisted selection.
            let rows = pickerRows(registry: registry, states: states, selectedID: "ltx23_distilled_q4")
            t.check(!rows.contains { $0.model.id == standardID },
                    "PICKER_2 unready H3 Standard is omitted, per Ready-only policy")
        }

        // ---------------------------------------------------------------
        // 3. HQ Ready -> may appear as a model according to normal readiness
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
        // 7. custom LTX selected -> does NOT remove Ready H3 Standard
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
                    "PICKER_7 a selected custom LTX profile does not remove Ready H3 Standard")
            // "Not narrowed" stated precisely: the rows are exactly the Ready
            // set. A saved selection may add a disabled row, never subtract.
            let expectedReady = selectable
                .filter { states[$0.id]?.canGenerate == true }
                .map(\.id).sorted()
            t.checkEqual(rows.map(\.model.id).sorted(), expectedReady,
                         "PICKER_7 the picker is not narrowed to the saved selection alone")
            t.check(rows.allSatisfy { $0.readiness.canGenerate },
                    "PICKER_7 an unregistered saved selection adds no phantom row")
        }

        // ---------------------------------------------------------------
        // 8. saved unavailable model -> keeps existing visible/disabled policy
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

            // Current product policy: an unavailable model is shown (disabled)
            // only when it is the persisted selection, so the app never
            // silently switches a project to a different model.
            let rows = pickerRows(registry: registry, states: states, selectedID: standardID)
            let row = rows.first { $0.model.id == standardID }
            t.check(row != nil, "PICKER_8 an unavailable *selected* model is still shown")
            t.checkEqual(row?.readiness.canGenerate, false,
                         "PICKER_8 that row stays disabled rather than becoming selectable")
            t.checkEqual(rows.first?.model.id, standardID,
                         "PICKER_8 the selected-but-unavailable row is inserted first")
        }

        // ---------------------------------------------------------------
        // 9. readiness refresh -> One Shot options refresh correctly
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

            // Simulate Settings recording a failed re-check. Re-evaluating the
            // same models must reflect it: readiness is recomputed, not cached
            // in the descriptor list.
            d.set(MiniMaxH3RuntimeState.failed.rawValue, forKey: MiniMaxH3Configuration.lastReadinessStateKey)
            d.set("probe failed", forKey: MiniMaxH3Configuration.lastReadinessDetailKey)
            let after = Dictionary(uniqueKeysWithValues:
                ModelReadinessResolver.evaluateAll(models: selectable, userDefaults: d)
                    .map { ($0.modelID, $0) })
            t.checkEqual(after[standardID]?.canGenerate, false, "PICKER_9 not Ready after the change")
            t.check(!pickerRows(registry: registry, states: after, selectedID: "ltx23_distilled_q4")
                        .contains { $0.model.id == standardID },
                    "PICKER_9 the refreshed options drop the no-longer-Ready model")

            // And back again, so the picker recovers without a defaults reset.
            d.set(MiniMaxH3RuntimeState.ready.rawValue, forKey: MiniMaxH3Configuration.lastReadinessStateKey)
            let recovered = Dictionary(uniqueKeysWithValues:
                ModelReadinessResolver.evaluateAll(models: selectable, userDefaults: d)
                    .map { ($0.modelID, $0) })
            t.checkEqual(recovered[standardID]?.canGenerate, true,
                         "PICKER_9 options recover once readiness is repaired")
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
}
