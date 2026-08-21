import Foundation
@testable import LTXVideoGeneratorCore

private final class H3FakeTransport: MiniMaxH3HTTPTransport {
    var healthStatus = 200
    var healthObject: [String: Any] = ["status": "ok"]
    var modelsStatus = 200
    var modelEntries: [[String: Any]] = [[
        "id": MiniMaxH3Configuration.expectedServerModelID,
        "loaded": true,
        "state": "ready",
    ]]

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
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
        for relative in [
            "lib/libmlx.dylib", "lib/libmlxc.dylib", "lib/libllama.dylib",
            "lib/libwebp.dylib", "lib/libsharpyuv.dylib", "lib/mlx.metallib",
        ] {
            try Data([1, 2, 3]).write(to: source.appendingPathComponent(relative))
        }

        let manager = MiniMaxH3ManagedRuntimeManager(runtimesDirectory: managedRoot)
        t.checkEqual(manager.evaluateStatus(), .notInstalled, "fresh Dev-style runtime root starts Not Installed")
        let inspected = try manager.inspectBundle(at: source)
        t.checkEqual(inspected.runtimeVersion, "26.8.9", "runtime version is read from the native binary")
        t.checkEqual(inspected.architecture, "arm64", "only the native arm64 bundle is accepted")
        t.checkEqual(inspected.licenseClassification, .bundleAllowed, "complete MIT/NOTICE/Apache files classify BUNDLE_ALLOWED")

        let installed = h3Await { try? await manager.install(from: source) }
        t.check(installed != nil, "existing local runtime bundle installs without a download")
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
        let chain4 = try MiniMaxH3DurationPolicy.plan(requestedDurationSeconds: 6.0)
        t.checkEqual(chain4.chainWindows, 4, "6 seconds selects chain 4")
        t.checkEqual(chain4.expectedTotalFrames, 153, "chain 4 expects 153 returned frames")
        t.checkEqual(chain4.expectedDurationSeconds, 6.375, "chain 4 expected duration is 153/24")
        let chain5 = try MiniMaxH3DurationPolicy.plan(requestedDurationSeconds: 8.0)
        t.checkEqual(chain5.chainWindows, 5, "8 seconds uses chain 5 only because duration requires it")
        t.check(chain5.hasElevatedDriftRisk, "chain 5 is internally marked higher drift risk")
        let chain6 = try MiniMaxH3DurationPolicy.plan(requestedDurationSeconds: 9.5)
        t.checkEqual(chain6.chainWindows, 6, "9.5 seconds selects maximum proven chain")
        t.checkEqual(chain6.expectedTotalFrames, 229, "chain 6 expects 229 frames")
        t.checkEqual(MiniMaxH3DurationPolicy.maximumDurationSeconds, 229.0 / 24.0, "maximum duration is evidence-derived")
        t.checkThrows(
            MiniMaxH3Error.unsupportedCapability("shot durations above the proven 9.54-second chain limit"),
            "duration beyond chain 6 fails closed") {
                _ = try MiniMaxH3DurationPolicy.plan(requestedDurationSeconds: 9.6)
            }
        for frames in MiniMaxH3DurationPolicy.singleWindowFrames {
            t.check((frames - 5) % 17 == 0, "\(frames) follows the 17k+5 ladder")
        }

        var parameters = GenerationParameters.default
        parameters.width = 768
        parameters.height = 512
        parameters.numFrames = 144
        let request = GenerationRequest(
            prompt: "A person turns toward camera.",
            modelId: MiniMaxH3Configuration.modelID,
            parameters: parameters,
            targetDurationSeconds: 6.0)
        let resolved = try MiniMaxH3DurationPolicy.applying(to: request)
        t.checkEqual(resolved.parameters.width, 512, "H3 effective width is proven canvas")
        t.checkEqual(resolved.parameters.height, 288, "H3 effective height is proven canvas")
        t.checkEqual(resolved.parameters.fps, 24, "H3 effective FPS is proven setting")
        t.checkEqual(resolved.parameters.numInferenceSteps, 8, "H3 effective steps are proven setting")
        t.checkEqual(resolved.parameters.numFrames, 39, "chained request sends 39 frames per window")
        t.checkEqual(resolved.minimaxH3ExpectedFrames, 153, "effective total frames remain separate")
        t.checkEqual(resolved.minimaxH3RequestedDurationSeconds, 6.0, "semantic requested duration remains separate")
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
}
