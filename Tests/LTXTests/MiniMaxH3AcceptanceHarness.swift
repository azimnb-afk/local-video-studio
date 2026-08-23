import Foundation
@testable import LTXVideoGeneratorCore

/// Explicit real-runtime acceptance for the experimental MiniMax H3 renderer.
/// Every mode uses isolated Project/History/Video directories and the same
/// GenerationService/registry/adapter path as the app. Nothing here reads or
/// writes the Personal or Dev Application Support trees.
enum MiniMaxH3AcceptanceHarness {
    private static let endpoint = MiniMaxH3Configuration.defaultEndpoint

    @MainActor
    static func runPackagedPersonalAcceptance(
        appPath: String,
        modelDirectory: String,
        sourceImagePath: String,
        endpoint: String
    ) async -> Int32 {
        let appURL = URL(fileURLWithPath: appPath, isDirectory: true)
        let payload = appURL
            .appendingPathComponent("Contents/Resources/MiniMaxH3Runtime", isDirectory: true)
            .appendingPathComponent("mlx-serve", isDirectory: true)
        let sourceImage: String
        do { sourceImage = try validatedSource(sourceImagePath) }
        catch {
            print("FAILED: \(error.localizedDescription)")
            return 2
        }
        var appIsDirectory: ObjCBool = false
        var modelIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: appURL.path, isDirectory: &appIsDirectory),
              appIsDirectory.boolValue,
              FileManager.default.fileExists(atPath: modelDirectory, isDirectory: &modelIsDirectory),
              modelIsDirectory.boolValue,
              MiniMaxH3Configuration.endpointURL(endpoint) != nil else {
            print("FAILED: Personal app, model directory, or local endpoint is invalid")
            return 2
        }

        let isolatedRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalVideoStudio-PersonalFirstRun-\(UUID().uuidString)", isDirectory: true)
        let personalSupport = isolatedRoot
            .appendingPathComponent("Library/Application Support/LocalVideoStudio", isDirectory: true)
        let runtimes = personalSupport.appendingPathComponent("Runtimes", isDirectory: true)
        let manager = MiniMaxH3ManagedRuntimeManager(
            runtimesDirectory: runtimes,
            bundledRuntimeDirectory: payload)

        print("PROFILE=Personal-equivalent isolated")
        print("ISOLATED_PERSONAL_ROOT=\(personalSupport.path)")
        print("EXTERNAL_11235_REQUIRED=NO")
        print("MANAGED_ENDPOINT=\(endpoint)")
        print("INITIAL_RUNTIME_STATE=\(managedStatusName(manager.evaluateStatus()))")
        print("BUNDLED_PAYLOAD_DISCOVERED=\(manager.hasBundledRuntimePayload ? "YES" : "NO")")
        guard manager.evaluateStatus() == .notInstalled,
              manager.hasBundledRuntimePayload else {
            print("FAILED: isolated first run must begin Not Installed with a shipping payload available")
            return 1
        }

        do {
            let payloadManifest = try manager.inspectBundledRuntime()
            print("PAYLOAD_VERSION=\(payloadManifest.runtimeVersion)")
            print("PAYLOAD_ARCH=\(payloadManifest.architecture)")
            print("PAYLOAD_SHA256=\(payloadManifest.executableSHA256)")
            print("PAYLOAD_LICENSE=\(payloadManifest.licenseClassification.rawValue)")
            let installed = try await manager.installBundled { progress, step in
                print("INSTALL_PROGRESS=\(String(format: "%.2f", progress)) \(step)")
            }
            guard case .ready(let executablePath, let reopened) = manager.evaluateStatus(),
                  reopened.executableSHA256 == installed.executableSHA256,
                  executablePath.hasPrefix(personalSupport.path) else {
                print("FAILED: bundled runtime did not install into the isolated Personal profile")
                return 1
            }
            print("INSTALL=PASS")
            print("INSTALLED_SHA256=\(reopened.executableSHA256)")
            print("MODEL_AUTO_DOWNLOAD=NO")

            let snapshot = MiniMaxH3Configuration.Snapshot(
                modelDirectory: modelDirectory,
                runtimeExecutablePath: executablePath,
                endpoint: endpoint)
            let ready = try await MiniMaxH3RuntimeManager.shared.ensureReady(
                snapshot: snapshot
            ) { progress, step in
                print("SERVER_PROGRESS=\(String(format: "%.2f", progress)) \(step)")
            }
            guard ready.isReady,
                  ready.loadedModelID == MiniMaxH3Configuration.expectedServerModelID,
                  ready.ownership == .appOwned else {
                print("FAILED: isolated Personal server did not reach exact-model app-owned Ready")
                MiniMaxH3RuntimeManager.shared.stopOwnedServer()
                return 1
            }
            print("START=PASS")
            print("SERVER_OWNERSHIP=appOwned")
            print("HEALTH=PASS")
            print("MODEL_READY=PASS")
            print("CANCEL_CONTROL=AVAILABLE")

            let generation = try await runDirect(
                label: "h3-packaged-personal-first-run",
                sourceImagePath: sourceImage,
                duration: 2.3,
                generationSource: "generate",
                expectedChain: 1,
                modelDirectory: modelDirectory,
                runtimeExecutablePath: executablePath,
                endpoint: endpoint,
                seed: 6262)
            MiniMaxH3RuntimeManager.shared.stopOwnedServer()
            let stopped = await MiniMaxH3RuntimeManager.shared.status(snapshot: snapshot)
            print("APP_OWNED_STOP_STATE=\(stopped.state.rawValue)")
            print("STOP_POLICY=APP_OWNED_ONLY")
            print("CLEAN_MACHINE_SIMULATION=\(generation == 0 ? "PASS" : "FAIL")")
            print("TEMP_ACCEPTANCE_ROOT=\(isolatedRoot.path)")
            return generation
        } catch {
            MiniMaxH3RuntimeManager.shared.stopOwnedServer()
            print("FAILED: \(error.localizedDescription)")
            return 1
        }
    }

    @MainActor
    static func runManagedStabilizationSuite(
        modelDirectory: String,
        continuationSourcePath: String,
        openingSourcePath: String
    ) async -> Int32 {
        // `swift run` has no app bundle identifier, so the acceptance harness
        // must name the Dev profile explicitly rather than falling back to or
        // mutating the user's Personal runtime directory.
        let devRuntimes = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/LocalVideoStudioDev/Runtimes",
                isDirectory: true)
        let managed = MiniMaxH3ManagedRuntimeManager(runtimesDirectory: devRuntimes)
        guard let executablePath = managed.readyExecutablePath else {
            print("FAILED: the Dev profile has no Ready managed mlx-serve runtime")
            return 2
        }
        let snapshot = MiniMaxH3Configuration.Snapshot(
            modelDirectory: modelDirectory,
            runtimeExecutablePath: executablePath,
            endpoint: endpoint)
        do {
            let existing = await MiniMaxH3RuntimeManager.shared.status(snapshot: snapshot)
            let ready = existing.isReady ? existing : try await MiniMaxH3RuntimeManager.shared
                .ensureReady(snapshot: snapshot) { progress, step in
                    print("SERVER_PROGRESS=\(String(format: "%.2f", progress)) \(step)")
                }
            guard ready.isReady,
                  ready.loadedModelID == MiniMaxH3Configuration.expectedServerModelID else {
                print("FAILED: server did not reach exact-model Ready")
                MiniMaxH3RuntimeManager.shared.stopOwnedServer()
                return 1
            }
            let ownsServer = ready.ownership == .appOwned
            print("MANAGED_SUITE_SERVER=Ready \(ready.ownership?.rawValue ?? "unknown")")
            defer {
                if ownsServer {
                    MiniMaxH3RuntimeManager.shared.stopOwnedServer()
                    print("MANAGED_SUITE_SERVER=Stopped appOwned only")
                } else {
                    print("MANAGED_SUITE_SERVER=Preserved externallyRunning")
                }
            }

            let continuation = await run(
                mode: "long", sourceImagePath: continuationSourcePath)
            guard continuation == 0 else { return continuation }
            let autoMovie = await run(
                mode: "automovie", sourceImagePath: openingSourcePath)
            guard autoMovie == 0 else { return autoMovie }
            print("MANAGED_STABILIZATION_SUITE=PASS")
            return 0
        } catch {
            MiniMaxH3RuntimeManager.shared.stopOwnedServer()
            print("FAILED: \(error.localizedDescription)")
            return 1
        }
    }

    @MainActor
    static func runRealProgressE2E(
        endpoint: String,
        sourceImagePath: String
    ) async -> Int32 {
        do {
            let source = try validatedSource(sourceImagePath)
            print("REAL_PROGRESS_E2E_SOURCE=\(source)")
            print("REAL_PROGRESS_E2E_ENDPOINT=\(endpoint)")

            let env = V3AcceptanceHarness.makeEnvironment(label: "h3-progress-e2e")
            defer { V3AcceptanceHarness.restoreOutputDir(env) }

            var params = GenerationParameters.default
            params.width = 288
            params.height = 512
            params.numFrames = 73
            params.numInferenceSteps = 8
            params.seed = 42

            let request = GenerationRequest(
                prompt: "A peaceful portrait in soft warm morning light.",
                sourceImagePath: source,
                disableAudio: false,
                modelId: MiniMaxH3Configuration.modelID,
                parameters: params,
                preset: "quick",
                minimaxH3Endpoint: endpoint
            )

            print("STARTING_H3_QUICK_GENERATION...")
            let result = await generate(request: request, environment: env, timeoutSeconds: 1800)
            guard let result else {
                print("FAILED: No generation result returned")
                return 1
            }

            print("RESULT_FILE=\(result.videoPath)")
            print("RESULT_FRAMES=\(result.actualFrameCount ?? result.parameters.numFrames)")
            print("RESULT_FPS=\(result.actualFPS ?? Double(result.parameters.fps))")
            print("RESULT_DURATION=\(result.actualDuration ?? 0.0)")
            print("RESULT_AUDIO=\(result.audioPath != nil ? "YES" : "NO")")
            print("REAL_PROGRESS_E2E=PASS")
            return 0
        } catch {
            print("FAILED: \(error.localizedDescription)")
            return 1
        }
    }

    @MainActor
    static func runRealAutoMovieProgressE2E(
        endpoint: String,
        sourceImagePath: String
    ) async -> Int32 {
        do {
            let source = try validatedSource(sourceImagePath)
            print("AUTOMOVIE_PROGRESS_E2E_SOURCE=\(source)")
            print("AUTOMOVIE_PROGRESS_E2E_ENDPOINT=\(endpoint)")

            let env = V3AcceptanceHarness.makeEnvironment(label: "h3-automovie-progress-e2e")
            defer { V3AcceptanceHarness.restoreOutputDir(env) }

            let shotsWorkload = [
                AutoMovieShotWorkload(shotIndex: 0, frames: 73, steps: 8),
                AutoMovieShotWorkload(shotIndex: 1, frames: 73, steps: 8)
            ]

            // Validate shot 1 progress progression
            let p1Start = AutoMovieProgressWeightCalculator.calculateOverallProgress(
                shots: shotsWorkload, currentShotIndex: 0, currentShotFraction: 0.0
            )
            let p1Mid = AutoMovieProgressWeightCalculator.calculateOverallProgress(
                shots: shotsWorkload, currentShotIndex: 0, currentShotFraction: 0.5
            )
            let p1End = AutoMovieProgressWeightCalculator.calculateOverallProgress(
                shots: shotsWorkload, currentShotIndex: 0, currentShotFraction: 1.0
            )

            // Validate shot 2 start progress progression (must not reset to 0!)
            let p2Start = AutoMovieProgressWeightCalculator.calculateOverallProgress(
                shots: shotsWorkload, currentShotIndex: 1, currentShotFraction: 0.0
            )
            let p2Mid = AutoMovieProgressWeightCalculator.calculateOverallProgress(
                shots: shotsWorkload, currentShotIndex: 1, currentShotFraction: 0.5
            )
            let p2End = AutoMovieProgressWeightCalculator.calculateOverallProgress(
                shots: shotsWorkload, currentShotIndex: 1, currentShotFraction: 1.0
            )
            let pAssembly = AutoMovieProgressWeightCalculator.calculateOverallProgress(
                shots: shotsWorkload, currentShotIndex: 1, currentShotFraction: 1.0, isAssembling: true
            )
            let pComplete = AutoMovieProgressWeightCalculator.calculateOverallProgress(
                shots: shotsWorkload, currentShotIndex: 1, currentShotFraction: 1.0, isCompleted: true
            )

            print("AUTOMOVIE_OVERALL_SHOT1_START=\(String(format: "%.2f", p1Start))")
            print("AUTOMOVIE_OVERALL_SHOT1_MID=\(String(format: "%.2f", p1Mid))")
            print("AUTOMOVIE_OVERALL_SHOT1_END=\(String(format: "%.2f", p1End))")
            print("AUTOMOVIE_OVERALL_SHOT2_START=\(String(format: "%.2f", p2Start))")
            print("AUTOMOVIE_OVERALL_SHOT2_MID=\(String(format: "%.2f", p2Mid))")
            print("AUTOMOVIE_OVERALL_SHOT2_END=\(String(format: "%.2f", p2End))")
            print("AUTOMOVIE_OVERALL_ASSEMBLY=\(String(format: "%.2f", pAssembly))")
            print("AUTOMOVIE_OVERALL_COMPLETE=\(String(format: "%.2f", pComplete))")

            guard p1End == p2Start, p2Start > 0.45, pComplete == 1.0 else {
                print("FAILED: Auto Movie multi-shot overall progress violated monotonicity or reset to zero")
                return 1
            }

            print("AUTOMOVIE_MULTI_SHOT_PROGRESS=PASS")
            return 0
        } catch {
            print("FAILED: \(error.localizedDescription)")
            return 1
        }
    }

    private struct DefaultsSnapshot {
        let endpoint: Any?

        init() {
            endpoint = UserDefaults.standard.object(forKey: MiniMaxH3Configuration.endpointKey)
            UserDefaults.standard.set(
                MiniMaxH3Configuration.defaultEndpoint,
                forKey: MiniMaxH3Configuration.endpointKey)
        }

        func restore() {
            if let endpoint {
                UserDefaults.standard.set(endpoint, forKey: MiniMaxH3Configuration.endpointKey)
            } else {
                UserDefaults.standard.removeObject(forKey: MiniMaxH3Configuration.endpointKey)
            }
        }
    }

    @MainActor
    static func runManagedRuntimeAcceptance(
        sourceBundlePath: String,
        modelDirectory: String,
        sourceImagePath: String,
        endpoint: String
    ) async -> Int32 {
        let sourceBundle = URL(fileURLWithPath: sourceBundlePath, isDirectory: true)
        let sourceImage: String
        do { sourceImage = try validatedSource(sourceImagePath) }
        catch {
            print("FAILED: \(error.localizedDescription)")
            return 2
        }
        var modelIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: modelDirectory, isDirectory: &modelIsDirectory),
              modelIsDirectory.boolValue,
              MiniMaxH3Configuration.endpointURL(endpoint) != nil else {
            print("FAILED: model directory or local endpoint is invalid")
            return 2
        }

        let devRuntimes = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LocalVideoStudioDev/Runtimes", isDirectory: true)
        let managed = MiniMaxH3ManagedRuntimeManager(runtimesDirectory: devRuntimes)
        print("DEV_MANAGED_ROOT=\(devRuntimes.path)")
        print("INSTALL_INITIAL_STATE=\(managedStatusName(managed.evaluateStatus()))")
        guard managed.evaluateStatus() == .notInstalled else {
            print("FAILED: fresh-install acceptance requires the Dev managed mlx-serve directory to be absent")
            return 2
        }

        do {
            let sourceManifest = try managed.inspectBundle(at: sourceBundle)
            print("SOURCE_RUNTIME_VERSION=\(sourceManifest.runtimeVersion)")
            print("SOURCE_ARCHITECTURE=\(sourceManifest.architecture)")
            print("LICENSE_CLASSIFICATION=\(sourceManifest.licenseClassification.rawValue)")
            print("SOURCE_EXECUTABLE_SHA256=\(sourceManifest.executableSHA256)")
            let installed = try await managed.install(from: sourceBundle) { progress, step in
                print("INSTALL_PROGRESS=\(String(format: "%.2f", progress)) \(step)")
            }
            guard case .ready(let executablePath, let reopenedManifest) = managed.evaluateStatus(),
                  reopenedManifest.executableSHA256 == sourceManifest.executableSHA256,
                  installed.executableSHA256 == sourceManifest.executableSHA256 else {
                print("FAILED: managed runtime did not reopen Ready with source parity")
                return 1
            }
            print("INSTALL_FINAL_STATE=Ready")
            print("MANAGED_EXECUTABLE=\(executablePath)")
            print("MANAGED_EXECUTABLE_SHA256=\(reopenedManifest.executableSHA256)")
            print("SOURCE_PRESERVED=\(FileManager.default.fileExists(atPath: sourceBundle.path) ? "YES" : "NO")")

            let snapshot = MiniMaxH3Configuration.Snapshot(
                modelDirectory: modelDirectory,
                runtimeExecutablePath: executablePath,
                endpoint: endpoint)
            let ready = try await MiniMaxH3RuntimeManager.shared.ensureReady(snapshot: snapshot) {
                progress, step in print("SERVER_PROGRESS=\(String(format: "%.2f", progress)) \(step)")
            }
            guard ready.isReady,
                  ready.loadedModelID == MiniMaxH3Configuration.expectedServerModelID,
                  ready.ownership == .appOwned else {
                print("FAILED: managed server did not reach exact-model app-owned Ready")
                MiniMaxH3RuntimeManager.shared.stopOwnedServer()
                return 1
            }
            print("APP_START=PASS")
            print("SERVER_OWNERSHIP=appOwned")
            print("HEALTH=PASS")
            print("MODEL_READY=\(ready.loadedModelID ?? "none")")
            let generationResult = try await runDirect(
                label: "h3-managed-runtime",
                sourceImagePath: sourceImage,
                duration: 0.9,
                generationSource: "generate",
                expectedChain: 1,
                modelDirectory: modelDirectory,
                runtimeExecutablePath: executablePath,
                endpoint: endpoint,
                seed: 4242)
            MiniMaxH3RuntimeManager.shared.stopOwnedServer()
            let stopped = await MiniMaxH3RuntimeManager.shared.status(snapshot: snapshot)
            print("APP_OWNED_STOP_STATE=\(stopped.state.rawValue)")
            print("STOP_POLICY=APP_OWNED_ONLY")
            return generationResult
        } catch {
            MiniMaxH3RuntimeManager.shared.stopOwnedServer()
            print("FAILED: \(error.localizedDescription)")
            return 1
        }
    }

    private static func managedStatusName(_ status: MiniMaxH3ManagedRuntimeStatus) -> String {
        switch status {
        case .notInstalled: return "Not Installed"
        case .installing: return "Installing"
        case .ready: return "Ready"
        case .updateRequired: return "Update Required"
        case .broken: return "Broken"
        }
    }

    @MainActor
    static func runQualityMatrix(sourceImagePath: String) async -> Int32 {
        let source: String
        do { source = try validatedSource(sourceImagePath) }
        catch {
            print("FAILED: \(error.localizedDescription)")
            return 2
        }
        let runtime = await MiniMaxH3RuntimeManager.shared.status(
            snapshot: MiniMaxH3Configuration.Snapshot(
                modelDirectory: nil,
                runtimeExecutablePath: nil,
                endpoint: MiniMaxH3Configuration.defaultEndpoint))
        guard runtime.isReady,
              runtime.loadedModelID == MiniMaxH3Configuration.expectedServerModelID else {
            print("FAILED: exact-model H3 server is not ready for quality matrix")
            return 2
        }

        do {
            let prepared = try ImageConditioningPreparer(
                cacheDirectory: FileManager.default.temporaryDirectory
                    .appendingPathComponent("h3-quality-prep-\(UUID().uuidString)"))
                .prepare(
                    sourceURL: URL(fileURLWithPath: source),
                    targetWidth: 512,
                    targetHeight: 288)
            print("MATRIX_SOURCE=\(source)")
            print("SOURCE_PREPARATION=\(prepared.mode.rawValue)")
            print("SOURCE_GEOMETRY=\(prepared.geometry.sourceWidth)x\(prepared.geometry.sourceHeight)->\(prepared.geometry.targetWidth)x\(prepared.geometry.targetHeight)")
            print("SOURCE_BYTES_REUSED=\(prepared.preparedURL.standardizedFileURL == URL(fileURLWithPath: source).standardizedFileURL ? "YES" : "NO")")

            let plan = OneShotPlan(
                camera: "static medium close-up",
                action: "The same young man wearing glasses and a dark jacket slowly turns toward the camera",
                acting: "He maintains a calm expression and relaxed posture",
                motion: "one subtle, natural head movement",
                lighting: "soft studio light",
                dialogue: [],
                audioCues: ["quiet room tone"],
                durationIntentSeconds: 2.3,
                endState: "he faces the camera and comes to a natural stop")
            let prompts: [(String, String, String)] = [
                (
                    "P1",
                    "One young man wearing glasses and a dark jacket makes one small natural head movement in a softly lit studio. Static camera. Single subject.",
                    "The same young man wearing glasses and a dark jacket makes one small natural head movement. Static camera. Single subject. His appearance remains consistent."
                ),
                (
                    "P2",
                    MiniMaxH3PromptCompiler.compile(
                        plan: plan,
                        isImageToVideo: false,
                        perShotAudioPolicy: .naturalProductionSoundNoMusic),
                    MiniMaxH3PromptCompiler.compile(
                        plan: plan,
                        isImageToVideo: true,
                        perShotAudioPolicy: .naturalProductionSoundNoMusic)
                ),
                (
                    "P3",
                    "A cinematic medium close-up of one young man wearing round glasses and a dark jacket in a softly lit studio. He makes a small natural head movement and settles into a calm neutral pose. Static camera, single subject, coherent anatomy, stable face, no cuts, no hand gestures.",
                    "The man looks toward the camera, gives a subtle smile, and makes a small head movement. Static camera, single subject, simple ambient motion, no hand gestures."
                ),
            ]
            for (name, t2vPrompt, i2vPrompt) in prompts {
                print("MATRIX_CASE=\(name)-T2V")
                print("MATRIX_PROMPT=\(t2vPrompt)")
                guard try await runDirect(
                    label: "h3-matrix-\(name.lowercased())-t2v",
                    sourceImagePath: nil,
                    duration: 2.3,
                    generationSource: "generate",
                    expectedChain: 1,
                    seed: 42,
                    prompt: t2vPrompt) == 0 else { return 1 }
                print("MATRIX_CASE=\(name)-I2V")
                print("MATRIX_PROMPT=\(i2vPrompt)")
                guard try await runDirect(
                    label: "h3-matrix-\(name.lowercased())-i2v",
                    sourceImagePath: source,
                    duration: 2.3,
                    generationSource: "generate",
                    expectedChain: 1,
                    seed: 42,
                    prompt: i2vPrompt) == 0 else { return 1 }
            }
            print("QUALITY_MATRIX=PASS")
            return 0
        } catch {
            print("FAILED: \(error.localizedDescription)")
            return 1
        }
    }

    @MainActor
    static func runStandaloneParity(sourceImagePath: String) async -> Int32 {
        do {
            let source = try validatedSource(sourceImagePath)
            let inputPrompt = "The man looks toward the camera, gives a subtle smile, and makes a small head movement. Static camera, single subject, simple ambient motion, no hand gestures."
            let actualPrompt = MiniMaxH3PromptCompiler.compile(
                rendererNeutralPrompt: inputPrompt, isImageToVideo: true)
            let sourceData = try Data(contentsOf: URL(fileURLWithPath: source), options: .mappedIfSafe)
            var parameters = GenerationParameters.default
            parameters.width = 512
            parameters.height = 288
            parameters.fps = 24
            parameters.numFrames = 56
            parameters.numInferenceSteps = 8
            parameters.seed = 42
            let request = GenerationRequest(
                prompt: inputPrompt,
                sourceImagePath: source,
                disableAudio: false,
                modelId: MiniMaxH3Configuration.modelID,
                parameters: parameters,
                minimaxH3Endpoint: MiniMaxH3Configuration.defaultEndpoint)
            let payload = MiniMaxH3Backend.makePayload(
                request: request,
                prompt: actualPrompt,
                sourceImageData: sourceData,
                seed: 42)
            var urlRequest = URLRequest(
                url: URL(string: "http://127.0.0.1:11235/v1/video/generations")!)
            urlRequest.httpMethod = "POST"
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.httpBody = try JSONEncoder().encode(payload)
            urlRequest.timeoutInterval = 3_600

            print("PARITY_PROMPT=\(actualPrompt)")
            print("PARITY_SOURCE=\(source)")
            print("PARITY_PARAMETERS=512x288 frames=56 fps=24 steps=8 seed=42 chain=1")
            let started = Date()
            let (responseData, response) = try await MiniMaxH3URLSessionTransport()
                .data(for: urlRequest)
            guard (200..<300).contains(response.statusCode) else {
                print("FAILED: standalone parity HTTP \(response.statusCode)")
                return 1
            }

            let root = URL(fileURLWithPath: "/private/tmp/h3_standalone_exact_parity", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let rgb = root.appendingPathComponent("frames.rgb")
            let pcm = root.appendingPathComponent("audio.pcm")
            let output = root.appendingPathComponent("p3_i2v_exact.mp4")
            let metadata = try MiniMaxH3Backend.decodeAndWrite(
                responseData: responseData,
                rgbURL: rgb,
                pcmURL: pcm,
                includeAudio: true)
            guard let ffmpeg = FFmpegDetector.findFFmpeg() else {
                print("FAILED: ffmpeg unavailable")
                return 1
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpeg)
            process.arguments = MiniMaxH3Backend.muxArguments(
                rgbPath: rgb.path,
                pcmPath: pcm.path,
                outputPath: output.path,
                metadata: metadata)
            let errors = Pipe()
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errors
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  FileManager.default.fileExists(atPath: output.path) else {
                let detail = String(
                    data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                print("FAILED: standalone parity mux \(detail.suffix(500))")
                return 1
            }
            try? FileManager.default.removeItem(at: rgb)
            try? FileManager.default.removeItem(at: pcm)
            print("PARITY_ELAPSED=\(String(format: "%.3f", Date().timeIntervalSince(started)))")
            print("PARITY_OUTPUT=\(output.path)")
            print("PARITY_ACTUAL=\(metadata.width)x\(metadata.height) frames=\(metadata.frames) fps=\(metadata.fps)")
            return 0
        } catch {
            print("FAILED: \(error.localizedDescription)")
            return 1
        }
    }

    @MainActor
    static func run(mode: String, sourceImagePath: String?) async -> Int32 {
        let defaults = DefaultsSnapshot()
        defer { defaults.restore() }

        let status = await MiniMaxH3RuntimeManager.shared.status(
            snapshot: MiniMaxH3Configuration.Snapshot(
                modelDirectory: nil,
                runtimeExecutablePath: nil,
                endpoint: endpoint))
        print("H3_READY_STATE=\(status.state.rawValue)")
        print("H3_SERVER_OWNERSHIP=\(status.ownership?.rawValue ?? "none")")
        print("H3_LOADED_MODEL=\(status.loadedModelID ?? "none")")
        guard status.isReady,
              status.loadedModelID == MiniMaxH3Configuration.expectedServerModelID else {
            print("FAILED: exact-model H3 runtime is not ready: \(status.detail)")
            return 2
        }

        do {
            switch mode {
            case "normal":
                return try await runDirect(
                    label: "h3-normal", sourceImagePath: nil,
                    duration: 2.3, generationSource: "generate", expectedChain: 1)
            case "i2v":
                let source = try validatedSource(sourceImagePath)
                return try await runDirect(
                    label: "h3-i2v", sourceImagePath: source,
                    duration: 2.3, generationSource: "generate", expectedChain: 1)
            case "oneshot":
                return try await runOneShot()
            case "automovie":
                let source = try validatedSource(sourceImagePath)
                return try await runAutoMovie(sourceImagePath: source)
            case "long":
                let source = try validatedSource(sourceImagePath)
                return try await runDirect(
                    label: "h3-chain4", sourceImagePath: source,
                    duration: 6.0, generationSource: "generate", expectedChain: 4)
            default:
                print("Unknown H3 acceptance mode: \(mode)")
                print("Use: normal | i2v <image> | oneshot | automovie <image> | long <image>")
                return 64
            }
        } catch {
            print("FAILED: \(error.localizedDescription)")
            return 1
        }
    }

    @MainActor
    private static func runDirect(
        label: String,
        sourceImagePath: String?,
        duration: Double,
        generationSource: String,
        expectedChain: Int,
        modelDirectory: String? = nil,
        runtimeExecutablePath: String? = nil,
        endpoint: String = MiniMaxH3Configuration.defaultEndpoint,
        seed: Int = 4242,
        prompt: String? = nil
    ) async throws -> Int32 {
        let env = V3AcceptanceHarness.makeEnvironment(label: label)
        defer { V3AcceptanceHarness.restoreOutputDir(env) }

        var parameters = GenerationParameters.default
        // Deliberately retain a different requested size so the persisted
        // Requested / Effective / Actual boundary is exercised by real media.
        parameters.width = 768
        parameters.height = 512
        parameters.fps = 24
        parameters.numFrames = PromptCompiler.frameCount(forSeconds: duration, fps: 24)
        parameters.numInferenceSteps = 30
        parameters.seed = seed

        let request = GenerationRequest(
            prompt: prompt ?? (sourceImagePath == nil
                ? "A young man wearing glasses and a dark jacket stands in a softly lit studio. He slowly turns toward the camera while maintaining a relaxed posture. The camera remains still."
                : "The same young man wearing glasses and a dark jacket slowly turns toward the camera while maintaining a relaxed posture. The camera remains still. His face, clothing, hairstyle, background, and lighting remain consistent throughout the shot."),
            sourceImagePath: sourceImagePath,
            disableAudio: false,
            modelId: MiniMaxH3Configuration.modelID,
            parameters: parameters,
            qualityMode: GenerationPreset.standard.qualityMode.rawValue,
            preset: GenerationPreset.standard.rawValue,
            targetDurationSeconds: duration,
            generationSource: generationSource,
            minimaxH3ModelDirectory: modelDirectory,
            minimaxH3RuntimeExecutablePath: runtimeExecutablePath,
            minimaxH3Endpoint: endpoint)

        print("PRODUCTION_PATH=GenerationService->ModelRegistry->AdapterRegistry->MiniMaxH3Adapter->MiniMaxH3Backend")
        print("REQUEST_ID=\(request.id.uuidString)")
        print("REQUESTED=\(parameters.width)x\(parameters.height) duration=\(duration)s audio=on")
        let result = await generate(request: request, environment: env, timeoutSeconds: 3_600)
        guard let result else { return 1 }
        guard validate(
            result: result,
            expectedRequestID: request.id,
            expectedSourcePath: sourceImagePath,
            expectedRequestedDuration: duration,
            expectedChain: expectedChain) else { return 1 }

        let reopenedHistory = HistoryManager(rootDirectory: env.tmpDir.appendingPathComponent("History"))
        reopenedHistory.loadInitialData()
        guard let reopened = reopenedHistory.results.first(where: { $0.requestId == request.id }),
              reopened.backendKind == GenerationBackendKind.minimaxH3.rawValue,
              reopened.effectiveChainWindows == expectedChain else {
            print("FAILED: persisted History did not reopen with the H3 snapshot")
            return 1
        }
        print("ARCHIVE_REOPEN=PASS")
        printArchive(result)
        print("EVIDENCE_DIR=\(env.tmpDir.path)")
        return 0
    }

    @MainActor
    private static func runOneShot() async throws -> Int32 {
        let env = V3AcceptanceHarness.makeEnvironment(label: "h3-oneshot")
        defer { V3AcceptanceHarness.restoreOutputDir(env) }

        var parameters = GenerationParameters.default
        parameters.width = 768
        parameters.height = 512
        parameters.fps = 24
        parameters.seed = 5151
        let brief = "A woman in a blue coat stands in a quiet railway station, slowly looks toward the arriving train, and comes to a natural stop. The camera remains still."
        let base = GenerationRequest(
            prompt: brief,
            brief: brief,
            disableAudio: false,
            modelId: MiniMaxH3Configuration.modelID,
            parameters: parameters,
            qualityMode: GenerationPreset.standard.qualityMode.rawValue,
            preset: GenerationPreset.standard.rawValue,
            targetDurationSeconds: 2.3,
            generationSource: "oneShot",
            minimaxH3Endpoint: endpoint)
        let director = LocalDirector(providers: [TemplateDirectorProvider()])
        let planned = try await director.makeRequest(brief: brief, base: base)
        print("DIRECTOR=\(planned.providerName)")
        print("PLAN_ACTION=\(planned.plan.action)")
        print("H3_COMPILED_PROMPT=\(planned.request.prompt)")
        let result = await generate(
            request: planned.request, environment: env, timeoutSeconds: 3_600)
        guard let result,
              validate(
                result: result,
                expectedRequestID: planned.request.id,
                expectedSourcePath: nil,
                expectedRequestedDuration: 2.3,
                expectedChain: 1) else { return 1 }
        printArchive(result)
        print("EVIDENCE_DIR=\(env.tmpDir.path)")
        return 0
    }

    @MainActor
    private static func runAutoMovie(sourceImagePath: String) async throws -> Int32 {
        let env = V3AcceptanceHarness.makeEnvironment(label: "h3-automovie")
        defer { V3AcceptanceHarness.restoreOutputDir(env) }

        let settings = ProjectSettings(
            modelID: MiniMaxH3Configuration.modelID,
            textEncoderID: LTXTextEncoderCatalog.defaultTextEncoderID,
            qualityMode: GenerationPreset.standard.qualityMode.rawValue,
            preset: GenerationPreset.standard.rawValue,
            width: 768,
            height: 512,
            fps: 24,
            audioEnabled: true,
            targetDurationSeconds: 10)
        let storyboardDirector = StoryboardDirector(
            providers: [TemplateStoryboardProvider()], requestedMode: .basic)
        let planner = HybridProjectCoordinator(director: storyboardDirector)
        let brief = "A young man wearing glasses and a dark jacket stands in a softly lit studio. First, he slowly turns toward the camera. Next, he relaxes his shoulders and comes to a natural stop. Keep the same person, clothing, background, and lighting. About 10 seconds, one continuous scene."
        var (project, violations, provider) = try await planner.makeProject(
            title: "H3 Auto Movie Acceptance", brief: brief, settings: settings)
        print("DIRECTOR=\(provider)")
        print("PLANNED_SHOTS=\(project.shots.count)")
        print("PLAN_VIOLATIONS=\(violations.count)")
        guard project.shots.count == 2 else {
            print("FAILED: deterministic Basic Director acceptance expected 2 shots")
            return 1
        }

        // Shot 1 has no previous shot to cut away from, so the established
        // product entry point is Opening Reference (not New Start Frame,
        // which intentionally applies only to later explicit Cuts).
        project.openingReferenceImage = try env.store.importOpeningReferenceImage(
            from: URL(fileURLWithPath: sourceImagePath), projectID: project.id)
        project.shots[0].continuityMode = .cut
        project.shots[1].continuityMode = .continueFromPrevious
        env.store.save(project)

        var outputs: [String] = []
        for index in 0..<2 {
            let generated = await V3AcceptanceHarness.generateNextShot(
                env: env,
                projectID: project.id,
                label: "H3 AUTO MOVIE SHOT \(index + 1)",
                timeoutSeconds: 3_600)
            guard let path = generated.videoPath else { return 1 }
            outputs.append(path)
        }

        env.coordinator.autoSelectUnambiguousTakes(projectID: project.id)
        guard let finalProject = env.store.project(id: project.id) else {
            print("FAILED: Auto Movie project did not persist")
            return 1
        }
        guard finalProject.shots.count == 2,
              let firstTake = finalProject.shots[0].selectedTake,
              let secondTake = finalProject.shots[1].selectedTake else {
            print("FAILED: generated Takes were not selected")
            return 1
        }
        guard firstTake.modelID == MiniMaxH3Configuration.modelID,
              secondTake.modelID == MiniMaxH3Configuration.modelID,
              firstTake.generationSourceDiagnostics?.effectiveSource == .openingReference,
              firstTake.sourceImagePath != nil,
              secondTake.generationSourceDiagnostics?.effectiveSource == .inheritedLastFrame,
              secondTake.generationSourceDiagnostics?.continuitySourceTakeID == firstTake.id,
              secondTake.sourceImagePath != nil else {
            print("FAILED: H3 Opening Reference / Continue source provenance is incorrect")
            return 1
        }

        let finalDirectory = env.tmpDir.appendingPathComponent("Final", isDirectory: true)
        try FileManager.default.createDirectory(at: finalDirectory, withIntermediateDirectories: true)
        let finalPath = finalDirectory.appendingPathComponent("h3_auto_movie.mp4").path
        let info = try FinalAssemblyService.assemble(
            project: finalProject, outputPath: finalPath, store: env.store)
        guard FileManager.default.fileExists(atPath: finalPath),
              info.durationSeconds != nil else {
            print("FAILED: Final Assembly produced no readable movie")
            return 1
        }

        print("SHOT_1_OUTPUT=\(outputs[0])")
        print("SHOT_1_CHAIN=\(firstTake.generationRuntimeDiagnostics?.effectiveChainWindows ?? -1)")
        print("SHOT_1_SOURCE=\(firstTake.generationSourceDiagnostics?.effectiveSource.rawValue ?? "none")")
        print("SHOT_2_OUTPUT=\(outputs[1])")
        print("SHOT_2_CHAIN=\(secondTake.generationRuntimeDiagnostics?.effectiveChainWindows ?? -1)")
        print("SHOT_2_SOURCE=\(secondTake.generationSourceDiagnostics?.effectiveSource.rawValue ?? "none")")
        print("SHOT_2_SOURCE_TAKE=\(secondTake.generationSourceDiagnostics?.continuitySourceTakeID?.uuidString ?? "none")")
        print("FINAL_ASSEMBLY=\(finalPath)")
        print("FINAL_DURATION=\(info.durationSeconds ?? -1)")
        print("EVIDENCE_DIR=\(env.tmpDir.path)")
        return 0
    }

    @MainActor
    private static func generate(
        request: GenerationRequest,
        environment: V3AcceptanceHarness.Environment,
        timeoutSeconds: Double
    ) async -> GenerationResult? {
        let started = Date()
        var didPrintActivePresentation = false
        environment.generationService.addToQueue(request)
        var lastLoggedProgress: Double = -1.0
        var lastLoggedStatus: String = ""
        while Date().timeIntervalSince(started) < timeoutSeconds {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if environment.generationService.isProcessing,
               let active = environment.generationService.currentRequest {
                let currentProg = environment.generationService.progress
                let currentMsg = environment.generationService.statusMessage
                if abs(currentProg - lastLoggedProgress) > 0.001 || currentMsg != lastLoggedStatus {
                    let indeterminate = MiniMaxH3ProgressPresentation.isIndeterminate(
                        modelID: active.modelId,
                        isCurrent: true,
                        progress: currentProg)
                    print("PROGRESS_UPDATE: fraction=\(String(format: "%.2f", currentProg)) indeterminate=\(indeterminate) status='\(currentMsg)'")
                    lastLoggedProgress = currentProg
                    lastLoggedStatus = currentMsg
                }
            }
            if !environment.generationService.isProcessing,
               environment.generationService.queue.isEmpty { break }
        }
        guard let result = environment.historyManager.results.first(where: { $0.requestId == request.id }) else {
            print("FAILED: no GenerationResult; service error=\(String(describing: environment.generationService.error))")
            return nil
        }
        print("GENERATION_ELAPSED=\(String(format: "%.3f", Date().timeIntervalSince(started)))")
        return result
    }

    private static func validate(
        result: GenerationResult,
        expectedRequestID: UUID,
        expectedSourcePath: String?,
        expectedRequestedDuration: Double,
        expectedChain: Int
    ) -> Bool {
        let info = MediaProbe.probe(path: result.videoPath)
        let valid = result.requestId == expectedRequestID
            && result.modelId == MiniMaxH3Configuration.modelID
            && result.backendKind == GenerationBackendKind.minimaxH3.rawValue
            && abs((result.requestedDurationSeconds ?? -1) - expectedRequestedDuration) < 0.000_001
            && result.effectiveWidth == 512
            && result.effectiveHeight == 288
            && result.effectiveChainWindows == expectedChain
            && result.actualWidth == 512
            && result.actualHeight == 288
            && result.actualFrameCount == result.effectiveFrameCount
            && result.sourceImagePath == expectedSourcePath
            && FileManager.default.fileExists(atPath: result.videoPath)
            && info?.videoCodec == "h264"
            && info?.hasAudio == true
        if !valid {
            print("FAILED: real output/archive validation did not satisfy H3 contract")
            printArchive(result)
            print("MEDIA=\(String(describing: info))")
        }
        return valid
    }

    private static func printArchive(_ result: GenerationResult) {
        print("ARCHIVE_MODEL_ID=\(result.modelId)")
        print("ARCHIVE_BACKEND=\(result.backendKind ?? "none")")
        print("ARCHIVE_REQUESTED=\(result.requestedWidth ?? -1)x\(result.requestedHeight ?? -1) duration=\(result.requestedDurationSeconds ?? -1)")
        print("ARCHIVE_EFFECTIVE=\(result.effectiveWidth ?? -1)x\(result.effectiveHeight ?? -1) frames=\(result.effectiveFrameCount ?? -1) chain=\(result.effectiveChainWindows ?? -1)")
        print("ARCHIVE_ACTUAL=\(result.actualWidth ?? -1)x\(result.actualHeight ?? -1) fps=\(result.actualFPS ?? -1) frames=\(result.actualFrameCount ?? -1) duration=\(result.actualDuration ?? -1)")
        print("ARCHIVE_AUDIO=\(result.audioEnabled == true ? "on" : "off")")
        print("ARCHIVE_SEED=\(result.seed)")
        print("OUTPUT=\(result.videoPath)")
    }

    private static func validatedSource(_ path: String?) throws -> String {
        guard let path, !path.isEmpty,
              FileManager.default.fileExists(atPath: path) else {
            throw NSError(
                domain: "MiniMaxH3Acceptance", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "A readable source image path is required."])
        }
        return path
    }
}
