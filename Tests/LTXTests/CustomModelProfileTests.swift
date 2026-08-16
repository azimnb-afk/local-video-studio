import Foundation
@testable import LTXVideoGeneratorCore

func runCustomModelProfileTests(_ t: TestKit) {
    let fileManager = FileManager.default

    t.suite("CustomModelProfile - Codable round-trip") {
        let profileID = UUID()
        let profile = CustomModelProfile(
            id: profileID,
            displayName: "Test Custom Model",
            modelFamily: "LTX",
            runtimeKind: "ltx-2-mlx",
            modelPath: "/path/to/custom_model",
            isEnabled: true,
            createdAt: Date(timeIntervalSince1970: 1700000000)
        )

        do {
            let data = try JSONEncoder().encode(profile)
            let decoded = try JSONDecoder().decode(CustomModelProfile.self, from: data)
            t.checkEqual(decoded.id, profileID, "decoded id matches")
            t.checkEqual(decoded.displayName, "Test Custom Model", "decoded display name matches")
            t.checkEqual(decoded.modelFamily, "LTX", "decoded model family matches")
            t.checkEqual(decoded.runtimeKind, "ltx-2-mlx", "decoded runtime kind matches")
            t.checkEqual(decoded.modelPath, "/path/to/custom_model", "decoded model path matches")
            t.checkEqual(decoded.isEnabled, true, "decoded isEnabled matches")
            t.checkEqual(decoded.modelID, "custom_profile_\(profileID.uuidString)", "modelID prefix matches")
            t.checkEqual(CustomModelProfile.profileID(from: decoded.modelID), profileID, "profileID helper extracts UUID")
        } catch {
            t.check(false, "Codable round-trip failed: \(error)")
        }
    }

    t.suite("CustomModelProfileStore - CRUD & Max 5 Limit") {
        let suiteName = "LTXTests.profiles.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // 1. Initial state: 0 profiles
        var profiles = CustomModelProfileStore.loadProfiles(userDefaults: defaults)
        t.checkEqual(profiles.count, 0, "initial profile count is 0")

        // 2. Add Profile 1
        let p1 = CustomModelProfile(displayName: "Profile 1", modelPath: "/models/p1")
        try? CustomModelProfileStore.addProfile(p1, userDefaults: defaults)
        profiles = CustomModelProfileStore.loadProfiles(userDefaults: defaults)
        t.checkEqual(profiles.count, 1, "profile count is 1 after add")
        t.checkEqual(profiles.first?.displayName, "Profile 1", "profile 1 display name matches")

        // 3. Edit Profile 1
        var p1Edited = p1
        p1Edited.displayName = "Profile 1 Renamed"
        p1Edited.modelPath = "/models/p1_updated"
        try? CustomModelProfileStore.updateProfile(p1Edited, userDefaults: defaults)
        let loadedP1 = CustomModelProfileStore.profile(for: p1.id, userDefaults: defaults)
        t.checkEqual(loadedP1?.displayName, "Profile 1 Renamed", "profile 1 successfully updated")
        t.checkEqual(loadedP1?.modelPath, "/models/p1_updated", "profile 1 path successfully updated")

        // 4. Add profiles up to 4
        let p2 = CustomModelProfile(displayName: "Profile 2", modelPath: "/models/p2")
        let p3 = CustomModelProfile(displayName: "Profile 3", modelPath: "/models/p3")
        let p4 = CustomModelProfile(displayName: "Profile 4", modelPath: "/models/p4")
        try? CustomModelProfileStore.addProfile(p2, userDefaults: defaults)
        try? CustomModelProfileStore.addProfile(p3, userDefaults: defaults)
        try? CustomModelProfileStore.addProfile(p4, userDefaults: defaults)
        profiles = CustomModelProfileStore.loadProfiles(userDefaults: defaults)
        t.checkEqual(profiles.count, 4, "profile count is 4")

        // 5. Add Profile 5 (Limit)
        let p5 = CustomModelProfile(displayName: "Profile 5", modelPath: "/models/p5")
        try? CustomModelProfileStore.addProfile(p5, userDefaults: defaults)
        profiles = CustomModelProfileStore.loadProfiles(userDefaults: defaults)
        t.checkEqual(profiles.count, 5, "profile count reaches max limit of 5")

        // 6. Attempt adding 6th profile -> Must throw maximumProfilesReached
        let p6 = CustomModelProfile(displayName: "Profile 6", modelPath: "/models/p6")
        var threwLimitError = false
        do {
            try CustomModelProfileStore.addProfile(p6, userDefaults: defaults)
        } catch CustomModelProfileStore.StoreError.maximumProfilesReached(let limit) {
            threwLimitError = true
            t.checkEqual(limit, 5, "limit is reported as 5")
        } catch {
            t.check(false, "Unexpected error thrown: \(error)")
        }
        t.check(threwLimitError, "Adding 6th profile throws maximumProfilesReached")
        t.checkEqual(CustomModelProfileStore.loadProfiles(userDefaults: defaults).count, 5, "count remains 5")

        // 7. Remove Profile 3 -> Count becomes 4
        CustomModelProfileStore.removeProfile(id: p3.id, userDefaults: defaults)
        profiles = CustomModelProfileStore.loadProfiles(userDefaults: defaults)
        t.checkEqual(profiles.count, 4, "count becomes 4 after removal")
        t.check(!profiles.contains(where: { $0.id == p3.id }), "removed profile is absent")

        // 8. Now adding a new profile succeeds again
        try? CustomModelProfileStore.addProfile(p6, userDefaults: defaults)
        t.checkEqual(CustomModelProfileStore.loadProfiles(userDefaults: defaults).count, 5, "can add again after slot freed")
    }

    t.suite("CustomModelProfileStore - File safety on removal") {
        let suiteName = "LTXTests.filesafety.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let tmpDir = fileManager.temporaryDirectory.appendingPathComponent("profile_safety_test_\(UUID().uuidString)")
        try? fileManager.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tmpDir) }

        let dummyFile = tmpDir.appendingPathComponent("model.safetensors")
        fileManager.createFile(atPath: dummyFile.path, contents: Data([0x01, 0x02, 0x03]))

        let profile = CustomModelProfile(displayName: "Safety Model", modelPath: tmpDir.path)
        try? CustomModelProfileStore.addProfile(profile, userDefaults: defaults)

        // Remove the profile
        CustomModelProfileStore.removeProfile(id: profile.id, userDefaults: defaults)

        // Verify the directory and dummy file still exist on disk!
        t.check(fileManager.fileExists(atPath: tmpDir.path), "directory was not deleted on profile removal")
        t.check(fileManager.fileExists(atPath: dummyFile.path), "model file was not deleted on profile removal")
    }

    t.suite("CustomModelProfileStore - Legacy Single-Path Migration") {
        let suiteName = "LTXTests.migration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Setup legacy key in UserDefaults
        defaults.set("/legacy/path/to/model", forKey: CustomModelProfileStore.legacyLocalPathUserDefaultsKey)

        // Load profiles -> should trigger one-time migration
        let migrated = CustomModelProfileStore.loadProfiles(userDefaults: defaults)
        t.checkEqual(migrated.count, 1, "migrated exactly 1 profile")
        t.checkEqual(migrated.first?.modelPath, "/legacy/path/to/model", "migrated path matches legacy setting")
        t.checkEqual(migrated.first?.displayName, "Custom LTX-2 MLX Model", "generic migrated display name")

        // Idempotency: load again -> should not create duplicates
        let loadedAgain = CustomModelProfileStore.loadProfiles(userDefaults: defaults)
        t.checkEqual(loadedAgain.count, 1, "idempotent: subsequent loads do not create duplicate profiles")
    }

    t.suite("Generation Resolution & Isolation - Profile A vs Profile B") {
        let suiteName = "LTXTests.isolation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let pA = CustomModelProfile(displayName: "Profile Alpha", modelPath: "/models/alpha")
        let pB = CustomModelProfile(displayName: "Profile Beta", modelPath: "/models/beta")
        try? CustomModelProfileStore.addProfile(pA, userDefaults: defaults)
        try? CustomModelProfileStore.addProfile(pB, userDefaults: defaults)

        // 1. GenerationRequest for Profile A
        let reqA = GenerationRequest(
            prompt: "Video A",
            modelId: pA.modelID,
            userDefaults: defaults
        )
        t.checkEqual(reqA.modelId, pA.modelID, "reqA modelID matches profile A")
        t.checkEqual(reqA.customModelProfileID, pA.id, "reqA bound to profile A UUID")
        t.checkEqual(reqA.customModelDisplayNameSnapshot, "Profile Alpha", "reqA snapshot holds profile A name")
        t.checkEqual(reqA.customModelLocalPath, "/models/alpha", "reqA resolves profile A path")

        // 2. GenerationRequest for Profile B
        let reqB = GenerationRequest(
            prompt: "Video B",
            modelId: pB.modelID,
            userDefaults: defaults
        )
        t.checkEqual(reqB.modelId, pB.modelID, "reqB modelID matches profile B")
        t.checkEqual(reqB.customModelProfileID, pB.id, "reqB bound to profile B UUID")
        t.checkEqual(reqB.customModelDisplayNameSnapshot, "Profile Beta", "reqB snapshot holds profile B name")
        t.checkEqual(reqB.customModelLocalPath, "/models/beta", "reqB resolves profile B path")

        // 3. Verify no cross-contamination
        t.check(reqA.customModelLocalPath != reqB.customModelLocalPath, "profile paths are isolated")
    }

    t.suite("ModelRegistry & GenerationModelResolver with CustomModelProfiles") {
        let suiteName = "LTXTests.registry_profiles.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let p1 = CustomModelProfile(displayName: "Model 1", modelPath: "/models/m1", isEnabled: true)
        let p2Disabled = CustomModelProfile(displayName: "Model 2 (Disabled)", modelPath: "/models/m2", isEnabled: false)
        try? CustomModelProfileStore.addProfile(p1, userDefaults: defaults)
        try? CustomModelProfileStore.addProfile(p2Disabled, userDefaults: defaults)

        let registry = ModelRegistry(userDefaults: defaults)

        // 1. Lookup by ID
        let desc1 = registry.descriptor(id: p1.modelID)
        t.check(desc1 != nil, "descriptor found for enabled profile")
        t.checkEqual(desc1?.displayName, "Model 1", "descriptor display name matches")
        t.checkEqual(desc1?.localPath, "/models/m1", "descriptor local path matches")

        // 2. Selectable models: enabled is present, disabled is filtered out
        let selectable = registry.selectableModels(customModelsEnabled: true)
        t.check(selectable.contains(where: { $0.id == p1.modelID }), "enabled profile is selectable")
        t.check(!selectable.contains(where: { $0.id == p2Disabled.modelID }), "disabled profile is not selectable")

        // 3. GenerationModelResolver resolves profile
        let resolution1 = GenerationModelResolver.resolve(modelID: p1.modelID, registry: registry, userDefaults: defaults)
        switch resolution1 {
        case .runnable(let runnable):
            t.checkEqual(runnable.backend, .ltx2MLX, "routes to ltx-2-mlx backend")
            t.checkEqual(runnable.model.id, p1.modelID, "model id matches")
        case .unsupported:
            t.check(false, "profile 1 should be runnable")
        }

        // 4. Missing / unregistered profile fails closed (no silent fallback)
        let fakeID = "custom_profile_\(UUID().uuidString)"
        let resolutionFake = GenerationModelResolver.resolve(modelID: fakeID, registry: registry, userDefaults: defaults)
        switch resolutionFake {
        case .runnable:
            t.check(false, "unregistered profile must not resolve to runnable")
        case .unsupported(let reason):
            t.checkEqual(reason, .unknownModel(modelID: fakeID), "fails closed as unknown model")
        }
    }

    t.suite("LTX-2.3 Built-in Regression & Backward Compatibility") {
        let suiteName = "LTXTests.regression.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Built-in models resolve as normal without custom profiles
        let resolution23 = GenerationModelResolver.resolve(modelID: "ltx23_distilled_q4", userDefaults: defaults)
        switch resolution23 {
        case .runnable(let runnable):
            t.checkEqual(runnable.backend, .mlxVideoWithAudio, "LTX-2.3 remains on mlxVideoWithAudio backend")
            t.checkEqual(runnable.model.id, "ltx23_distilled_q4", "model id matches")
        case .unsupported:
            t.check(false, "LTX-2.3 must be runnable")
        }

        // Legacy request decoding without customModelProfileID still succeeds
        let legacyJSON = """
        {
            "id": "\(UUID().uuidString)",
            "prompt": "Legacy prompt",
            "negativePrompt": "",
            "voiceoverText": "",
            "voiceoverSource": "mlx-audio",
            "voiceoverVoice": "af_heart",
            "musicEnabled": false,
            "disableAudio": false,
            "gemmaRepetitionPenalty": 1.2,
            "gemmaTopP": 0.9,
            "modelId": "ltx23_distilled_q4",
            "parameters": {
                "numInferenceSteps": 20,
                "guidanceScale": 3.0,
                "width": 512,
                "height": 512,
                "numFrames": 49,
                "fps": 24,
                "vaeTilingMode": "auto",
                "imageStrength": 1.0
            },
            "createdAt": "2026-08-16T00:00:00Z",
            "status": "completed"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let legacyReq = try decoder.decode(GenerationRequest.self, from: legacyJSON)
            t.checkEqual(legacyReq.modelId, "ltx23_distilled_q4", "legacy request decodes modelId")
            t.check(legacyReq.customModelProfileID == nil, "legacy request has nil customModelProfileID")
            t.check(legacyReq.customModelDisplayNameSnapshot == nil, "legacy request has nil snapshot")
        } catch {
            t.check(false, "legacy request decoding failed: \(error)")
        }
    }
}
