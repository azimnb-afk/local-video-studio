import Foundation
@testable import LTXVideoGeneratorCore

private struct H3FakeConnectionFailure: Error {}

private final class H3FakeTransport: MiniMaxH3HTTPTransport {
    var healthStatus = 200
    var healthObject: [String: Any] = ["status": "ok"]
    var modelsStatus = 200
    var modelEntries: [[String: Any]] = [[
        "id": MiniMaxH3Configuration.expectedServerModelID,
        "loaded": true,
        "state": "ready",
    ]]
    /// Simulates "nothing is listening at this endpoint" — the real
    /// URLSessionTransport throws when the connection is refused; the
    /// managed-runtime failure tests need that same catch-branch behavior
    /// without a real socket.
    var shouldThrowConnectionFailure = false

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if shouldThrowConnectionFailure { throw H3FakeConnectionFailure() }
        let path = request.url?.path ?? ""
        let object: Any
        let status: Int
        if path.hasSuffix("/health") {
            object = healthObject
            status = healthStatus
        } else {
            object = ["data": modelEntries]
            status = modelsStatus
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        return (data, response)
    }
}

private final class H3AwaitBox<T>: @unchecked Sendable {
    var value: T?
}

private func h3Await<T>(_ operation: @escaping () async -> T) -> T {
    let semaphore = DispatchSemaphore(value: 0)
    let box = H3AwaitBox<T>()
    Task {
        box.value = await operation()
        semaphore.signal()
    }
    semaphore.wait()
    return box.value!
}

func runMiniMaxH3Tests(_ t: TestKit) {
    t.suite("MiniMax H3 Model / Routing") {
        let suite = "MiniMaxH3Tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("/models/h3", forKey: MiniMaxH3Configuration.modelDirectoryKey)
        defaults.set("/runtimes/mlx-serve", forKey: MiniMaxH3Configuration.runtimeExecutablePathKey)
        defaults.set("http://127.0.0.1:11235", forKey: MiniMaxH3Configuration.endpointKey)

        let registry = ModelRegistry(userDefaults: defaults)
        let descriptor = registry.descriptor(id: MiniMaxH3Configuration.modelID)
        t.check(descriptor != nil, "H3 descriptor is registered")
        t.checkEqual(descriptor?.displayName, "MiniMax H3 (Experimental)", "Experimental marker is explicit")
        t.checkEqual(descriptor?.runtime.backend, GenerationBackendKind.minimaxH3.rawValue, "H3 has a dedicated backend kind")
        t.checkEqual(descriptor?.architecture.modelFamily, "MiniMax H3", "H3 architecture is not presented as LTX")
        t.checkEqual(descriptor?.localPath, "/models/h3", "model path is renderer-scoped configuration")
        t.checkEqual(descriptor?.runtime.executablePath, "/runtimes/mlx-serve", "runtime path stays separate from model path")
        t.checkEqual(descriptor?.runtime.endpoint, "http://127.0.0.1:11235", "endpoint is separate from identity")
        t.check(descriptor?.capabilities.textToVideo == true, "H3 advertises T2V")
        t.check(descriptor?.capabilities.imageToVideo == true, "H3 advertises I2V")
        t.check(descriptor?.capabilities.synchronizedAudio == true, "H3 advertises native audio")
        t.check(descriptor?.capabilities.continuation == true, "H3 advertises continuation")
        t.check(registry.selectableModels(customModelsEnabled: false).contains {
            $0.id == MiniMaxH3Configuration.modelID
        }, "built-in H3 remains selectable when custom profiles are disabled")
        do {
            _ = try registry.validateForGeneration(
                modelID: MiniMaxH3Configuration.modelID,
                customModelsEnabled: false)
            t.check(true, "built-in H3 is not incorrectly gated as a custom profile")
        } catch {
            t.check(false, "built-in H3 policy validation should pass: \(error)")
        }

        let request = GenerationRequest(
            prompt: "A subject turns.",
            modelId: MiniMaxH3Configuration.modelID,
            minimaxH3ModelDirectory: "/frozen/model",
            minimaxH3RuntimeExecutablePath: "/frozen/runtime",
            minimaxH3Endpoint: "http://127.0.0.1:12000",
            userDefaults: defaults)
        let frozen = registry.descriptor(for: request)
        t.checkEqual(frozen?.localPath, "/frozen/model", "resolved descriptor consumes frozen request model path")
        t.checkEqual(frozen?.runtime.executablePath, "/frozen/runtime", "resolved descriptor consumes frozen runtime path")
        t.checkEqual(frozen?.runtime.endpoint, "http://127.0.0.1:12000", "resolved descriptor consumes frozen endpoint")
        defaults.set("/changed/model", forKey: MiniMaxH3Configuration.modelDirectoryKey)
        t.checkEqual(registry.descriptor(for: request)?.localPath, "/frozen/model", "queued request never re-looks-up changed model path")

        let adapter = AdapterRegistry.shared.adapter(for: frozen!)
        t.check(adapter is MiniMaxH3Adapter, "AdapterRegistry routes H3 to MiniMaxH3Adapter")
        t.check(!(adapter is LTX2MLXAdapter), "H3 is not overloaded onto ltx-2-mlx")
        if case .runnable(let runnable) = GenerationModelResolver.resolve(
            modelID: MiniMaxH3Configuration.modelID,
            registry: registry,
            userDefaults: defaults) {
            t.checkEqual(runnable.model.id, MiniMaxH3Configuration.modelID, "resolver preserves stable H3 ID")
            t.checkEqual(runnable.backend, .minimaxH3, "resolver preserves dedicated backend")
            t.check(runnable.model.id != LTXModelCatalog.defaultModelID, "H3 never silently falls back to LTX")
        } else {
            t.check(false, "H3 must resolve as runnable")
        }

        let capabilities = MiniMaxH3Capabilities()
        t.check(!capabilities.referenceVideos, "REF2VA/ref_videos remains unsupported")
        t.check(!capabilities.motionContext, "Motion Context remains unsupported")
        t.check(!capabilities.contextLoop, "Context Loop remains unsupported")
        t.check(capabilities.lastFrameContinuation, "last-frame continuation uses existing I2V semantics")
        t.check(capabilities.chainWindows, "chain_windows capability is explicit")
    }

    t.suite("MiniMax H3 Product Guidance") {
        t.check(MiniMaxH3ProductPolicy.isExperimental,
                "H3 product role remains explicitly Experimental")
        t.check(MiniMaxH3ProductPolicy.modelDescription.contains("Best results with a starting image"),
                "model description recommends image grounding")
        t.check(MiniMaxH3ProductPolicy.modelDescription.contains("Text-only generation may be less consistent"),
                "model description states the measured T2V limitation without calling it broken")
        t.check(MiniMaxH3ProductPolicy.modelDescription.contains("longer sequences may gradually drift"),
                "model description states the measured long-continuation limitation")

        let generate = MiniMaxH3ProductPolicy.recommendation(
            modelID: MiniMaxH3Configuration.modelID,
            context: .normalGenerate,
            hasImage: false)
        let oneShot = MiniMaxH3ProductPolicy.recommendation(
            modelID: MiniMaxH3Configuration.modelID,
            context: .oneShot,
            hasImage: false)
        let autoMovie = MiniMaxH3ProductPolicy.recommendation(
            modelID: MiniMaxH3Configuration.modelID,
            context: .autoMovie,
            hasImage: false)
        t.check(generate?.english.contains("Starting Image") == true,
                "Normal Generate recommends a Starting Image for H3")
        t.check(oneShot?.english.contains("Starting Image") == true,
                "One Shot recommends a Starting Image for H3")
        t.check(autoMovie?.english.contains("Opening Reference") == true,
                "Auto Movie recommends an Opening Reference for H3")
        t.check(generate?.english.contains("remains available") == true,
                "H3 recommendation explicitly remains non-blocking")
        t.check(MiniMaxH3ProductPolicy.recommendation(
            modelID: MiniMaxH3Configuration.modelID,
            context: .normalGenerate,
            hasImage: true) == nil,
                "recommendation disappears after a Starting Image is supplied")
        t.check(MiniMaxH3ProductPolicy.recommendation(
            modelID: MiniMaxH3Configuration.modelID,
            context: .autoMovie,
            hasImage: true) == nil,
                "recommendation disappears after an Opening Reference is supplied")
        t.check(MiniMaxH3ProductPolicy.recommendation(
            modelID: LTXModelCatalog.defaultModelID,
            context: .normalGenerate,
            hasImage: false) == nil,
                "LTX never receives H3-specific recommendation copy")

        let h3TextOnly = GenerationRequest(
            prompt: "A subject walks through a quiet room.",
            sourceImagePath: nil,
            modelId: MiniMaxH3Configuration.modelID)
        t.check(!h3TextOnly.isImageToVideo,
                "H3 request with no image remains valid text-to-video")
        t.check(GenerationSubmissionPolicy.canSubmit(
            prompt: h3TextOnly.prompt, isPreparing: false, blockingError: nil),
                "H3 guidance does not block text-only submission")
        t.check(!h3TextOnly.prompt.contains("Recommended for H3"),
                "product recommendation is not injected into the generation prompt")

        let ltxRequest = GenerationRequest(
            prompt: "An LTX scene remains unchanged.",
            sourceImagePath: nil,
            modelId: LTXModelCatalog.defaultModelID)
        t.checkEqual(ltxRequest.prompt, "An LTX scene remains unchanged.",
                     "LTX prompt is unchanged by H3 product guidance")
    }

    t.suite("MiniMax H3 Local Runtime Readiness") {
        t.checkEqual(
            MiniMaxH3Configuration.defaultEndpoint(bundleIdentifier: "com.localvideostudio.personal"),
            "http://127.0.0.1:11237",
            "fresh Personal profile uses the isolated managed H3 port")
        t.checkEqual(
            MiniMaxH3Configuration.defaultEndpoint(bundleIdentifier: "com.localvideostudio.dev"),
            "http://127.0.0.1:11236",
            "fresh Dev profile uses the isolated managed H3 port")
        t.checkEqual(
            MiniMaxH3Configuration.defaultEndpoint(bundleIdentifier: nil),
            "http://127.0.0.1:11235",
            "bundle-less harness retains the explicit legacy external endpoint")
        t.check(MiniMaxH3Configuration.endpointURL("http://127.0.0.1:11235") != nil, "default localhost endpoint accepted")
        t.check(MiniMaxH3Configuration.endpointURL("http://localhost:11235") != nil, "localhost endpoint accepted")
        t.check(MiniMaxH3Configuration.endpointURL("http://0.0.0.0:11235") == nil, "0.0.0.0 endpoint rejected")
        t.check(MiniMaxH3Configuration.endpointURL("https://127.0.0.1:11235") == nil, "non-local HTTP contract rejected")
        t.check(MiniMaxH3Configuration.endpointURL("http://192.168.1.4:11235") == nil, "LAN endpoint rejected")

        let snapshot = MiniMaxH3Configuration.Snapshot(
            modelDirectory: nil,
            runtimeExecutablePath: nil,
            endpoint: "http://127.0.0.1:11235")
        let transport = H3FakeTransport()
        let manager = MiniMaxH3RuntimeManager()
        var status = h3Await { await manager.status(snapshot: snapshot, transport: transport) }
        t.checkEqual(status.state, .ready, "health plus exact ready model is required and sufficient")
        t.checkEqual(status.ownership, .externallyRunning, "existing compatible server is classified external")

        transport.modelEntries = [["id": "different-model", "loaded": true, "state": "ready"]]
        status = h3Await { await manager.status(snapshot: snapshot, transport: transport) }
        t.checkEqual(status.state, .wrongModel, "healthy wrong-model server is rejected")
        t.checkEqual(status.loadedModelID, "different-model", "wrong model identity is diagnostic")

        transport.modelEntries = [[
            "id": MiniMaxH3Configuration.expectedServerModelID,
            "loaded": true,
            "state": "loading",
        ]]
        status = h3Await { await manager.status(snapshot: snapshot, transport: transport) }
        t.checkEqual(status.state, .starting, "expected model must also report ready")

        transport.healthObject = ["status": "bad"]
        status = h3Await { await manager.status(snapshot: snapshot, transport: transport) }
        t.checkEqual(status.state, .failed, "unhealthy server fails closed")

        let args = MiniMaxH3RuntimeManager.serverArguments(modelDirectory: "/model", port: 11235)
        t.check(args.contains("127.0.0.1"), "app-owned server binds explicit loopback")
        t.check(!args.contains("0.0.0.0"), "app-owned server never binds all interfaces")
        t.check(args.contains("/model"), "server launch receives model directory")
        t.check(args.contains("11235"), "server launch receives configured port")
        t.check(args.contains("--skip-mem-preflight"), "accepted staged H3 model launch bypasses the generic aggregate preflight")
        manager.stopOwnedServer()
        transport.healthObject = ["status": "ok"]
        transport.modelEntries = [[
            "id": MiniMaxH3Configuration.expectedServerModelID,
            "loaded": true,
            "state": "ready",
        ]]
        status = h3Await { await manager.status(snapshot: snapshot, transport: transport) }
        t.checkEqual(status.ownership, .externallyRunning, "stopping app-owned state never claims or stops external server")
    }

    t.suite("MiniMax H3 Managed Runtime Installation") {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MiniMaxH3ManagedRuntimeTests-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        let managedRoot = root.appendingPathComponent("managed", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: source.appendingPathComponent("lib"), withIntermediateDirectories: true)

        var executable = Data([0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0x00, 0x00, 0x01])
        executable.append(Data(repeating: 0, count: 64))
        executable.append(Data("mlx-serve 26.8.9".utf8))
        let executableURL = source.appendingPathComponent("mlx-serve")
        try executable.write(to: executableURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
        try Data("MIT License\nPermission is hereby granted, free of charge\nThe above copyright notice and this permission notice shall be included in all copies or substantial portions".utf8)
            .write(to: source.appendingPathComponent("LICENSE"))
        try Data("mlx-serve\nthird-party software attributions".utf8)
            .write(to: source.appendingPathComponent("NOTICE"))
        try Data("Apache License\nVersion 2.0".utf8)
            .write(to: source.appendingPathComponent("LICENSE-APACHE-2.0"))
        let nativeStub = Data([0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0x00, 0x00, 0x01])
            + Data(repeating: 0, count: 64)
        for relative in [
            "lib/libmlx.dylib", "lib/libmlxc.dylib", "lib/libjaccl.dylib",
            "lib/libllama.dylib", "lib/libwebp.dylib", "lib/libsharpyuv.dylib",
        ] {
            try nativeStub.write(to: source.appendingPathComponent(relative))
        }
        try Data([1, 2, 3]).write(to: source.appendingPathComponent("lib/mlx.metallib"))

        let manager = MiniMaxH3ManagedRuntimeManager(
            runtimesDirectory: managedRoot,
            bundledRuntimeDirectory: source)
        t.checkEqual(manager.evaluateStatus(), .notInstalled, "fresh Dev-style runtime root starts Not Installed")
        t.check(manager.hasBundledRuntimePayload, "shipping payload discovery sees an embedded runtime source")
        let inspected = try manager.inspectBundle(at: source)
        let bundledInspected = try manager.inspectBundledRuntime()
        t.checkEqual(
            bundledInspected.executableSHA256, inspected.executableSHA256,
            "embedded payload discovery inspects the exact accepted source")
        t.checkEqual(inspected.runtimeVersion, "26.8.9", "runtime version is read from the native binary")
        t.checkEqual(inspected.architecture, "arm64", "only the native arm64 bundle is accepted")
        t.checkEqual(inspected.licenseClassification, .bundleAllowed, "complete MIT/NOTICE/Apache files classify BUNDLE_ALLOWED")
        t.checkEqual(inspected.componentSHA256?.count, 11, "manifest snapshots every required runtime component")

        let installed = h3Await { try? await manager.installBundled() }
        t.check(installed != nil, "embedded runtime payload installs without a download or file picker")
        t.check(FileManager.default.fileExists(atPath: executableURL.path), "source runtime remains in place after managed install")
        t.check(FileManager.default.fileExists(atPath: manager.managedExecutableURL.path), "managed executable copy exists")
        t.check(FileManager.default.fileExists(atPath: manager.manifestURL.path), "managed runtime manifest exists")
        if case .ready(let path, let manifest) = manager.evaluateStatus() {
            t.checkEqual(path, manager.managedExecutableURL.path, "Ready resolves the canonical managed executable")
            t.checkEqual(manifest.executableSHA256, inspected.executableSHA256, "manifest freezes executable integrity")
            t.checkEqual(manifest.licenseClassification, .bundleAllowed, "manifest preserves license classification")
        } else {
            t.check(false, "verified managed runtime must evaluate Ready")
        }

        var tamperedExecutable = try Data(contentsOf: manager.managedExecutableURL)
        tamperedExecutable.append(0xff)
        try tamperedExecutable.write(to: manager.managedExecutableURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: manager.managedExecutableURL.path)
        if case .broken(let reason) = manager.evaluateStatus() {
            t.check(!reason.isEmpty, "post-install executable mutation is detected and explained")
        } else {
            t.check(false, "tampered managed executable must evaluate Broken")
        }

        let repaired = h3Await { try? await manager.installBundled() }
        t.check(repaired != nil, "explicit Repair replaces only the broken managed runtime")
        if case .ready = manager.evaluateStatus() {
            t.check(true, "repaired runtime returns to Ready")
        } else {
            t.check(false, "repaired runtime must evaluate Ready")
        }

        let managedLibrary = manager.managedRuntimeDirectory
            .appendingPathComponent("lib/libjaccl.dylib")
        var tamperedLibrary = try Data(contentsOf: managedLibrary)
        tamperedLibrary.append(0xee)
        try tamperedLibrary.write(to: managedLibrary)
        if case .broken(let reason) = manager.evaluateStatus() {
            t.check(reason.contains("component"), "post-install dylib mutation is detected by component SHA")
        } else {
            t.check(false, "tampered managed dylib must evaluate Broken")
        }

        let missingPayloadManager = MiniMaxH3ManagedRuntimeManager(
            runtimesDirectory: root.appendingPathComponent("missing-managed", isDirectory: true),
            bundledRuntimeDirectory: root.appendingPathComponent("missing-payload", isDirectory: true))
        t.check(!missingPayloadManager.hasBundledRuntimePayload, "missing shipping payload is explicit")
        let missingInstall = h3Await { try? await missingPayloadManager.installBundled() }
        t.check(missingInstall == nil, "missing shipping payload fails closed without a download")

        let legacyRoot = root.appendingPathComponent("legacy", isDirectory: true)
        let legacyManager = MiniMaxH3ManagedRuntimeManager(runtimesDirectory: legacyRoot)
        try FileManager.default.createDirectory(
            at: legacyManager.managedRuntimeDirectory, withIntermediateDirectories: true)
        try executable.write(to: legacyManager.managedExecutableURL)
        if case .updateRequired = legacyManager.evaluateStatus() {
            t.check(true, "runtime without the verified manifest evaluates Update Required")
        } else {
            t.check(false, "legacy runtime without manifest must not be treated Ready")
        }

        t.checkEqual(
            MiniMaxH3ManagedRuntimeManager.classifyLicense(
                license: "unclassified", notice: "", apacheLicense: ""),
            .unknown,
            "ambiguous license material remains UNKNOWN")
    }

    t.suite("MiniMax H3 Canonical Runtime Resolution") {
        // resolveRuntimeExecutable is the single place Normal Generate, One
        // Shot, and Auto Movie all resolve H3 runtime readiness through (via
        // MiniMaxH3Backend's single ensureReady call site), so exercising it
        // here covers all three workflows uniformly.
        func writeValidRuntimeBundle(at source: URL) throws {
            try FileManager.default.createDirectory(
                at: source.appendingPathComponent("lib"), withIntermediateDirectories: true)
            var executable = Data([0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0x00, 0x00, 0x01])
            executable.append(Data(repeating: 0, count: 64))
            executable.append(Data("mlx-serve 26.8.9".utf8))
            let executableURL = source.appendingPathComponent("mlx-serve")
            try executable.write(to: executableURL)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
            try Data("MIT License\nPermission is hereby granted, free of charge\nThe above copyright notice and this permission notice shall be included in all copies or substantial portions".utf8)
                .write(to: source.appendingPathComponent("LICENSE"))
            try Data("mlx-serve\nthird-party software attributions".utf8)
                .write(to: source.appendingPathComponent("NOTICE"))
            try Data("Apache License\nVersion 2.0".utf8)
                .write(to: source.appendingPathComponent("LICENSE-APACHE-2.0"))
            let nativeStub = Data([0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0x00, 0x00, 0x01])
                + Data(repeating: 0, count: 64)
            for relative in [
                "lib/libmlx.dylib", "lib/libmlxc.dylib", "lib/libjaccl.dylib",
                "lib/libllama.dylib", "lib/libwebp.dylib", "lib/libsharpyuv.dylib",
            ] {
                try nativeStub.write(to: source.appendingPathComponent(relative))
            }
            try Data([1, 2, 3]).write(to: source.appendingPathComponent("lib/mlx.metallib"))
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MiniMaxH3ResolverTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // H3 One Shot + runtime missing: no manual executable selection is
        // offered or required; the user gets Install guidance instead of the
        // obsolete developer-oriented message.
        let notInstalled = MiniMaxH3ManagedRuntimeManager(
            runtimesDirectory: root.appendingPathComponent("not-installed", isDirectory: true))
        let notInstalledRuntimeManager = MiniMaxH3RuntimeManager(managedRuntimeManager: notInstalled)
        do {
            _ = try notInstalledRuntimeManager.resolveRuntimeExecutable(configuredPath: nil)
            t.check(false, "missing managed runtime must not silently resolve")
        } catch let error as MiniMaxH3Error {
            let message = error.localizedDescription
            t.check(message.contains("Settings"), "Not Installed guidance points to Settings")
            t.check(message.contains("Models & Features"), "Not Installed guidance names the exact menu")
            t.check(!message.contains("Select an executable"), "obsolete developer-oriented wording is gone")
        }

        // H3 One Shot + runtime ready: a Ready managed runtime resolves
        // automatically with zero manual path selection.
        let readySource = root.appendingPathComponent("ready-source", isDirectory: true)
        try writeValidRuntimeBundle(at: readySource)
        let readyManaged = MiniMaxH3ManagedRuntimeManager(
            runtimesDirectory: root.appendingPathComponent("ready-managed", isDirectory: true),
            bundledRuntimeDirectory: readySource)
        let installedManifest = h3Await { try? await readyManaged.installBundled() }
        t.check(installedManifest != nil, "fixture managed runtime installs cleanly")
        let readyRuntimeManager = MiniMaxH3RuntimeManager(managedRuntimeManager: readyManaged)
        let resolvedManagedPath = try readyRuntimeManager.resolveRuntimeExecutable(configuredPath: nil)
        t.checkEqual(
            resolvedManagedPath, readyManaged.managedExecutableURL.path,
            "Ready managed runtime resolves automatically without a manual path")

        // H3 One Shot + compatible external server: an explicit Advanced
        // override remains authoritative even when a managed runtime is Ready.
        let overrideSource = root.appendingPathComponent("override", isDirectory: true)
        try writeValidRuntimeBundle(at: overrideSource)
        let overridePath = overrideSource.appendingPathComponent("mlx-serve").path
        let overrideResolved = try readyRuntimeManager.resolveRuntimeExecutable(configuredPath: overridePath)
        t.checkEqual(
            overrideResolved, overridePath,
            "an explicit Advanced executable path wins over the managed runtime")

        // A stale/removed Advanced override must not block generation when a
        // managed runtime is Ready — it falls back rather than failing.
        let staleResolved = try readyRuntimeManager.resolveRuntimeExecutable(
            configuredPath: root.appendingPathComponent("does-not-exist").path)
        t.checkEqual(
            staleResolved, readyManaged.managedExecutableURL.path,
            "a stale Advanced override falls back to the Ready managed runtime")

        // H3 One Shot + runtime broken: distinct Repair guidance, never the
        // generic "select an executable" message.
        var tampered = try Data(contentsOf: readyManaged.managedExecutableURL)
        tampered.append(0xff)
        try tampered.write(to: readyManaged.managedExecutableURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: readyManaged.managedExecutableURL.path)
        do {
            _ = try readyRuntimeManager.resolveRuntimeExecutable(configuredPath: nil)
            t.check(false, "a Broken managed runtime must not silently resolve")
        } catch let error as MiniMaxH3Error {
            let message = error.localizedDescription
            t.check(message.contains("Repair"), "Broken guidance offers Repair, not Select")
            t.check(message.contains("Settings"), "Broken guidance points to Settings")
            t.check(!message.contains("Select an executable"), "obsolete developer-oriented wording is gone")
        }

        // Managed runtime predates the verified manifest format: Update
        // Required is distinct from both Not Installed and Broken.
        let legacyManaged = MiniMaxH3ManagedRuntimeManager(
            runtimesDirectory: root.appendingPathComponent("legacy", isDirectory: true))
        try FileManager.default.createDirectory(
            at: legacyManaged.managedRuntimeDirectory, withIntermediateDirectories: true)
        let legacySource = root.appendingPathComponent("legacy-source", isDirectory: true)
        try writeValidRuntimeBundle(at: legacySource)
        try FileManager.default.copyItem(
            at: legacySource.appendingPathComponent("mlx-serve"),
            to: legacyManaged.managedExecutableURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: legacyManaged.managedExecutableURL.path)
        let legacyRuntimeManager = MiniMaxH3RuntimeManager(managedRuntimeManager: legacyManaged)
        do {
            _ = try legacyRuntimeManager.resolveRuntimeExecutable(configuredPath: nil)
            t.check(false, "an Update Required managed runtime must not silently resolve")
        } catch let error as MiniMaxH3Error {
            let message = error.localizedDescription
            t.check(message.contains("Update"), "Update Required guidance is distinct wording")
            t.check(message.contains("Settings"), "Update Required guidance points to Settings")
        }
    }

    t.suite("MiniMax H3 Model Directory Resolution") {
        // Reproduces the reported bug: a user-chosen H3 model folder is
        // naturally the *container* folder (what a folder picker shows by
        // default), not the concrete model pack one level inside it — real
        // MiniMax-H3 downloads land exactly this way. The old flat
        // directoryExists() check accepted the container folder as
        // "Configured" and only failed once mlx-serve exited with
        // FileNotFound at server start.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MiniMaxH3ModelDirTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = MiniMaxH3RuntimeManager()

        // A directory that directly contains config.json resolves as-is.
        let concretePack = root.appendingPathComponent("concrete", isDirectory: true)
        try FileManager.default.createDirectory(at: concretePack, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: concretePack.appendingPathComponent("config.json"))
        let resolvedConcrete = try manager.resolveModelDirectory(concretePack.path)
        t.checkEqual(resolvedConcrete, concretePack.path, "a directory with config.json resolves directly")

        // A container folder with the real pack one level inside resolves to
        // the concrete subfolder, not the container itself.
        let container = root.appendingPathComponent("container", isDirectory: true)
        let nestedPack = container.appendingPathComponent(
            MiniMaxH3Configuration.expectedServerModelID, isDirectory: true)
        try FileManager.default.createDirectory(at: nestedPack, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: nestedPack.appendingPathComponent("config.json"))
        let resolvedNested = try manager.resolveModelDirectory(container.path)
        t.checkEqual(resolvedNested, nestedPack.path,
                     "a container folder resolves to its concrete model pack subfolder")

        // A folder with no valid pack anywhere in it (or one level deep)
        // must fail with a distinct, actionable message — never silently
        // report Configured and defer the failure to server startup.
        let empty = root.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        do {
            _ = try manager.resolveModelDirectory(empty.path)
            t.check(false, "a folder with no model files anywhere must not silently resolve")
        } catch let error as MiniMaxH3Error {
            let message = error.localizedDescription
            t.check(message.contains("config.json"), "model-missing guidance names the concrete signal checked")
            t.check(message.contains(MiniMaxH3Configuration.expectedServerModelID),
                    "model-missing guidance names the exact expected model folder")
        }

        // Nil / nonexistent path keeps the original, distinct "not
        // configured" message — never confused with the runtime message.
        do {
            _ = try manager.resolveModelDirectory(nil)
            t.check(false, "a missing model directory must not silently resolve")
        } catch let error as MiniMaxH3Error {
            if case .runtimeNotConfigured(let detail) = error {
                t.checkEqual(detail, "Select the local MiniMax H3 model directory.",
                             "unset model directory keeps its original distinct message")
            } else {
                t.check(false, "expected runtimeNotConfigured for a missing model directory")
            }
        }
    }

    t.suite("MiniMax H3 Server Status Lifecycle — ensureReady") {
        // Every H3 workflow calls ensureReady() through MiniMaxH3Backend's
        // single call site, and its final state is written to the same
        // UserDefaults keys (minimaxH3LastReadinessState/Detail) the sidebar
        // (ActiveModelDisplayResolver) reads on every redraw. This proves
        // the sidebar actually sees Stopped -> Starting -> Ready/Failed
        // during a real generation attempt, not a stale Settings-only
        // snapshot — and that a process that exits before Ready surfaces
        // its stderr instead of the old bare "exited before becoming ready."
        func writeFakeRuntime(at url: URL, script: String) throws {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(script.utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MiniMaxH3EnsureReadyTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let modelDir = root.appendingPathComponent("model", isDirectory: true)
        try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: modelDir.appendingPathComponent("config.json"))

        let testSuiteName = "test.h3.ensureready.\(UUID().uuidString)"
        let tempDefaults = UserDefaults(suiteName: testSuiteName)!
        defer { tempDefaults.removePersistentDomain(forName: testSuiteName) }

        // CASE: the process exits immediately with a diagnostic on stderr —
        // the exact shape of the real "mlx-serve exited before becoming
        // ready" incident (reproduced manually against the real managed
        // binary with a wrong model path: "error: FileNotFound").
        let crashingRuntime = root.appendingPathComponent("crashing-mlx-serve")
        try writeFakeRuntime(
            at: crashingRuntime,
            script: "#!/bin/sh\necho 'error: FileNotFound' >&2\nexit 1\n")

        let crashManager = MiniMaxH3RuntimeManager(userDefaults: tempDefaults)
        let crashTransport = H3FakeTransport()
        crashTransport.shouldThrowConnectionFailure = true // nothing is ever listening
        let crashSnapshot = MiniMaxH3Configuration.Snapshot(
            modelDirectory: modelDir.path,
            runtimeExecutablePath: crashingRuntime.path,
            endpoint: "http://127.0.0.1:19981")

        var capturedStartingState: String?
        var thrownDetail: String?
        h3Await {
            do {
                _ = try await crashManager.ensureReady(
                    snapshot: crashSnapshot,
                    transport: crashTransport,
                    progress: { _, _ in
                        if capturedStartingState == nil {
                            capturedStartingState = tempDefaults.string(
                                forKey: MiniMaxH3Configuration.lastReadinessStateKey)
                        }
                    })
            } catch {
                thrownDetail = error.localizedDescription
            }
        }

        t.checkEqual(capturedStartingState, MiniMaxH3RuntimeState.starting.rawValue,
                     "the sidebar's persisted state reaches Starting before the process is judged")
        t.check(thrownDetail?.contains("error: FileNotFound") == true,
                "process-exit failure preserves the real stderr instead of a bare generic message")
        t.checkEqual(
            tempDefaults.string(forKey: MiniMaxH3Configuration.lastReadinessStateKey),
            MiniMaxH3RuntimeState.failed.rawValue,
            "a start failure is surfaced as Failed, never left silently as Stopped")
        t.check(
            tempDefaults.string(forKey: MiniMaxH3Configuration.lastReadinessDetailKey)?
                .contains("error: FileNotFound") == true,
            "the persisted detail the sidebar reads also carries the real stderr")

        // CASE: a compatible server is already healthy — no process needs to
        // start, and the sidebar snapshot still ends at Ready.
        let readyManager = MiniMaxH3RuntimeManager(userDefaults: tempDefaults)
        let readyTransport = H3FakeTransport()
        let readySnapshot = MiniMaxH3Configuration.Snapshot(
            modelDirectory: modelDir.path,
            runtimeExecutablePath: crashingRuntime.path,
            endpoint: "http://127.0.0.1:19982")
        let readyResult = h3Await {
            try? await readyManager.ensureReady(snapshot: readySnapshot, transport: readyTransport)
        }
        t.check(readyResult?.isReady == true, "an already-healthy compatible server resolves Ready")
        t.checkEqual(
            tempDefaults.string(forKey: MiniMaxH3Configuration.lastReadinessStateKey),
            MiniMaxH3RuntimeState.ready.rawValue,
            "the sidebar's persisted state reaches Ready, matching real generation readiness")
    }

    t.suite("MiniMax H3 Shipping Payload Contract") {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let embedScript = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "scripts/embed-minimax-h3-runtime.sh"), encoding: .utf8)
        let releaseScript = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "scripts/build-release.sh"), encoding: .utf8)
        let devScript = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "scripts/build-dev-app.sh"), encoding: .utf8)
        let personalScript = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "scripts/install-personal-app.sh"), encoding: .utf8)
        let settingsSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "LTXVideoGenerator/Sources/Views/ModelsAndFeaturesPreferences.swift"),
            encoding: .utf8)

        t.check(embedScript.contains("f1cbcdf9ee4c54a23da0a3f0f9c91e5a4d1691beb366bae9eaaa9c5c8523e60a"),
                "shipping build pins the exact accepted runtime executable SHA")
        t.check(embedScript.contains("modelIncluded\": false"),
                "shipping payload manifest explicitly excludes the H3 model")
        t.check(!embedScript.contains("curl ") && !embedScript.contains("ollama pull"),
                "runtime packaging has no hidden network or model-download path")
        t.check(embedScript.contains("APP_SIGN_ARGS=(--force --sign \"${SIGN_IDENTITY}\")")
                && embedScript.contains("APP_SIGN_ARGS+=(--options runtime --timestamp)"),
                "local ad-hoc apps avoid Team-ID library validation while distribution remains hardened")
        t.check(releaseScript.contains("MINIMAX_H3_RUNTIME_PAYLOAD_SOURCE"),
                "distribution build requires an explicit audited payload source")
        t.check(releaseScript.contains("embed-minimax-h3-runtime.sh")
                && devScript.contains("embed-minimax-h3-runtime.sh")
                && personalScript.contains("embed-minimax-h3-runtime.sh"),
                "Dev, Personal install, and release builds share one payload mechanism")
        t.check(settingsSource.contains("Install Runtime")
                && settingsSource.contains("never downloaded automatically"),
                "first-run UI separates runtime installation from user-supplied model configuration")
    }

    t.suite("MiniMax H3 Duration / Frames") {
        let oneSecond = try MiniMaxH3DurationPolicy.plan(requestedDurationSeconds: 1.0)
        t.checkEqual(oneSecond.windowFrames, 22, "short request selects nearest valid 17k+5 rung")
        t.checkEqual(oneSecond.chainWindows, 1, "short request is single-window")
        let normal = try MiniMaxH3DurationPolicy.plan(requestedDurationSeconds: 2.3)
        t.checkEqual(normal.windowFrames, 56, "normal 2.3-second request selects 56 frames")
        t.checkEqual(normal.expectedTotalFrames, 56, "single-window effective frames are explicit")
        let chain2 = try MiniMaxH3DurationPolicy.plan(requestedDurationSeconds: 3.2)
        t.checkEqual(chain2.chainWindows, 2, "3.2 seconds selects proven chain 2")
        t.checkEqual(chain2.expectedTotalFrames, 77, "chain 2 uses one-frame overlap")
        let chain4 = try MiniMaxH3DurationPolicy.plan(requestedDurationSeconds: 6.4)
        t.checkEqual(chain4.chainWindows, 4, "6.4 seconds selects chain 4")
        t.checkEqual(chain4.expectedTotalFrames, 153, "chain 4 expects 153 returned frames")
        t.checkEqual(chain4.expectedDurationSeconds, 6.375, "chain 4 expected duration is 153/24")

        for frames in MiniMaxH3DurationPolicy.singleWindowFrames {
            t.check((frames - 5) % 17 == 0, "\(frames) follows the 17k+5 ladder")
        }

        var parameters = GenerationParameters.default
        parameters.width = 768
        parameters.height = 512
        parameters.numFrames = 144

        // 1. Default preset = Standard (landscape & portrait)
        let defaultReq = GenerationRequest(
            prompt: "A person turns toward camera.",
            modelId: MiniMaxH3Configuration.modelID,
            parameters: parameters)
        let defaultResolved = try MiniMaxH3DurationPolicy.applying(to: defaultReq)
        t.checkEqual(defaultResolved.parameters.width, 640, "Default H3 is Standard landscape width 640")
        t.checkEqual(defaultResolved.parameters.height, 384, "Default H3 is Standard landscape height 384")
        t.checkEqual(defaultResolved.parameters.numFrames, 90, "Default H3 is Standard 90 frames")
        t.checkEqual(defaultResolved.parameters.numInferenceSteps, 16, "Default H3 is Standard 16 steps")

        // 2. Quick landscape: 512x288, 73f, 8 steps
        let quickReq = GenerationRequest(
            prompt: "A person turns toward camera.",
            modelId: MiniMaxH3Configuration.modelID,
            parameters: parameters,
            preset: MiniMaxH3Preset.quick.rawValue)
        let quickResolved = try MiniMaxH3DurationPolicy.applying(to: quickReq)
        t.checkEqual(quickResolved.parameters.width, 512, "Quick landscape width 512")
        t.checkEqual(quickResolved.parameters.height, 288, "Quick landscape height 288")
        t.checkEqual(quickResolved.parameters.numFrames, 73, "Quick frames 73")
        t.checkEqual(quickResolved.parameters.numInferenceSteps, 8, "Quick steps 8")

        // 3. Quick portrait: 288x512, 73f, 8 steps
        let quickPortraitReq = GenerationRequest(
            prompt: "A person turns toward camera.",
            presetResolutionOrientation: .portrait,
            modelId: MiniMaxH3Configuration.modelID,
            parameters: parameters,
            preset: MiniMaxH3Preset.quick.rawValue)
        let quickPortraitResolved = try MiniMaxH3DurationPolicy.applying(to: quickPortraitReq)
        t.checkEqual(quickPortraitResolved.parameters.width, 288, "Quick portrait width 288")
        t.checkEqual(quickPortraitResolved.parameters.height, 512, "Quick portrait height 512")
        t.checkEqual(quickPortraitResolved.parameters.numFrames, 73, "Quick portrait frames 73")
        t.checkEqual(quickPortraitResolved.parameters.numInferenceSteps, 8, "Quick portrait steps 8")

        // 4. Standard landscape: 640x384, 90f, 16 steps
        let standardReq = GenerationRequest(
            prompt: "A person turns toward camera.",
            modelId: MiniMaxH3Configuration.modelID,
            parameters: parameters,
            preset: MiniMaxH3Preset.standard.rawValue)
        let standardResolved = try MiniMaxH3DurationPolicy.applying(to: standardReq)
        t.checkEqual(standardResolved.parameters.width, 640, "Standard landscape width 640")
        t.checkEqual(standardResolved.parameters.height, 384, "Standard landscape height 384")
        t.checkEqual(standardResolved.parameters.numFrames, 90, "Standard landscape frames 90")
        t.checkEqual(standardResolved.parameters.numInferenceSteps, 16, "Standard landscape steps 16")

        // 5. Standard portrait: 384x640, 90f, 16 steps
        let standardPortraitReq = GenerationRequest(
            prompt: "A person turns toward camera.",
            presetResolutionOrientation: .portrait,
            modelId: MiniMaxH3Configuration.modelID,
            parameters: parameters,
            preset: MiniMaxH3Preset.standard.rawValue)
        let standardPortraitResolved = try MiniMaxH3DurationPolicy.applying(to: standardPortraitReq)
        t.checkEqual(standardPortraitResolved.parameters.width, 384, "Standard portrait width 384")
        t.checkEqual(standardPortraitResolved.parameters.height, 640, "Standard portrait height 640")
        t.checkEqual(standardPortraitResolved.parameters.numFrames, 90, "Standard portrait frames 90")
        t.checkEqual(standardPortraitResolved.parameters.numInferenceSteps, 16, "Standard portrait steps 16")

        // 6. High landscape: 640x384, 90f, 20 steps
        let highReq = GenerationRequest(
            prompt: "A person turns toward camera.",
            modelId: MiniMaxH3Configuration.modelID,
            parameters: parameters,
            preset: MiniMaxH3Preset.high.rawValue)
        let highResolved = try MiniMaxH3DurationPolicy.applying(to: highReq)
        t.checkEqual(highResolved.parameters.width, 640, "High landscape width 640")
        t.checkEqual(highResolved.parameters.height, 384, "High landscape height 384")
        t.checkEqual(highResolved.parameters.numFrames, 90, "High landscape frames 90")
        t.checkEqual(highResolved.parameters.numInferenceSteps, 20, "High landscape steps 20")

        // 7. High portrait: 384x640, 90f, 20 steps
        let highPortraitReq = GenerationRequest(
            prompt: "A person turns toward camera.",
            presetResolutionOrientation: .portrait,
            modelId: MiniMaxH3Configuration.modelID,
            parameters: parameters,
            preset: MiniMaxH3Preset.high.rawValue)
        let highPortraitResolved = try MiniMaxH3DurationPolicy.applying(to: highPortraitReq)
        t.checkEqual(highPortraitResolved.parameters.width, 384, "High portrait width 384")
        t.checkEqual(highPortraitResolved.parameters.height, 640, "High portrait height 640")
        t.checkEqual(highPortraitResolved.parameters.numFrames, 90, "High portrait frames 90")
        t.checkEqual(highPortraitResolved.parameters.numInferenceSteps, 20, "High portrait steps 20")

        // 8. Custom Tier 1 portrait
        var customTier1Params = parameters
        customTier1Params.width = 288
        customTier1Params.height = 512
        customTier1Params.numInferenceSteps = 15
        let customTier1Req = GenerationRequest(
            prompt: "A custom shot.",
            presetResolutionOrientation: .portrait,
            modelId: MiniMaxH3Configuration.modelID,
            parameters: customTier1Params,
            preset: MiniMaxH3Preset.custom.rawValue,
            targetDurationSeconds: 3.0)
        let customTier1Resolved = try MiniMaxH3DurationPolicy.applying(to: customTier1Req)
        t.checkEqual(customTier1Resolved.parameters.width, 288, "Custom Tier 1 portrait width 288")
        t.checkEqual(customTier1Resolved.parameters.height, 512, "Custom Tier 1 portrait height 512")
        t.checkEqual(customTier1Resolved.parameters.numFrames, 73, "Custom 3s frames 73")
        t.checkEqual(customTier1Resolved.parameters.numInferenceSteps, 15, "Custom steps preserved 15")

        // 9. Custom Tier 2 portrait
        var customTier2Params = parameters
        customTier2Params.width = 384
        customTier2Params.height = 640
        customTier2Params.numInferenceSteps = 18
        let customTier2Req = GenerationRequest(
            prompt: "A custom shot tier 2.",
            presetResolutionOrientation: .portrait,
            modelId: MiniMaxH3Configuration.modelID,
            parameters: customTier2Params,
            preset: MiniMaxH3Preset.custom.rawValue,
            targetDurationSeconds: 5.0)
        let customTier2Resolved = try MiniMaxH3DurationPolicy.applying(to: customTier2Req)
        t.checkEqual(customTier2Resolved.parameters.width, 384, "Custom Tier 2 portrait width 384")
        t.checkEqual(customTier2Resolved.parameters.height, 640, "Custom Tier 2 portrait height 640")
        t.checkEqual(customTier2Resolved.parameters.numFrames, 124, "Custom 5s frames 124")
        t.checkEqual(customTier2Resolved.parameters.numInferenceSteps, 18, "Custom steps preserved 18")

        // 10. Frame grid snapping test (17k + 5 ladder)
        t.checkEqual(MiniMaxH3FrameGrid.legalFrames(forRequestedDurationSeconds: 1.0), 22, "1.0s -> 22 frames (k=1)")
        t.checkEqual(MiniMaxH3FrameGrid.legalFrames(forRequestedDurationSeconds: 2.0), 56, "2.0s -> 56 frames (k=3)")
        t.checkEqual(MiniMaxH3FrameGrid.legalFrames(forRequestedDurationSeconds: 3.0), 73, "3.0s -> 73 frames (k=4)")
        t.checkEqual(MiniMaxH3FrameGrid.legalFrames(forRequestedDurationSeconds: 4.0), 90, "4.0s -> 90 frames (k=5)")
        t.checkEqual(MiniMaxH3FrameGrid.legalFrames(forRequestedDurationSeconds: 5.0), 124, "5.0s -> 124 frames (k=7)")
        t.checkEqual(MiniMaxH3FrameGrid.legalFrames(forRequestedDurationSeconds: 6.0), 141, "6.0s -> 141 frames (k=8)")

        // 11 & 12. Long duration warning threshold (>= 5.0s)
        t.check(!MiniMaxH3FrameGrid.shouldShowLongDurationWarning(durationSeconds: 4.0), "4.0s no warning")
        t.check(!MiniMaxH3FrameGrid.shouldShowLongDurationWarning(durationSeconds: 4.5), "4.5s no warning")
        t.check(MiniMaxH3FrameGrid.shouldShowLongDurationWarning(durationSeconds: 5.0), "5.0s has warning")
        t.check(MiniMaxH3FrameGrid.shouldShowLongDurationWarning(durationSeconds: 6.0), "6.0s has warning")

        // 13 & 14. Custom steps clamping (min 8, max 24)
        var clampedMinParams = parameters
        clampedMinParams.numInferenceSteps = 2
        let customMinReq = GenerationRequest(
            prompt: "Min steps test",
            modelId: MiniMaxH3Configuration.modelID,
            parameters: clampedMinParams,
            preset: MiniMaxH3Preset.custom.rawValue)
        let customMinResolved = try MiniMaxH3DurationPolicy.applying(to: customMinReq)
        t.checkEqual(customMinResolved.parameters.numInferenceSteps, 8, "Clamped minimum steps to 8")

        // 15. Source Image: FL2VA preserved
        let fl2vaReq = GenerationRequest(
            prompt: "A FL2VA test.",
            sourceImagePath: "/tmp/fake_source.png",
            presetResolutionOrientation: .portrait,
            modelId: MiniMaxH3Configuration.modelID,
            parameters: parameters,
            preset: MiniMaxH3Preset.standard.rawValue)
        let fl2vaResolved = try MiniMaxH3DurationPolicy.applying(to: fl2vaReq)
        t.checkEqual(fl2vaResolved.sourceImagePath, "/tmp/fake_source.png", "FL2VA source image preserved")
        t.checkEqual(fl2vaResolved.parameters.width, 384, "FL2VA portrait width resolved")
        t.checkEqual(fl2vaResolved.parameters.height, 640, "FL2VA portrait height resolved")

        // 16. No Source Image: T2VA preserved
        let t2vaReq = GenerationRequest(
            prompt: "A T2VA text-only test.",
            sourceImagePath: nil,
            modelId: MiniMaxH3Configuration.modelID,
            parameters: parameters,
            preset: MiniMaxH3Preset.standard.rawValue)
        let t2vaResolved = try MiniMaxH3DurationPolicy.applying(to: t2vaReq)
        t.check(t2vaResolved.sourceImagePath == nil, "T2VA has no source image")
        t.checkEqual(t2vaResolved.parameters.width, 640, "T2VA landscape default width")
        t.checkEqual(t2vaResolved.parameters.height, 384, "T2VA landscape default height")

        // 17. LTX preset behavior unchanged (GenerationPreset.standard / quick / high)
        let ltxStandard = GenerationPreset.standard
        t.checkEqual(ltxStandard.displayName, "Standard", "LTX Standard displayName unchanged")
        t.checkEqual(ltxStandard.qualityMode, .auto, "LTX Standard qualityMode is auto")

        // 18 & 19. H3 <-> LTX switch persistence isolation
        let ltxPresetRaw = GenerationPreset.highQuality.rawValue
        let h3PresetRaw = MiniMaxH3Preset.quick.rawValue
        t.checkEqual(GenerationPreset(rawValue: ltxPresetRaw)?.displayName, "High Quality", "LTX preset intact")
        t.checkEqual(MiniMaxH3Preset(rawValue: h3PresetRaw)?.displayName, "Quick", "H3 preset intact")

        // 20. One Shot with H3 Preset Standard resolves cleanly to 90f, 16 steps
        let oneShotReq = GenerationRequest(
            prompt: "One shot brief.",
            modelId: MiniMaxH3Configuration.modelID,
            parameters: parameters,
            preset: MiniMaxH3Preset.standard.rawValue,
            targetDurationSeconds: 4.0,
            generationSource: "oneShot")
        let oneShotResolved = try MiniMaxH3DurationPolicy.applying(to: oneShotReq)
        t.checkEqual(oneShotResolved.parameters.numFrames, 90, "One shot Standard resolves to 90 frames")
        t.checkEqual(oneShotResolved.parameters.numInferenceSteps, 16, "One shot Standard resolves to 16 steps")
        t.checkEqual(oneShotResolved.minimaxH3ChainWindows, 1, "One shot Standard uses 1 window")

        // 21. Auto Movie with H3 Preset Quick resolves to 73f, 8 steps per shot
        let autoMovieReq = GenerationRequest(
            prompt: "Auto movie segment.",
            modelId: MiniMaxH3Configuration.modelID,
            parameters: parameters,
            preset: MiniMaxH3Preset.quick.rawValue,
            targetDurationSeconds: 3.0,
            generationSource: "autoMovie")
        let autoMovieResolved = try MiniMaxH3DurationPolicy.applying(to: autoMovieReq)
        t.checkEqual(autoMovieResolved.parameters.numFrames, 73, "Auto movie Quick resolves to 73 frames")
        t.checkEqual(autoMovieResolved.parameters.numInferenceSteps, 8, "Auto movie Quick resolves to 8 steps")
        t.checkEqual(autoMovieResolved.minimaxH3ChainWindows, 1, "Auto movie Quick uses 1 window")

        // 22. Storyboard with H3 Preset High resolves to 90f, 20 steps, Tier 2 dimensions
        let storyboardReq = GenerationRequest(
            prompt: "Storyboard shot.",
            modelId: MiniMaxH3Configuration.modelID,
            parameters: parameters,
            preset: MiniMaxH3Preset.high.rawValue,
            targetDurationSeconds: 4.0,
            generationSource: "storyboard")
        let storyboardResolved = try MiniMaxH3DurationPolicy.applying(to: storyboardReq)
        t.checkEqual(storyboardResolved.parameters.numFrames, 90, "Storyboard High resolves to 90 frames")
        t.checkEqual(storyboardResolved.parameters.numInferenceSteps, 20, "Storyboard High resolves to 20 steps")
        t.checkEqual(storyboardResolved.parameters.width, 640, "Storyboard High width is 640")
        t.checkEqual(storyboardResolved.parameters.height, 384, "Storyboard High height is 384")
        t.checkEqual(storyboardResolved.parameters.fps, 24, "Storyboard FPS preserved")
    }

    t.suite("MiniMax H3 Truthful Progress Presentation") {
        var parameters = GenerationParameters.default
        parameters.width = 512
        parameters.height = 288
        parameters.fps = 24
        parameters.numFrames = 39
        parameters.numInferenceSteps = 8
        var request = GenerationRequest(
            prompt: "A subject turns toward camera.",
            modelId: MiniMaxH3Configuration.modelID,
            parameters: parameters)
        request.minimaxH3ChainWindows = 6
        request.minimaxH3ExpectedFrames = 229

        t.check(MiniMaxH3ProgressPresentation.isIndeterminate(
            modelID: request.modelId, isCurrent: true, progress: 0),
                "H3 is visibly active before the single-response HTTP request advances")
        t.check(MiniMaxH3ProgressPresentation.isIndeterminate(
            modelID: request.modelId, isCurrent: true, progress: 0.03),
                "H3 sampling does not show a frozen fake 3 percent")
        t.check(!MiniMaxH3ProgressPresentation.isIndeterminate(
            modelID: request.modelId, isCurrent: true, progress: 0.94),
                "H3 returns to determinate progress for the proven mux phase")
        t.check(!MiniMaxH3ProgressPresentation.isIndeterminate(
            modelID: LTXModelCatalog.defaultModelID, isCurrent: true, progress: 0.03),
                "LTX progress presentation remains unchanged")
        t.check(!MiniMaxH3ProgressPresentation.isIndeterminate(
            modelID: request.modelId, isCurrent: false, progress: 0),
                "waiting H3 requests are not presented as actively rendering")

        let message = MiniMaxH3ProgressPresentation.generatingMessage(for: request)
        t.check(message.contains("512×288"), "active status exposes the effective H3 canvas")
        t.check(message.contains("chain 6"), "active status exposes the effective chain count")
        t.check(message.contains("9.5 s output"), "active status distinguishes output duration from wall time")
        t.check(message.contains("8 steps"), "active status exposes the effective H3 sampler steps")
        t.check(message.contains("long local generation"), "active status sets truthful duration expectations")
        let start = Date(timeIntervalSinceReferenceDate: 100)
        t.checkEqual(
            MiniMaxH3ProgressPresentation.elapsedText(
                since: start,
                now: Date(timeIntervalSinceReferenceDate: 225)),
            "Elapsed 02:05",
            "elapsed H3 time is stable and human readable")
        t.checkEqual(
            MiniMaxH3ProgressPresentation.elapsedText(
                since: start,
                now: Date(timeIntervalSinceReferenceDate: 90)),
            "Elapsed 00:00",
            "clock skew never displays negative elapsed time")
        t.check(MiniMaxH3ProgressPresentation.requestTimeoutSeconds >= 24 * 60,
                "H3 timeout remains longer than the proven 24-minute chain 6 run")
    }

    t.suite("MiniMax H3 Prompt Contract") {
        let plan = OneShotPlan(
            camera: "static medium close-up",
            action: "A woman in a white sweater slowly turns toward the camera",
            acting: "She maintains a relaxed posture",
            motion: "natural and continuous",
            lighting: "soft and warm",
            dialogue: [],
            audioCues: ["quiet room tone"],
            durationIntentSeconds: 6,
            endState: "she is facing the camera and has come to a natural stop")
        let prompt = MiniMaxH3PromptCompiler.compile(
            plan: plan,
            isImageToVideo: true,
            perShotAudioPolicy: .naturalProductionSoundNoMusic)
        t.check(prompt.contains("woman in a white sweater"), "subject/environment context is retained")
        t.check(prompt.contains("slowly turns"), "one coherent action is retained")
        t.check(prompt.lowercased().contains("camera"), "camera behavior is explicit")
        t.check(prompt.contains("By the end of the shot"), "end state is explicit")
        t.check(prompt.contains("face, clothing, hairstyle"), "I2V appearance preservation is concise and explicit")
        t.check(prompt.contains("quiet room tone"), "native audio cues are retained")
        t.check(prompt.contains("No background music"), "shared no-generated-BGM policy remains intact")

        let short = MiniMaxH3PromptCompiler.compile(
            rendererNeutralPrompt: "He smiles.",
            isImageToVideo: true)
        t.check(short.contains("He smiles."), "short user action is retained")
        t.check(short.lowercased().contains("camera"), "short prompt receives structural camera context")
        t.check(short.contains("remain consistent"), "short I2V prompt receives appearance stability")
        t.check(short.count > "He smiles.".count, "short prompt is not sent as a tiny bare command")
    }

    t.suite("MiniMax H3 HTTP / Media Contract") {
        var parameters = GenerationParameters.default
        parameters.width = 512
        parameters.height = 288
        parameters.numFrames = 39
        parameters.numInferenceSteps = 8
        parameters.seed = 42
        var t2v = GenerationRequest(
            prompt: "A subject turns while the camera remains still.",
            modelId: MiniMaxH3Configuration.modelID,
            parameters: parameters)
        t2v.minimaxH3ChainWindows = 4
        let t2vPayload = MiniMaxH3Backend.makePayload(
            request: t2v, sourceImageData: nil, seed: 42)
        t.check(t2vPayload.firstFrameImage == nil, "T2V omits first_frame_image")
        t.checkEqual(t2vPayload.chainWindows, 4, "chain_windows reaches HTTP payload")
        t.checkEqual(t2vPayload.numFrames, 39, "window frames reach HTTP payload")

        let imageBytes = Data([0x89, 0x50, 0x4e, 0x47])
        let i2vPayload = MiniMaxH3Backend.makePayload(
            request: t2v, sourceImageData: imageBytes, seed: 42)
        t.checkEqual(i2vPayload.firstFrameImage, imageBytes, "I2V maps exactly one source to first_frame_image")
        let encodedPayload = try JSONEncoder().encode(i2vPayload)
        let payloadJSON = String(data: encodedPayload, encoding: .utf8) ?? ""
        t.check(payloadJSON.contains("\"first_frame_image\""), "wire key is first_frame_image")
        t.check(!payloadJSON.contains("ref_videos"), "unsupported ref_videos is never sent")
        t.check(!payloadJSON.contains("motion_context"), "unsupported Motion Context is never sent")

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MiniMaxH3Tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let rgbURL = root.appendingPathComponent("frames.rgb")
        let pcmURL = root.appendingPathComponent("audio.pcm")
        let response = MiniMaxH3GenerationResponse(
            frames: 1,
            height: 1,
            width: 2,
            fps: 24,
            format: "rgb8",
            data: Data([1, 2, 3, 4, 5, 6]),
            audioSampleRate: 32_000,
            audioChannels: 2,
            audioFormat: "pcm_s16le",
            audioData: Data([1, 0, 2, 0]))
        let responseData = try JSONEncoder().encode(response)
        let metadata = try MiniMaxH3Backend.decodeAndWrite(
            responseData: responseData,
            rgbURL: rgbURL,
            pcmURL: pcmURL,
            includeAudio: true)
        t.checkEqual(metadata.frames, 1, "response frame count is authoritative")
        t.checkEqual(metadata.width, 2, "response width is authoritative")
        t.checkEqual(metadata.audioSampleRate, 32_000, "response audio sample rate is authoritative")
        t.checkEqual(try Data(contentsOf: rgbURL), response.data, "raw RGB bytes are written exactly")
        t.checkEqual(try Data(contentsOf: pcmURL), response.audioData!, "PCM s16le bytes are written exactly")
        let mux = MiniMaxH3Backend.muxArguments(
            rgbPath: rgbURL.path,
            pcmPath: pcmURL.path,
            outputPath: root.appendingPathComponent("out.mp4").path,
            metadata: metadata)
        t.check(mux.contains("libx264") && mux.contains("yuv420p"), "mux contract produces compatible H.264")
        t.check(mux.contains("aac") && mux.contains("-shortest"), "native PCM is muxed to AAC")
        t.check(mux.contains("apad"), "short native audio is padded to preserve every returned frame")
        let silentMux = MiniMaxH3Backend.muxArguments(
            rgbPath: rgbURL.path,
            pcmPath: nil,
            outputPath: root.appendingPathComponent("silent.mp4").path,
            metadata: MiniMaxH3DecodedMetadata(
                frames: 1, width: 2, height: 1, fps: 24,
                audioSampleRate: nil, audioChannels: nil, hasAudio: false))
        t.check(silentMux.contains("-an"), "Audio Off discards runtime audio at mux without inventing HTTP controls")

        let bad = MiniMaxH3GenerationResponse(
            frames: 2, height: 1, width: 2, fps: 24, format: "rgb8",
            data: Data([1, 2, 3]), audioSampleRate: nil, audioChannels: nil,
            audioFormat: nil, audioData: nil)
        t.checkThrows(
            MiniMaxH3Error.invalidFramePayload(expected: 12, actual: 3),
            "invalid RGB size fails closed") {
                _ = try MiniMaxH3Backend.decodeAndWrite(
                    responseData: try JSONEncoder().encode(bad),
                    rgbURL: rgbURL,
                    pcmURL: pcmURL,
                    includeAudio: false)
            }

        let invalidBase64 = Data("{\"frames\":1,\"height\":1,\"width\":1,\"fps\":24,\"format\":\"rgb8\",\"data\":\"%%%\"}".utf8)
        t.checkThrows(
            MiniMaxH3Error.invalidBase64("data"),
            "invalid frame base64 is classified explicitly") {
                _ = try MiniMaxH3Backend.decodeAndWrite(
                    responseData: invalidBase64,
                    rgbURL: rgbURL,
                    pcmURL: pcmURL,
                    includeAudio: false)
            }

        let h3SourceError = MiniMaxH3Error.invalidSourceImage("Unsupported image data.")
        t.checkEqual(
            GenerationRuntimeFailureClassifier.stage(for: h3SourceError),
            .sourcePreparation,
            "H3 source preparation errors use the shared failure category")
    }

    t.suite("MiniMax H3 Requested / Effective / Actual Persistence") {
        var parameters = GenerationParameters.default
        parameters.width = 512
        parameters.height = 288
        parameters.numFrames = 39
        let request = GenerationRequest(
            prompt: "A stable subject.",
            modelId: MiniMaxH3Configuration.modelID,
            parameters: parameters,
            targetDurationSeconds: 6.0,
            minimaxH3ModelDirectory: "/frozen/model",
            minimaxH3RuntimeExecutablePath: "/frozen/runtime",
            minimaxH3Endpoint: "http://127.0.0.1:11235",
            minimaxH3ChainWindows: 4,
            minimaxH3ExpectedFrames: 153,
            minimaxH3RequestedDurationSeconds: 6.0)
        let requestRoundTrip = try JSONDecoder().decode(
            GenerationRequest.self,
            from: JSONEncoder().encode(request))
        t.checkEqual(requestRoundTrip.modelId, MiniMaxH3Configuration.modelID, "request persists stable H3 ID")
        t.checkEqual(requestRoundTrip.minimaxH3ChainWindows, 4, "request persists effective chain")
        t.checkEqual(requestRoundTrip.minimaxH3ExpectedFrames, 153, "request persists effective frames")
        t.checkEqual(requestRoundTrip.minimaxH3RequestedDurationSeconds, 6.0, "request persists requested duration")

        let result = GenerationResult(
            id: UUID(),
            requestId: request.id,
            prompt: request.prompt,
            enhancedPrompt: nil,
            negativePrompt: "",
            voiceoverText: "",
            voiceoverSource: "mlx-audio",
            voiceoverVoice: "af_heart",
            modelId: MiniMaxH3Configuration.modelID,
            parameters: parameters,
            videoPath: "/archive/h3.mp4",
            thumbnailPath: nil,
            audioPath: nil,
            musicPath: nil,
            musicGenre: nil,
            createdAt: Date(timeIntervalSinceReferenceDate: 100),
            completedAt: Date(timeIntervalSinceReferenceDate: 200),
            duration: 100,
            seed: 42,
            requestedWidth: 768,
            requestedHeight: 512,
            requestedDurationSeconds: 6.0,
            audioEnabled: true,
            effectiveWidth: 512,
            effectiveHeight: 288,
            actualWidth: 512,
            actualHeight: 288,
            actualFPS: 24,
            actualDuration: 6.375,
            actualFrameCount: 153,
            backendKind: GenerationBackendKind.minimaxH3.rawValue,
            effectiveFrameCount: 153,
            effectiveChainWindows: 4)
        let resultRoundTrip = try JSONDecoder().decode(
            GenerationResult.self,
            from: JSONEncoder().encode(result))
        t.checkEqual(resultRoundTrip.modelId, MiniMaxH3Configuration.modelID, "Archive persists stable renderer identity")
        t.checkEqual(resultRoundTrip.backendKind, GenerationBackendKind.minimaxH3.rawValue, "Archive persists backend")
        t.checkEqual(resultRoundTrip.requestedDurationSeconds, 6.0, "Archive preserves requested duration")
        t.checkEqual(resultRoundTrip.effectiveFrameCount, 153, "Archive preserves effective frame plan")
        t.checkEqual(resultRoundTrip.effectiveChainWindows, 4, "Archive preserves chain_windows")
        t.checkEqual(resultRoundTrip.actualFrameCount, 153, "Archive preserves actual probed frame count")
        t.checkEqual(resultRoundTrip.actualDuration, 6.375, "Archive preserves actual duration")
        t.checkEqual(resultRoundTrip.videoPath, "/archive/h3.mp4", "Archive preserves output without runtime paths")
    }

    t.suite("MiniMax H3 Project Take Requested Duration") {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MiniMaxH3TakeTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FilmProjectStore(projectsDirectory: root)
        var project = FilmProject(title: "H3 duration snapshot")
        project.settings = ProjectSettings(
            modelID: MiniMaxH3Configuration.modelID,
            qualityMode: GenerationPreset.standard.qualityMode.rawValue,
            preset: GenerationPreset.standard.rawValue,
            width: 768, height: 512, fps: 24)
        var shot = Shot(index: 0, title: "Shot", summary: "A person turns.")
        shot.compiledPrompt = "A person turns toward the camera."
        shot.durationSeconds = 2.3
        shot.continuityMode = .cut
        project.shots = [shot]
        store.save(project)

        let requests = try TakeGenerationCoordinator(store: store).planTakes(
            projectID: project.id, shotID: shot.id, count: 1, baseSeed: 42)
        let saved = store.project(id: project.id)!
        t.checkEqual(saved.shots[0].takes[0].requestedDuration, 2.3,
                     "Take preserves semantic H3 requested duration")
        t.checkEqual(requests[0].targetDurationSeconds, 2.3,
                     "queued H3 request preserves semantic duration target")
        t.checkEqual(requests[0].parameters.width, 768,
                     "queued H3 request preserves requested width before execution resolution")
        t.checkEqual(requests[0].parameters.height, 512,
                     "queued H3 request preserves requested height before execution resolution")
    }

    t.suite("MiniMax H3 All Generation Modes Unified Preset System") {
        var parameters = GenerationParameters.default

        // 1. Authoritative Preset Constants
        t.checkEqual(MiniMaxH3ResolutionTier.tier1.dimensions(for: .landscape).width, 512, "Tier 1 landscape width: 512")
        t.checkEqual(MiniMaxH3ResolutionTier.tier1.dimensions(for: .landscape).height, 288, "Tier 1 landscape height: 288")
        t.checkEqual(MiniMaxH3ResolutionTier.tier1.dimensions(for: .portrait).width, 288, "Tier 1 portrait width: 288")
        t.checkEqual(MiniMaxH3ResolutionTier.tier1.dimensions(for: .portrait).height, 512, "Tier 1 portrait height: 512")

        t.checkEqual(MiniMaxH3ResolutionTier.tier2.dimensions(for: .landscape).width, 640, "Tier 2 landscape width: 640")
        t.checkEqual(MiniMaxH3ResolutionTier.tier2.dimensions(for: .landscape).height, 384, "Tier 2 landscape height: 384")
        t.checkEqual(MiniMaxH3ResolutionTier.tier2.dimensions(for: .portrait).width, 384, "Tier 2 portrait width: 384")
        t.checkEqual(MiniMaxH3ResolutionTier.tier2.dimensions(for: .portrait).height, 640, "Tier 2 portrait height: 640")

        t.checkEqual(MiniMaxH3Preset.quick.perShotSafeMaxDurationSeconds, 3.0, "Quick per-shot safe max: 3.0s")
        t.checkEqual(MiniMaxH3Preset.standard.perShotSafeMaxDurationSeconds, 3.75, "Standard per-shot safe max: 3.75s")
        t.checkEqual(MiniMaxH3Preset.high.perShotSafeMaxDurationSeconds, 3.75, "High per-shot safe max: 3.75s")

        // 2. Summary Formatting (Standard / Auto Movie / Landscape / Portrait)
        let quickSummaryLandscape = MiniMaxH3Preset.quick.effectiveSummary(orientation: .landscape, isAutoMovie: false)
        t.check(quickSummaryLandscape.contains("512×288"), "Quick summary contains 512x288")
        t.check(quickSummaryLandscape.contains("3 sec") || quickSummaryLandscape.contains("3.0"), "Quick summary contains 3 sec")
        t.check(quickSummaryLandscape.contains("8 steps"), "Quick summary contains 8 steps")

        let quickSummaryPortrait = MiniMaxH3Preset.quick.effectiveSummary(orientation: .portrait, isAutoMovie: false)
        t.check(quickSummaryPortrait.contains("288×512"), "Quick portrait summary contains 288x512")

        let standardAutoMovieSummary = MiniMaxH3Preset.standard.effectiveSummary(orientation: .landscape, isAutoMovie: true)
        t.check(standardAutoMovieSummary.contains("up to") && standardAutoMovieSummary.contains("/shot"), "Auto Movie Standard summary contains up to X/shot")

        let customSummary = MiniMaxH3Preset.custom.effectiveSummary(
            orientation: .landscape, isAutoMovie: true, customTier: .tier2, customDurationSeconds: 5.5, customSteps: 14)
        t.check(customSummary.contains("640×384"), "Custom Tier 2 summary contains 640x384")
        t.check(customSummary.contains("14 steps"), "Custom summary contains 14 steps")
        t.check(customSummary.contains("up to") && customSummary.contains("/shot"), "Custom Auto Movie summary contains up to X/shot")

        // 3. Auto Movie Duration Planner (normalizeForH3)
        var mockShots = [
            Shot(index: 0, title: "Shot 1", summary: "Opening scene."),
            Shot(index: 1, title: "Shot 2", summary: "Action unfolds."),
            Shot(index: 2, title: "Shot 3", summary: "Climax and finish.")
        ]
        let normalizedH3Standard = AutoMovieDurationPlanner.normalizeForH3(
            shots: mockShots, targetDurationSeconds: 12.0, preset: .standard)
        t.checkEqual(normalizedH3Standard.count, 4, "12s Standard Auto Movie optimizes to 4 shots for minimal error")
        let totalNormalized12 = normalizedH3Standard.reduce(0) { $0 + ($1.effectiveFrames ?? 0) }
        t.checkEqual(totalNormalized12, 292, "12s Standard produces 292 frames (12.17s, error +4f)")
        for shot in normalizedH3Standard {
            t.check((shot.effectiveFrames ?? 0) <= 90, "Each shot is <= 90 frames for Standard")
        }

        // 4. Auto Movie with 20s target and Standard preset (3.75s safe max -> expands to >= 5 shots)
        let normalized20s = AutoMovieDurationPlanner.normalizeForH3(
            shots: mockShots, targetDurationSeconds: 20.0, preset: .standard)
        t.check(normalized20s.count >= 5, "20s Standard Auto Movie expands to at least 5 shots to respect safe max")
        for shot in normalized20s {
            t.check(shot.durationSeconds <= 4.0, "No shot exceeds 4s in Standard Auto Movie")
            let frames = Int((shot.durationSeconds * 24.0).rounded())
            t.check(MiniMaxH3FrameGrid.isLegalFrameCount(frames), "Shot frame count \(frames) is on 17k+5 grid")
        }

        // 5. Auto Movie Structural Movie Planner for H3
        let brief = "A samurai walks in the forest.\n\nHe spots an enemy in the trees.\n\nHe draws his blade for battle."
        let plan = try! StructuralMoviePlanner.plan(prompt: brief)
        t.checkEqual(plan.segments.count, 3, "Structural planner parsed 3 segments")

        // 6. Storyboard and Take Generation Coordinator H3 Propagation
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MiniMaxH3AutoMovieTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var settings = ProjectSettings()
        settings.modelID = MiniMaxH3Configuration.modelID
        settings.minimaxH3Preset = MiniMaxH3Preset.standard.rawValue
        settings.targetDurationSeconds = 12.0

        var project = FilmProject(title: "H3 Project")
        project.settings = settings
        var shot0 = Shot(index: 0, title: "Shot 1", summary: "Opening")
        shot0.compiledPrompt = "Samurai walks in forest"
        shot0.durationSeconds = 3.75
        project.shots = [shot0]

        let store = FilmProjectStore(projectsDirectory: root)
        store.save(project)

        let coordinator = TakeGenerationCoordinator(store: store)
        let requests = try coordinator.planTakes(projectID: project.id, shotID: shot0.id, count: 1, baseSeed: 100)
        t.checkEqual(requests.count, 1, "Generated 1 take request")
        let req = requests[0]
        t.checkEqual(req.modelId, MiniMaxH3Configuration.modelID, "Request carries H3 model ID")
        t.checkEqual(req.preset, MiniMaxH3Preset.standard.rawValue, "Request carries Standard H3 preset")
        t.checkEqual(req.parameters.numInferenceSteps, 16, "Request carries 16 inference steps for Standard")

        let resolvedReq = try MiniMaxH3DurationPolicy.applying(to: req)
        t.checkEqual(resolvedReq.parameters.numFrames, 90, "Resolved request has 90 frames")
        t.checkEqual(resolvedReq.parameters.numInferenceSteps, 16, "Resolved request has 16 steps")
        t.checkEqual(resolvedReq.parameters.width, 640, "Resolved request has 640 width")
        t.checkEqual(resolvedReq.parameters.height, 384, "Resolved request has 384 height")
        t.checkEqual(resolvedReq.parameters.fps, 24, "Resolved request has 24 fps")

        // 7. Portrait Source Image Orientation Propagation
        let portraitReq = GenerationRequest(
            prompt: req.prompt,
            presetResolutionOrientation: .portrait,
            modelId: req.modelId,
            parameters: req.parameters,
            preset: req.preset,
            targetDurationSeconds: req.targetDurationSeconds,
            generationSource: req.generationSource,
            minimaxH3RequestedDurationSeconds: req.minimaxH3RequestedDurationSeconds
        )
        let resolvedPortrait = try MiniMaxH3DurationPolicy.applying(to: portraitReq)
        t.checkEqual(resolvedPortrait.parameters.width, 384, "Portrait resolved width is 384")
        t.checkEqual(resolvedPortrait.parameters.height, 640, "Portrait resolved height is 640")

        // 8. Custom Preset Validation
        var customReq = GenerationRequest(
            prompt: "Custom shot",
            modelId: MiniMaxH3Configuration.modelID,
            parameters: parameters,
            preset: MiniMaxH3Preset.custom.rawValue,
            targetDurationSeconds: 5.0,
            generationSource: "generate",
            minimaxH3RequestedDurationSeconds: 5.0
        )
        customReq.parameters.numInferenceSteps = 16
        customReq.parameters.width = 640
        customReq.parameters.height = 384
        let resolvedCustom = try MiniMaxH3DurationPolicy.applying(to: customReq)
        t.checkEqual(resolvedCustom.parameters.width, 640, "Custom Tier 2 width is 640")
        t.checkEqual(resolvedCustom.parameters.height, 384, "Custom Tier 2 height is 384")
        t.checkEqual(resolvedCustom.parameters.numInferenceSteps, 16, "Custom steps is 16")
        t.checkEqual(resolvedCustom.parameters.numFrames, 124, "5.0s snaps to 124 frames (17*7+5)")

        // 9. Frame Ladder Legal Checks
        t.check(MiniMaxH3FrameGrid.isLegalFrameCount(22), "22 is legal (17*1+5)")
        t.check(MiniMaxH3FrameGrid.isLegalFrameCount(39), "39 is legal (17*2+5)")
        t.check(MiniMaxH3FrameGrid.isLegalFrameCount(56), "56 is legal (17*3+5)")
        t.check(MiniMaxH3FrameGrid.isLegalFrameCount(73), "73 is legal (17*4+5)")
        t.check(MiniMaxH3FrameGrid.isLegalFrameCount(90), "90 is legal (17*5+5)")
        t.check(MiniMaxH3FrameGrid.isLegalFrameCount(107), "107 is legal (17*6+5)")
        t.check(MiniMaxH3FrameGrid.isLegalFrameCount(124), "124 is legal (17*7+5)")
        t.check(MiniMaxH3FrameGrid.isLegalFrameCount(141), "141 is legal (17*8+5)")
        t.check(!MiniMaxH3FrameGrid.isLegalFrameCount(80), "80 is not legal")
        t.check(!MiniMaxH3FrameGrid.isLegalFrameCount(100), "100 is not legal")
    }

    t.suite("MiniMax H3 Auto Movie Duration Solver & Continuity Guidance") {
        // 1. 12 sec Standard Duration Solver Optimization
        guard let optimal12 = MiniMaxH3DurationSolver.solve(targetDurationSeconds: 12.0, preset: .standard) else {
            t.check(false, "MiniMaxH3DurationSolver failed to solve 12.0s Standard")
            return
        }
        let totalFrames12 = optimal12.reduce(0, +)
        let errorFrames12 = abs(totalFrames12 - 288) // 12s * 24fps = 288 frames
        t.check(errorFrames12 <= 4, "12s Standard total frames \(totalFrames12) has error <= 4 frames (actual: \(errorFrames12))")
        t.check(errorFrames12 < 18, "New error (\(errorFrames12)f) is substantially better than old 270f error (18f)")
        t.check(optimal12.count <= 12, "Shot count is <= 12 (actual: \(optimal12.count))")
        for f in optimal12 {
            t.check(f <= 90, "Shot frame \(f) <= 90 (Standard safe max)")
            t.check(MiniMaxH3FrameGrid.isLegalFrameCount(f), "Shot frame \(f) is legal on 17k+5 grid")
        }

        // 2. 20 sec Standard Duration Solver Optimization
        guard let optimal20 = MiniMaxH3DurationSolver.solve(targetDurationSeconds: 20.0, preset: .standard) else {
            t.check(false, "MiniMaxH3DurationSolver failed to solve 20.0s Standard")
            return
        }
        let totalFrames20 = optimal20.reduce(0, +)
        let errorFrames20 = abs(totalFrames20 - 480) // 20s * 24fps = 480 frames
        t.check(errorFrames20 <= 9, "20s Standard total frames \(totalFrames20) has error <= 9 frames (actual: \(errorFrames20))")
        t.check(optimal20.count <= 12, "20s shot count is <= 12 (actual: \(optimal20.count))")
        for f in optimal20 {
            t.check(f <= 90, "Shot frame \(f) <= 90 (Standard safe max)")
            t.check(MiniMaxH3FrameGrid.isLegalFrameCount(f), "Shot frame \(f) is legal on 17k+5 grid")
        }

        // 3. Quick Preset (safe max 73)
        guard let optimalQuick = MiniMaxH3DurationSolver.solve(targetDurationSeconds: 6.0, preset: .quick) else {
            t.check(false, "MiniMaxH3DurationSolver failed to solve 6.0s Quick")
            return
        }
        let totalFramesQuick = optimalQuick.reduce(0, +)
        t.check(abs(totalFramesQuick - 144) <= 2, "6s Quick total frames \(totalFramesQuick) close to 144")
        for f in optimalQuick {
            t.check(f <= 73, "Quick shot frame \(f) <= 73")
            t.check(MiniMaxH3FrameGrid.isLegalFrameCount(f), "Quick shot frame \(f) is legal")
        }

        // 4. High Preset (safe max 90)
        guard let optimalHigh = MiniMaxH3DurationSolver.solve(targetDurationSeconds: 12.0, preset: .high) else {
            t.check(false, "MiniMaxH3DurationSolver failed to solve 12.0s High")
            return
        }
        for f in optimalHigh {
            t.check(f <= 90, "High shot frame \(f) <= 90")
            t.check(MiniMaxH3FrameGrid.isLegalFrameCount(f), "High shot frame \(f) is legal")
        }

        // 5. Custom Preset (e.g. 5.0s -> 124f safe max)
        guard let optimalCustom = MiniMaxH3DurationSolver.solve(
            targetDurationSeconds: 15.0, preset: .custom, customDurationSeconds: 5.0) else {
            t.check(false, "MiniMaxH3DurationSolver failed to solve 15.0s Custom")
            return
        }
        for f in optimalCustom {
            t.check(f <= 124, "Custom shot frame \(f) <= 124")
            t.check(MiniMaxH3FrameGrid.isLegalFrameCount(f), "Custom shot frame \(f) is legal")
        }

        // 6. Capacity Limit & Fail Closed (e.g. 60s Standard: 12*90=1080 < 1440)
        let overcapacity = MiniMaxH3DurationSolver.solve(targetDurationSeconds: 60.0, preset: .standard)
        t.check(overcapacity == nil, "Overcapacity target returns nil (fail closed)")

        // 7. Determinism (100 runs return identical allocations)
        let runA = MiniMaxH3DurationSolver.solve(targetDurationSeconds: 12.0, preset: .standard)
        for _ in 0..<100 {
            let runB = MiniMaxH3DurationSolver.solve(targetDurationSeconds: 12.0, preset: .standard)
            t.checkEqual(runA, runB, "Solver output is deterministic")
        }

        // 8. normalizeForH3 integration with Shot fields
        var mockShots = [
            Shot(index: 0, title: "Shot 1", summary: "Opening shot of traveler."),
            Shot(index: 1, title: "Shot 2", summary: "Traveler walks through ancient forest.")
        ]
        let normalized = AutoMovieDurationPlanner.normalizeForH3(
            shots: mockShots, targetDurationSeconds: 12.0, preset: .standard)
        t.checkEqual(normalized.count, 4, "12s Standard normalizes to 4 shots")
        for shot in normalized {
            t.check(shot.effectiveFrames != nil, "effectiveFrames is populated")
            t.check(shot.actualDurationSeconds != nil, "actualDurationSeconds is populated")
            t.checkEqual(shot.durationSeconds, shot.actualDurationSeconds!, "durationSeconds equals actualDurationSeconds")
            t.check(shot.continueChainIndex != nil, "continueChainIndex is populated")
        }

        // 9. Continuity Chain Policy & Warning Thresholds
        var chain3Shots = [
            Shot(index: 0, title: "Shot 1"),
            Shot(index: 1, title: "Shot 2"),
            Shot(index: 2, title: "Shot 3")
        ]
        chain3Shots[0].continuityMode = .cut
        chain3Shots[1].continuityMode = .continueFromPrevious
        chain3Shots[2].continuityMode = .continueFromPrevious
        ContinuityChainPolicy.updateContinueChainIndices(shots: &chain3Shots)
        t.checkEqual(chain3Shots[0].continueChainIndex, 0, "Shot 1 chain index is 0")
        t.checkEqual(chain3Shots[1].continueChainIndex, 1, "Shot 2 chain index is 1")
        t.checkEqual(chain3Shots[2].continueChainIndex, 2, "Shot 3 chain index is 2")
        t.check(!ContinuityChainPolicy.hasLongContinueChainWarning(shots: chain3Shots, modelID: MiniMaxH3Configuration.modelID),
                "3 shots CONTINUE chain has NO warning")

        var chain4Shots = chain3Shots
        var shot4 = Shot(index: 3, title: "Shot 4")
        shot4.continuityMode = .continueFromPrevious
        chain4Shots.append(shot4)
        ContinuityChainPolicy.updateContinueChainIndices(shots: &chain4Shots)
        t.checkEqual(chain4Shots[3].continueChainIndex, 3, "Shot 4 chain index is 3")
        t.check(ContinuityChainPolicy.hasLongContinueChainWarning(shots: chain4Shots, modelID: MiniMaxH3Configuration.modelID),
                "4 shots CONTINUE chain triggers warning")

        // LTX model ID check: no warning
        t.check(!ContinuityChainPolicy.hasLongContinueChainWarning(shots: chain4Shots, modelID: "ltx-video-0.9.1"),
                "LTX model does NOT trigger H3 continue warning")

        // 10. Cut resets chain index
        var resetChainShots = chain4Shots
        var shot5Cut = Shot(index: 4, title: "Shot 5")
        shot5Cut.continuityMode = .cut
        resetChainShots.append(shot5Cut)
        var shot6Continue = Shot(index: 5, title: "Shot 6")
        shot6Continue.continuityMode = .continueFromPrevious
        resetChainShots.append(shot6Continue)
        ContinuityChainPolicy.updateContinueChainIndices(shots: &resetChainShots)
        t.checkEqual(resetChainShots[4].continueChainIndex, 0, "Shot 5 Cut resets chain index to 0")
        t.checkEqual(resetChainShots[5].continueChainIndex, 1, "Shot 6 Continue has chain index 1")

        // 11. Director OFF Structural Capacity Validation
        let coordinator = HybridProjectCoordinator()
        var h3Settings = ProjectSettings()
        h3Settings.modelID = MiniMaxH3Configuration.modelID
        h3Settings.minimaxH3Preset = MiniMaxH3Preset.standard.rawValue
        h3Settings.targetDurationSeconds = 12.0

        h3Await {
            do {
                let result12 = try await coordinator.makeProject(
                    title: "Test Movie",
                    brief: "1. The hero wakes up in the cave.\n2. Light filters through the ceiling.\n3. He heads toward the exit.",
                    settings: h3Settings,
                    characterBible: CharacterBible(),
                    directorEnabled: false
                )
                t.checkEqual(result12.project.shots.count, 4, "Director OFF creates 4 optimized shots for 12s Standard")
                t.checkEqual(result12.project.shots[0].summary, "The hero wakes up in the cave.", "Segment 1 content preserved")
                t.check(result12.project.shots[0].effectiveFrames! <= 90, "Shot 1 frame <= 90")
            } catch {
                t.check(false, "Director OFF makeProject failed: \(error)")
            }
        }
    }

    t.suite("MiniMax H3 Preset V2 Canonical Tests") {
        var baseParams = GenerationParameters.default

        // H3_QUICK_LANDSCAPE_V2: 512x288 / 73f / 8st / Fast ON
        let quickLandReq = GenerationRequest(
            prompt: "Quick Landscape",
            modelId: MiniMaxH3Configuration.modelID,
            parameters: baseParams,
            preset: MiniMaxH3Preset.quick.rawValue)
        let resolvedQuickLand = try! MiniMaxH3DurationPolicy.applying(to: quickLandReq)
        t.checkEqual(resolvedQuickLand.parameters.width, 512, "H3_QUICK_LANDSCAPE_V2 width 512")
        t.checkEqual(resolvedQuickLand.parameters.height, 288, "H3_QUICK_LANDSCAPE_V2 height 288")
        t.checkEqual(resolvedQuickLand.parameters.numFrames, 73, "H3_QUICK_LANDSCAPE_V2 frames 73")
        t.checkEqual(resolvedQuickLand.parameters.numInferenceSteps, 8, "H3_QUICK_LANDSCAPE_V2 steps 8")
        t.checkEqual(resolvedQuickLand.minimaxH3Fast, true, "H3_FAST_QUICK_ON")

        // H3_QUICK_PORTRAIT_V2: 288x512 / 73f / 8st / Fast ON
        let quickPortReq = GenerationRequest(
            prompt: "Quick Portrait",
            presetResolutionOrientation: .portrait,
            modelId: MiniMaxH3Configuration.modelID,
            parameters: baseParams,
            preset: MiniMaxH3Preset.quick.rawValue)
        let resolvedQuickPort = try! MiniMaxH3DurationPolicy.applying(to: quickPortReq)
        t.checkEqual(resolvedQuickPort.parameters.width, 288, "H3_QUICK_PORTRAIT_V2 width 288")
        t.checkEqual(resolvedQuickPort.parameters.height, 512, "H3_QUICK_PORTRAIT_V2 height 512")
        t.checkEqual(resolvedQuickPort.parameters.numFrames, 73, "H3_QUICK_PORTRAIT_V2 frames 73")
        t.checkEqual(resolvedQuickPort.parameters.numInferenceSteps, 8, "H3_QUICK_PORTRAIT_V2 steps 8")
        t.checkEqual(resolvedQuickPort.minimaxH3Fast, true, "H3_FAST_QUICK_ON portrait")

        // H3_STANDARD_LANDSCAPE_V2: 640x384 / 90f / 16st / Fast ON
        let stdLandReq = GenerationRequest(
            prompt: "Standard Landscape",
            modelId: MiniMaxH3Configuration.modelID,
            parameters: baseParams,
            preset: MiniMaxH3Preset.standard.rawValue)
        let resolvedStdLand = try! MiniMaxH3DurationPolicy.applying(to: stdLandReq)
        t.checkEqual(resolvedStdLand.parameters.width, 640, "H3_STANDARD_LANDSCAPE_V2 width 640")
        t.checkEqual(resolvedStdLand.parameters.height, 384, "H3_STANDARD_LANDSCAPE_V2 height 384")
        t.checkEqual(resolvedStdLand.parameters.numFrames, 90, "H3_STANDARD_LANDSCAPE_V2 frames 90")
        t.checkEqual(resolvedStdLand.parameters.numInferenceSteps, 16, "H3_STANDARD_LANDSCAPE_V2 steps 16")
        t.checkEqual(resolvedStdLand.minimaxH3Fast, true, "H3_FAST_STANDARD_ON")

        // H3_STANDARD_PORTRAIT_V2: 384x640 / 90f / 16st / Fast ON
        let stdPortReq = GenerationRequest(
            prompt: "Standard Portrait",
            presetResolutionOrientation: .portrait,
            modelId: MiniMaxH3Configuration.modelID,
            parameters: baseParams,
            preset: MiniMaxH3Preset.standard.rawValue)
        let resolvedStdPort = try! MiniMaxH3DurationPolicy.applying(to: stdPortReq)
        t.checkEqual(resolvedStdPort.parameters.width, 384, "H3_STANDARD_PORTRAIT_V2 width 384")
        t.checkEqual(resolvedStdPort.parameters.height, 640, "H3_STANDARD_PORTRAIT_V2 height 640")
        t.checkEqual(resolvedStdPort.parameters.numFrames, 90, "H3_STANDARD_PORTRAIT_V2 frames 90")
        t.checkEqual(resolvedStdPort.parameters.numInferenceSteps, 16, "H3_STANDARD_PORTRAIT_V2 steps 16")
        t.checkEqual(resolvedStdPort.minimaxH3Fast, true, "H3_FAST_STANDARD_ON portrait")

        // H3_HIGH_LANDSCAPE_V2: 640x384 / 90f / 20st / Fast ON
        let highLandReq = GenerationRequest(
            prompt: "High Landscape",
            modelId: MiniMaxH3Configuration.modelID,
            parameters: baseParams,
            preset: MiniMaxH3Preset.high.rawValue)
        let resolvedHighLand = try! MiniMaxH3DurationPolicy.applying(to: highLandReq)
        t.checkEqual(resolvedHighLand.parameters.width, 640, "H3_HIGH_LANDSCAPE_V2 width 640")
        t.checkEqual(resolvedHighLand.parameters.height, 384, "H3_HIGH_LANDSCAPE_V2 height 384")
        t.checkEqual(resolvedHighLand.parameters.numFrames, 90, "H3_HIGH_LANDSCAPE_V2 frames 90")
        t.checkEqual(resolvedHighLand.parameters.numInferenceSteps, 20, "H3_HIGH_LANDSCAPE_V2 steps 20")
        t.checkEqual(resolvedHighLand.minimaxH3Fast, true, "H3_FAST_HIGH_ON")

        // H3_HIGH_PORTRAIT_V2: 384x640 / 90f / 20st / Fast ON
        let highPortReq = GenerationRequest(
            prompt: "High Portrait",
            presetResolutionOrientation: .portrait,
            modelId: MiniMaxH3Configuration.modelID,
            parameters: baseParams,
            preset: MiniMaxH3Preset.high.rawValue)
        let resolvedHighPort = try! MiniMaxH3DurationPolicy.applying(to: highPortReq)
        t.checkEqual(resolvedHighPort.parameters.width, 384, "H3_HIGH_PORTRAIT_V2 width 384")
        t.checkEqual(resolvedHighPort.parameters.height, 640, "H3_HIGH_PORTRAIT_V2 height 640")
        t.checkEqual(resolvedHighPort.parameters.numFrames, 90, "H3_HIGH_PORTRAIT_V2 frames 90")
        t.checkEqual(resolvedHighPort.parameters.numInferenceSteps, 20, "H3_HIGH_PORTRAIT_V2 steps 20")
        t.checkEqual(resolvedHighPort.minimaxH3Fast, true, "H3_FAST_HIGH_ON portrait")

        // H3_CUSTOM_MIN_STEPS & H3_CUSTOM_MAX_STEPS
        var minStepsParams = baseParams
        minStepsParams.numInferenceSteps = 2
        let minStepsReq = GenerationRequest(
            prompt: "Custom Min Steps",
            modelId: MiniMaxH3Configuration.modelID,
            parameters: minStepsParams,
            preset: MiniMaxH3Preset.custom.rawValue)
        let resolvedMinSteps = try! MiniMaxH3DurationPolicy.applying(to: minStepsReq)
        t.checkEqual(resolvedMinSteps.parameters.numInferenceSteps, 8, "H3_CUSTOM_MIN_STEPS clamped to 8")

        var maxStepsParams = baseParams
        maxStepsParams.numInferenceSteps = 50
        let maxStepsReq = GenerationRequest(
            prompt: "Custom Max Steps",
            modelId: MiniMaxH3Configuration.modelID,
            parameters: maxStepsParams,
            preset: MiniMaxH3Preset.custom.rawValue)
        let resolvedMaxSteps = try! MiniMaxH3DurationPolicy.applying(to: maxStepsReq)
        t.checkEqual(resolvedMaxSteps.parameters.numInferenceSteps, 24, "H3_CUSTOM_MAX_STEPS clamped to 24")

        // H3_CUSTOM_MAX_FRAMES & H3_CUSTOM_MAX_DURATION
        let maxFrames = MiniMaxH3FrameGrid.legalFrames(forRequestedDurationSeconds: 5.9)
        t.checkEqual(maxFrames, 141, "H3_CUSTOM_MAX_FRAMES is 141")
        t.checkEqual(Double(maxFrames) / 24.0, 141.0 / 24.0, "H3_CUSTOM_MAX_DURATION is ~5.875s")

        // H3_FAST_CUSTOM_DEFAULT_ON & H3_FAST_CUSTOM_OFF_ALLOWED
        var customDefaultFastReq = GenerationRequest(
            prompt: "Custom Default Fast",
            modelId: MiniMaxH3Configuration.modelID,
            parameters: baseParams,
            preset: MiniMaxH3Preset.custom.rawValue)
        let resolvedCustomDefaultFast = try! MiniMaxH3DurationPolicy.applying(to: customDefaultFastReq)
        t.checkEqual(resolvedCustomDefaultFast.minimaxH3Fast, true, "H3_FAST_CUSTOM_DEFAULT_ON")

        var customFastOffReq = GenerationRequest(
            prompt: "Custom Fast OFF",
            modelId: MiniMaxH3Configuration.modelID,
            parameters: baseParams,
            preset: MiniMaxH3Preset.custom.rawValue,
            minimaxH3Fast: false)
        let resolvedCustomFastOff = try! MiniMaxH3DurationPolicy.applying(to: customFastOffReq)
        t.checkEqual(resolvedCustomFastOff.minimaxH3Fast, false, "H3_FAST_CUSTOM_OFF_ALLOWED")
    }

    t.suite("MiniMax H3 8-Bit High Quality Model Tier Tests") {
        let registry = ModelRegistry.shared

        // 1. H3_MODEL_STANDARD_ENTRY
        let standardDescriptor = registry.descriptor(id: MiniMaxH3Configuration.standardModelID)
        t.check(standardDescriptor != nil, "H3_MODEL_STANDARD_ENTRY exists in registry")
        t.checkEqual(standardDescriptor?.id, "minimax_h3_fl2va_2bit_te", "H3_MODEL_STANDARD_ENTRY id")
        t.checkEqual(standardDescriptor?.displayName, MiniMaxH3Configuration.standardDisplayName, "H3_MODEL_STANDARD_ENTRY display name")
        t.checkEqual(standardDescriptor?.quantization, "2-bit", "H3_MODEL_STANDARD_ENTRY quantization")

        // 2. H3_MODEL_HIGH_QUALITY_ENTRY
        let hqDescriptor = registry.descriptor(id: MiniMaxH3Configuration.highQualityModelID)
        t.check(hqDescriptor != nil, "H3_MODEL_HIGH_QUALITY_ENTRY exists in registry")
        t.checkEqual(hqDescriptor?.id, "minimax_h3_fl2va_8bit_dit", "H3_MODEL_HIGH_QUALITY_ENTRY id")
        t.checkEqual(hqDescriptor?.displayName, MiniMaxH3Configuration.highQualityDisplayName, "H3_MODEL_HIGH_QUALITY_ENTRY display name")
        t.checkEqual(hqDescriptor?.quantization, "8-bit", "H3_MODEL_HIGH_QUALITY_ENTRY quantization")

        // 3. DEFAULT_H3_MODEL_REMAINS_STANDARD
        t.checkEqual(MiniMaxH3Configuration.modelID, "minimax_h3_fl2va_2bit_te", "DEFAULT_H3_MODEL_REMAINS_STANDARD")
        t.check(MiniMaxH3Configuration.isMiniMaxH3(modelID: MiniMaxH3Configuration.standardModelID), "isMiniMaxH3 recognizes standard model")
        t.check(MiniMaxH3Configuration.isMiniMaxH3(modelID: MiniMaxH3Configuration.highQualityModelID), "isMiniMaxH3 recognizes high quality model")

        // 4. H3_HQ_RECOMMENDED_MEMORY_48GB
        t.checkEqual(hqDescriptor?.recommendedUnifiedMemoryGB, 48, "H3_HQ_RECOMMENDED_MEMORY_48GB recommended 48GB")
        t.checkEqual(hqDescriptor?.minimumUnifiedMemoryGB, 32, "H3_HQ_RECOMMENDED_MEMORY_48GB minimum 32GB")

        // 5. H3_HQ_NOT_AUTO_DOWNLOADED
        t.checkEqual(hqDescriptor?.isOfficial, false, "H3_HQ_NOT_AUTO_DOWNLOADED not in official auto-download catalog")

        // 6. H3_HQ_PRESET_STANDARD: 640x384 / 90f / 16st / Fast ON
        let hqStandardReq = GenerationRequest(
            prompt: "HQ Standard Test",
            modelId: MiniMaxH3Configuration.highQualityModelID,
            preset: MiniMaxH3Preset.standard.rawValue)
        let resolvedHQStd = try! MiniMaxH3DurationPolicy.applying(to: hqStandardReq)
        t.checkEqual(resolvedHQStd.parameters.width, 640, "H3_HQ_PRESET_STANDARD width 640")
        t.checkEqual(resolvedHQStd.parameters.height, 384, "H3_HQ_PRESET_STANDARD height 384")
        t.checkEqual(resolvedHQStd.parameters.numFrames, 90, "H3_HQ_PRESET_STANDARD frames 90")
        t.checkEqual(resolvedHQStd.parameters.numInferenceSteps, 16, "H3_HQ_PRESET_STANDARD steps 16")
        t.checkEqual(resolvedHQStd.minimaxH3Fast, true, "H3_HQ_PRESET_STANDARD fast ON")

        // 7. H3_HQ_PRESET_HIGH: 640x384 / 90f / 20st / Fast ON
        let hqHighReq = GenerationRequest(
            prompt: "HQ High Test",
            modelId: MiniMaxH3Configuration.highQualityModelID,
            preset: MiniMaxH3Preset.high.rawValue)
        let resolvedHQHigh = try! MiniMaxH3DurationPolicy.applying(to: hqHighReq)
        t.checkEqual(resolvedHQHigh.parameters.width, 640, "H3_HQ_PRESET_HIGH width 640")
        t.checkEqual(resolvedHQHigh.parameters.height, 384, "H3_HQ_PRESET_HIGH height 384")
        t.checkEqual(resolvedHQHigh.parameters.numFrames, 90, "H3_HQ_PRESET_HIGH frames 90")
        t.checkEqual(resolvedHQHigh.parameters.numInferenceSteps, 20, "H3_HQ_PRESET_HIGH steps 20")
        t.checkEqual(resolvedHQHigh.minimaxH3Fast, true, "H3_HQ_PRESET_HIGH fast ON")

        // 8. H3_HQ_CUSTOM_141F
        let hqCustomReq = GenerationRequest(
            prompt: "HQ Custom 141f Test",
            modelId: MiniMaxH3Configuration.highQualityModelID,
            preset: MiniMaxH3Preset.custom.rawValue,
            minimaxH3RequestedDurationSeconds: 5.9)
        let resolvedHQCustom = try! MiniMaxH3DurationPolicy.applying(to: hqCustomReq)
        t.checkEqual(resolvedHQCustom.parameters.numFrames, 141, "H3_HQ_CUSTOM_141F frames 141")

        // 9. H3_MODEL_SWITCH_4_TO_8 & H3_MODEL_SWITCH_8_TO_4
        let snap4 = MiniMaxH3Configuration.Snapshot.current(forModelID: MiniMaxH3Configuration.standardModelID)
        let snap8 = MiniMaxH3Configuration.Snapshot.current(forModelID: MiniMaxH3Configuration.highQualityModelID)
        t.checkEqual(snap4.targetModelID, MiniMaxH3Configuration.standardModelID, "H3_MODEL_SWITCH snapshot target 4bit")
        t.checkEqual(snap8.targetModelID, MiniMaxH3Configuration.highQualityModelID, "H3_MODEL_SWITCH snapshot target 8bit")
        t.checkEqual(MiniMaxH3Configuration.expectedServerModelIDs(for: snap4.targetModelID).first, "MiniMax-H3-FL2VA-MLX-Serve-2bit-text-encoder", "H3_MODEL_SWITCH 4bit expected server id")
        t.check(MiniMaxH3Configuration.expectedServerModelIDs(for: snap8.targetModelID).contains("MiniMax-H3-FL2VA-MLX-Serve-8bit-DiT-2bit-TE"), "H3_MODEL_SWITCH 8bit expected server id")

        // 10. AUTO_MOVIE_ONE_MODEL_ONLY
        let resolverResolution4 = GenerationModelResolver.resolve(modelID: MiniMaxH3Configuration.standardModelID)
        let resolverResolution8 = GenerationModelResolver.resolve(modelID: MiniMaxH3Configuration.highQualityModelID)
        if case .runnable(let run4) = resolverResolution4 {
            t.checkEqual(run4.backend, .minimaxH3, "Resolver routes 4bit to minimaxH3 backend")
            t.checkEqual(run4.model.id, MiniMaxH3Configuration.standardModelID, "Resolver keeps 4bit model ID")
        } else {
            t.check(false, "Resolver failed to resolve 4bit H3 model")
        }
        if case .runnable(let run8) = resolverResolution8 {
            t.checkEqual(run8.backend, .minimaxH3, "Resolver routes 8bit to minimaxH3 backend")
            t.checkEqual(run8.model.id, MiniMaxH3Configuration.highQualityModelID, "Resolver keeps 8bit model ID")
        } else {
            t.check(false, "Resolver failed to resolve 8bit H3 model")
        }

        // 11. OLD_PROJECT_MODEL_COMPATIBILITY
        let oldProjectRes = GenerationModelResolver.resolve(modelID: "minimax_h3_fl2va_2bit_te")
        if case .runnable(let runOld) = oldProjectRes {
            t.checkEqual(runOld.model.id, "minimax_h3_fl2va_2bit_te", "OLD_PROJECT_MODEL_COMPATIBILITY preserved")
        } else {
            t.check(false, "Failed to resolve old H3 project model ID")
        }
    }
}
