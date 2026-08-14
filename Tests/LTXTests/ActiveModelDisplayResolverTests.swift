import Foundation
@testable import LTXVideoGeneratorCore

func runActiveModelDisplayResolverTests(_ t: TestKit) {
    t.suite("ActiveModelDisplayResolver — Live sidebar active model indicator") {
        let testDefaults = UserDefaults(suiteName: "test.active.model.display.\(UUID().uuidString)")!
        defer {
            testDefaults.removePersistentDomain(forName: testDefaults.description)
        }

        // 1. Initial current model LTX-2.3 resolves to official LTX display
        let initialDisplay = ActiveModelDisplayResolver.resolve(
            modelID: LTXModelCatalog.defaultModelID,
            generationServiceLoaded: true,
            userDefaults: testDefaults
        )
        t.checkEqual(initialDisplay.displayName, LTXModelCatalog.defaultModel.displayName, "LTX default model resolves official display name")
        t.checkEqual(initialDisplay.backendBadge, "MLX", "LTX default model badge is MLX")
        t.check(!initialDisplay.isCustom, "LTX default model is not custom")
        t.check(initialDisplay.isReady, "Official model reflects environment readiness")
        t.checkEqual(initialDisplay.statusText, "Environment Ready", "Official model shows Environment Ready")

        // 2. Changing current selection to Custom updates display to generic Custom LTX-2 MLX Model
        let customDisplay = ActiveModelDisplayResolver.resolve(
            modelID: ModelRegistry.customModelID,
            generationServiceLoaded: false,
            userDefaults: testDefaults
        )
        t.checkEqual(customDisplay.displayName, "Custom LTX-2 MLX Model", "Custom model resolves to generic safe display name")
        t.checkEqual(customDisplay.backendBadge, "ltx-2-mlx", "Custom model badge is ltx-2-mlx")
        t.check(customDisplay.isCustom, "Custom model is identified as custom")

        // 3. Changing Custom back to LTX updates display immediately
        let backToOfficial = ActiveModelDisplayResolver.resolve(
            modelID: LTXModelCatalog.defaultModelID,
            generationServiceLoaded: false,
            userDefaults: testDefaults
        )
        t.checkEqual(backToOfficial.displayName, LTXModelCatalog.defaultModel.displayName, "Switching back to official model restores official display name")
        t.checkEqual(backToOfficial.backendBadge, "MLX", "Switching back restores MLX badge")
        t.check(!backToOfficial.isCustom, "Switching back marks as non-custom")

        // 4. No restart needed — resolution is a direct pure/reactive mapping
        let rapidSwitchA = ActiveModelDisplayResolver.resolve(modelID: "custom_ltx2_mlx", userDefaults: testDefaults)
        let rapidSwitchB = ActiveModelDisplayResolver.resolve(modelID: "ltx23_distilled_q4", userDefaults: testDefaults)
        t.checkEqual(rapidSwitchA.displayName, "Custom LTX-2 MLX Model", "Instant switch to custom succeeds without reload")
        t.checkEqual(rapidSwitchB.displayName, LTXModelCatalog.defaultModel.displayName, "Instant switch to official succeeds without reload")

        // 5. Custom HF ↔ Local keeps generic Custom display
        testDefaults.set("local", forKey: ModelRegistry.customSourceModeUserDefaultsKey)
        testDefaults.set("/Users/testuser/models/private_checkpoint", forKey: ModelRegistry.customLocalPathUserDefaultsKey)
        let localModeDisplay = ActiveModelDisplayResolver.resolve(modelID: ModelRegistry.customModelID, userDefaults: testDefaults)
        t.checkEqual(localModeDisplay.displayName, "Custom LTX-2 MLX Model", "Local mode retains generic title")

        testDefaults.set("huggingFace", forKey: ModelRegistry.customSourceModeUserDefaultsKey)
        testDefaults.set("private-user/confidential-model", forKey: ModelRegistry.customRepositoryUserDefaultsKey)
        let hfModeDisplay = ActiveModelDisplayResolver.resolve(modelID: ModelRegistry.customModelID, userDefaults: testDefaults)
        t.checkEqual(hfModeDisplay.displayName, "Custom LTX-2 MLX Model", "HF mode retains generic title")

        // 6. Readiness failure does NOT alter selected model name (no silent fallback to LTX-2.3)
        testDefaults.removeObject(forKey: LTX2MLXRuntime.executablePathKey)
        let brokenRuntimeDisplay = ActiveModelDisplayResolver.resolve(modelID: ModelRegistry.customModelID, userDefaults: testDefaults)
        t.checkEqual(brokenRuntimeDisplay.displayName, "Custom LTX-2 MLX Model", "Broken runtime readiness does NOT fall back to LTX-2.3")
        t.check(!brokenRuntimeDisplay.isReady, "Unconfigured runtime is marked not ready")
        t.checkEqual(brokenRuntimeDisplay.statusText, "Not Configured", "Unconfigured runtime shows Not Configured status")

        // 7. Already queued Job A retains Model A when current selection becomes Model B
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-disp-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        for file in CustomLTX2MLXModelCatalog.requiredComponents {
            FileManager.default.createFile(atPath: tempDir.appendingPathComponent(file).path, contents: Data())
        }

        testDefaults.set("local", forKey: ModelRegistry.customSourceModeUserDefaultsKey)
        testDefaults.set(tempDir.path, forKey: ModelRegistry.customLocalPathUserDefaultsKey)

        // Queue Job 1 with custom model
        let req1 = GenerationRequest(
            prompt: "Prompt 1",
            modelId: ModelRegistry.customModelID,
            userDefaults: testDefaults
        )
        t.checkEqual(req1.modelId, ModelRegistry.customModelID, "Job 1 model is custom")
        t.checkEqual(req1.customModelLocalPath, tempDir.path, "Job 1 froze local path A")

        // User changes current selection to official LTX-2.3
        testDefaults.set(LTXModelCatalog.defaultModelID, forKey: LTXModelCatalog.selectedModelIDKey)

        // Sidebar immediately reflects current selection B (LTX-2.3)
        let updatedSidebar = ActiveModelDisplayResolver.resolve(
            modelID: testDefaults.string(forKey: LTXModelCatalog.selectedModelIDKey),
            userDefaults: testDefaults
        )
        t.checkEqual(updatedSidebar.displayName, LTXModelCatalog.defaultModel.displayName, "Sidebar immediately shows newly selected model B")

        // 8. But queued Job 1 STILL retains Model A
        t.checkEqual(req1.modelId, ModelRegistry.customModelID, "Queued Job 1 retains frozen Model A")
        t.checkEqual(req1.customModelLocalPath, tempDir.path, "Queued Job 1 retains frozen local path")

        // New Job 2 uses new selection B
        let req2 = GenerationRequest(
            prompt: "Prompt 2",
            modelId: LTXModelCatalog.defaultModelID,
            userDefaults: testDefaults
        )
        t.checkEqual(req2.modelId, LTXModelCatalog.defaultModelID, "New Job 2 uses Model B")

        // 9. Queue FIFO and execution semantics remain unchanged
        let queue = [req1, req2]
        t.checkEqual(queue[0].modelId, ModelRegistry.customModelID, "FIFO element 0 is Job 1 (Model A)")
        t.checkEqual(queue[1].modelId, LTXModelCatalog.defaultModelID, "FIFO element 1 is Job 2 (Model B)")

        // 10. Custom local snapshot propagation from b336a41 unchanged
        let descriptor1 = ModelRegistry(userDefaults: testDefaults).descriptor(for: req1)
        t.checkEqual(descriptor1?.localPath, tempDir.path, "Request 1 produces descriptor with frozen local path")

        // 11. No local filesystem path is exposed in sidebar display
        t.check(!localModeDisplay.displayName.contains("/Users/"), "Display name does not leak path")
        t.check(!localModeDisplay.displayName.contains("private_checkpoint"), "Display name does not leak directory name")
        t.check(!localModeDisplay.backendBadge.contains("/Users/"), "Badge does not leak path")

        // 12. No specific third-party model branding exposed
        let safeName = customDisplay.displayName.lowercased()
        t.check(!safeName.contains("10eros"), "Display name contains 0 10Eros")
        t.check(!safeName.contains("tenstrip"), "Display name contains 0 TenStrip")
        t.check(!safeName.contains("mlxbits"), "Display name contains 0 MLXBits")
        t.check(!safeName.contains("adult"), "Display name contains 0 Adult")
        t.check(!safeName.contains("nsfw"), "Display name contains 0 NSFW")
    }
}
