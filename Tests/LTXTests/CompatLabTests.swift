import Foundation
@testable import LTXVideoGeneratorCore

func runCompatLabTests(_ t: TestKit) {
    let tmpDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("LTXTests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let suiteName = "LTXTests.compat.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    t.suite("Verification gate") {
        let lab = CompatibilityLab(storeURL: tmpDir.appendingPathComponent("lab.json"))
        let modelID = ModelRegistry.customModelID
        t.check(!lab.isVerified(modelID: modelID), "starts unverified")

        // Pass all but one check → still unverified.
        for check in VerificationCheck.allCases.dropLast() {
            lab.record(check, .passed, note: "test", for: modelID)
        }
        t.check(!lab.isVerified(modelID: modelID), "one pending check keeps model unverified")

        // A failed check also keeps it unverified.
        lab.record(VerificationCheck.allCases.last!, .failed, note: "smoke failed", for: modelID)
        t.check(!lab.isVerified(modelID: modelID), "failed check keeps model unverified")

        // All passed → verified.
        lab.record(VerificationCheck.allCases.last!, .passed, note: "smoke ok", for: modelID)
        t.check(lab.isVerified(modelID: modelID), "all checks passed → verified")

        // Registry promotion honors the lab.
        let registry = ModelRegistry(userDefaults: defaults)
        registry.refreshVerification(from: lab)
        t.check(registry.descriptor(id: modelID)?.runtime.verified == true, "refreshVerification promotes")
        do {
            _ = try registry.validateForGeneration(modelID: modelID, customModelsEnabled: true)
            t.check(true, "verified custom model passes generation gate")
        } catch {
            t.check(false, "verified custom model passes generation gate (threw \(error))")
        }

        // Persistence round-trip.
        let lab2 = CompatibilityLab(storeURL: tmpDir.appendingPathComponent("lab.json"))
        t.check(lab2.isVerified(modelID: modelID), "lab state persists across instances")
    }

    t.suite("Manifest validator") {
        let registry = ModelRegistry(userDefaults: defaults)
        let official = registry.descriptor(id: LTXModelCatalog.defaultModelID)!
        t.check(!ManifestValidator.hasBlockingIssues(ManifestValidator.validateDescriptor(official)),
                "official descriptor has no blocking issues")

        let customModel = registry.descriptor(id: ModelRegistry.customModelID)!
        var injected = customModel
        injected.revision = "abc123"
        injected.repository = "evil; rm -rf /"
        t.check(ManifestValidator.validateDescriptor(injected).contains { $0.message.contains("disallowed characters") },
                "shell metacharacters in repo id rejected")

        // Snapshot validation with temp dirs.
        let goodSnap = tmpDir.appendingPathComponent("good")
        try? FileManager.default.createDirectory(at: goodSnap, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: goodSnap.appendingPathComponent("config.json").path, contents: Data("{}".utf8))
        FileManager.default.createFile(atPath: goodSnap.appendingPathComponent("model.safetensors").path, contents: Data([0x01]))
        t.check(!ManifestValidator.hasBlockingIssues(ManifestValidator.validateSnapshot(at: goodSnap.path)),
                "complete snapshot passes")

        let badSnap = tmpDir.appendingPathComponent("bad")
        try? FileManager.default.createDirectory(at: badSnap, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: badSnap.appendingPathComponent("model.safetensors").path, contents: Data())
        let badIssues = ManifestValidator.validateSnapshot(at: badSnap.path)
        t.check(badIssues.contains { $0.message.contains("config.json") }, "missing config detected")
        t.check(badIssues.contains { $0.message.contains("Zero-byte") }, "zero-byte shard detected")
        t.check(ManifestValidator.hasBlockingIssues(ManifestValidator.validateSnapshot(at: tmpDir.appendingPathComponent("nope").path)),
                "missing snapshot dir is blocking")
    }

    t.suite("Model installer") {
        let registry = ModelRegistry(userDefaults: defaults)
        let installer = ModelInstaller(registry: registry, recordsURL: tmpDir.appendingPathComponent("installs.json"))

        // Official model: plan works, no license ack needed.
        do {
            let plan = try installer.planInstall(modelID: LTXModelCatalog.defaultModelID,
                                                 availableDiskBytesOverride: 200_000_000_000)
            t.check(plan.diskPreflightPassed, "official plan passes disk preflight with 200GB free")
            t.check(plan.downloadCommand.contains(plan.repository), "download command references repo")
            t.check(!plan.requiresLicenseAcknowledgement, "official license needs no acknowledgement")
        } catch {
            t.check(false, "official plan (threw \(error))")
        }

        // Insufficient disk fails preflight (22GB model + 10GB headroom > 20GB free).
        do {
            let plan = try installer.planInstall(modelID: LTXModelCatalog.defaultModelID,
                                                 availableDiskBytesOverride: 20_000_000_000)
            t.check(!plan.diskPreflightPassed, "tight disk fails preflight")
        } catch {
            t.check(false, "tight disk plan should not throw (\(error))")
        }

        // Install record with revision.
        do {
            try installer.recordInstall(modelID: ModelRegistry.customModelID, revision: "abc123",
                                        licenseAcknowledged: true, checksumVerified: true)
            t.check(installer.installRecord(modelID: ModelRegistry.customModelID)?.revision == "abc123",
                    "install record persisted with revision")
        } catch {
            t.check(false, "install record (threw \(error))")
        }
    }
}
