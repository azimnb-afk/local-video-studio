import Foundation

struct MiniMaxH3GenerationPayload: Codable, Equatable {
    var prompt: String
    var width: Int
    var height: Int
    var numFrames: Int
    var steps: Int
    var seed: Int
    var firstFrameImage: Data?
    var chainWindows: Int

    enum CodingKeys: String, CodingKey {
        case prompt, width, height, steps, seed
        case numFrames = "num_frames"
        case firstFrameImage = "first_frame_image"
        case chainWindows = "chain_windows"
    }
}

struct MiniMaxH3GenerationResponse: Codable, Equatable {
    var frames: Int
    var height: Int
    var width: Int
    var fps: Double
    var format: String
    var data: Data
    var audioSampleRate: Int?
    var audioChannels: Int?
    var audioFormat: String?
    var audioData: Data?

    enum CodingKeys: String, CodingKey {
        case frames, height, width, fps, format, data
        case audioSampleRate = "audio_sample_rate"
        case audioChannels = "audio_channels"
        case audioFormat = "audio_format"
        case audioData = "audio_data"
    }
}

struct MiniMaxH3DecodedMetadata: Equatable {
    var frames: Int
    var width: Int
    var height: Int
    var fps: Double
    var audioSampleRate: Int?
    var audioChannels: Int?
    var hasAudio: Bool
}

/// HTTP + raw media boundary for the MiniMax H3 mlx-serve model pack. It
/// never consults an LTX catalog and never falls back to another renderer.
final class MiniMaxH3Backend {
    private let runtimeManager: MiniMaxH3RuntimeManager
    private let transport: MiniMaxH3HTTPTransport
    private let fileManager: FileManager
    private let ffmpegPath: String?

    init(
        runtimeManager: MiniMaxH3RuntimeManager = .shared,
        transport: MiniMaxH3HTTPTransport = MiniMaxH3URLSessionTransport(),
        fileManager: FileManager = .default,
        ffmpegPath: String? = FFmpegDetector.findFFmpeg()
    ) {
        self.runtimeManager = runtimeManager
        self.transport = transport
        self.fileManager = fileManager
        self.ffmpegPath = ffmpegPath
    }

    func generate(
        request: GenerationRequest,
        model: ModelDescriptor,
        outputPath: String,
        progressHandler: @escaping (Double, String) -> Void
    ) async throws -> (videoPath: String, seed: Int, enhancedPrompt: String?) {
        guard model.id == MiniMaxH3Configuration.modelID,
              model.runtime.backend == GenerationBackendKind.minimaxH3.rawValue else {
            throw MiniMaxH3Error.unsupportedCapability("this resolved model/backend combination")
        }
        guard model.capabilities.textToVideo, model.capabilities.imageToVideo else {
            throw MiniMaxH3Error.unsupportedCapability("the required T2V/I2V capability")
        }
        guard let ffmpegPath else { throw MiniMaxH3Error.ffmpegUnavailable }
        try Task.checkCancellation()

        // Personal and Dev load the same multi-gigabyte quantized H3 model
        // into this Mac's shared unified memory even though they run on
        // different ports/profiles. A controlled test drove system free
        // memory to ~65MB running two H3 generations at once, and a real
        // session saw a Ready server disappear mid-request under the same
        // condition. This machine-local lease keeps only one H3 generation
        // (across all Local Video Studio processes) resource-heavy at a
        // time; it never touches Personal/Dev storage or blocks anything
        // else (LTX generation, Settings, Archive, planning, install).
        do {
            try MiniMaxH3GenerationLease.acquire()
        } catch let error as MiniMaxH3GenerationLease.LeaseError {
            throw MiniMaxH3Error.generationBusy(error.localizedDescription ?? "MiniMax H3 is busy.")
        }
        defer { MiniMaxH3GenerationLease.release() }

        let endpoint = model.runtime.endpoint ?? request.minimaxH3Endpoint
            ?? MiniMaxH3Configuration.defaultEndpoint
        let snapshot = MiniMaxH3Configuration.Snapshot(
            modelDirectory: model.localPath ?? request.minimaxH3ModelDirectory,
            runtimeExecutablePath: model.runtime.executablePath ?? request.minimaxH3RuntimeExecutablePath,
            endpoint: endpoint)
        _ = try await runtimeManager.ensureReady(snapshot: snapshot, progress: progressHandler)
        guard let baseURL = MiniMaxH3Configuration.endpointURL(endpoint) else {
            throw MiniMaxH3Error.invalidEndpoint
        }
        guard (1...MiniMaxH3DurationPolicy.maximumChainWindows)
            .contains(request.minimaxH3ChainWindows ?? 1) else {
            throw MiniMaxH3Error.unsupportedCapability("chain_windows outside 1...6")
        }

        let seed = request.parameters.seed ?? Int.random(in: 0..<Int(Int32.max))
        var preparedImage: PreparedImageConditioning?
        var sourceData: Data?
        if let rawSourcePath = request.sourceImagePath {
            let sourcePath = rawSourcePath.trimmingCharacters(in: .whitespacesAndNewlines)
            if !sourcePath.isEmpty {
            do {
                preparedImage = try ImageConditioningPreparer.shared.prepare(
                    sourceURL: URL(fileURLWithPath: sourcePath),
                    targetWidth: request.parameters.width,
                    targetHeight: request.parameters.height)
                sourceData = try Data(contentsOf: preparedImage!.preparedURL, options: .mappedIfSafe)
            } catch {
                throw MiniMaxH3Error.invalidSourceImage(error.localizedDescription)
            }
            }
        }
        if request.takeID != nil {
            TakeGenerationCoordinator().recordImagePreparation(
                request: request,
                preparedConditioning: preparedImage)
        }

        let prompt = MiniMaxH3PromptCompiler.compile(
            rendererNeutralPrompt: request.prompt,
            isImageToVideo: request.isImageToVideo)
        let payload = Self.makePayload(
            request: request,
            prompt: prompt,
            sourceImageData: sourceData,
            seed: seed)
        let body: Data
        do {
            body = try JSONEncoder().encode(payload)
        } catch {
            throw MiniMaxH3Error.malformedResponse("Could not encode the generation request.")
        }

        var urlRequest = URLRequest(
            url: baseURL.appendingPathComponent("v1/video/generations"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = body
        urlRequest.timeoutInterval = MiniMaxH3ProgressPresentation.requestTimeoutSeconds

        progressHandler(0.03, MiniMaxH3ProgressPresentation.generatingMessage(for: request))
        try Task.checkCancellation()
        var responseData: Data
        let response: HTTPURLResponse
        do {
            (responseData, response) = try await transport.data(for: urlRequest)
        } catch is CancellationError {
            throw MiniMaxH3Error.cancelled
        } catch {
            if Task.isCancelled { throw MiniMaxH3Error.cancelled }
            // Distinguish "the app-owned process actually crashed" (with its
            // real termination reason/signal/stderr) from a plain
            // network-layer failure — a Ready server does not just vanish
            // without a cause the app itself can usually observe.
            let detail = runtimeManager.ownedProcessCrashDetail()
                ?? "The network connection was lost. \(error.localizedDescription)"
            runtimeManager.recordReadiness(state: .failed, detail: detail)
            throw MiniMaxH3Error.runtimeNotRunning(detail)
        }
        guard (200..<300).contains(response.statusCode) else {
            throw MiniMaxH3Error.requestRejected(
                status: response.statusCode,
                message: Self.serverErrorSummary(responseData))
        }

        let workDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("local-video-studio-h3-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workDirectory) }
        let rgbURL = workDirectory.appendingPathComponent("frames.rgb")
        let pcmURL = workDirectory.appendingPathComponent("audio.pcm")

        let decoded = try Self.decodeAndWrite(
            responseData: responseData,
            rgbURL: rgbURL,
            pcmURL: pcmURL,
            includeAudio: !request.disableAudio)
        // The JSON/base64 response is normally much larger than the final
        // MP4. Release it before FFmpeg reads the raw files so the app does not
        // retain the response and mux working set at the same time.
        responseData = Data()
        progressHandler(0.94, "Muxing MiniMax H3 video\(request.disableAudio ? "" : " and audio")…")
        try await Self.mux(
            ffmpegPath: ffmpegPath,
            rgbURL: rgbURL,
            pcmURL: decoded.hasAudio ? pcmURL : nil,
            outputURL: URL(fileURLWithPath: outputPath),
            metadata: decoded)

        let outputURL = URL(fileURLWithPath: outputPath)
        let size = (try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard fileManager.fileExists(atPath: outputPath), size > 0,
              MediaProbe.probe(path: outputPath) != nil else {
            throw MiniMaxH3Error.outputMissing
        }
        progressHandler(1.0, "MiniMax H3 generation complete.")
        return (outputPath, seed, prompt == request.prompt ? nil : prompt)
    }

    static func decodeAndWrite(
        responseData: Data,
        rgbURL: URL,
        pcmURL: URL,
        includeAudio: Bool
    ) throws -> MiniMaxH3DecodedMetadata {
        let decoded: MiniMaxH3GenerationResponse
        do {
            decoded = try JSONDecoder().decode(MiniMaxH3GenerationResponse.self, from: responseData)
        } catch let error as DecodingError {
            if case .dataCorrupted(let context) = error,
               let field = context.codingPath.last?.stringValue,
               field == "data" || field == "audio_data" {
                throw MiniMaxH3Error.invalidBase64(field)
            }
            throw MiniMaxH3Error.malformedResponse(error.localizedDescription)
        } catch {
            throw MiniMaxH3Error.malformedResponse(error.localizedDescription)
        }
        guard decoded.frames > 0, decoded.width > 0, decoded.height > 0, decoded.fps > 0 else {
            throw MiniMaxH3Error.malformedResponse("Frame metadata is invalid.")
        }
        let format = decoded.format.lowercased()
        guard format == "rgb8" || format == "rgb24" || format == "raw_rgb8" else {
            throw MiniMaxH3Error.malformedResponse("Unsupported frame format \(decoded.format).")
        }
        let expected = decoded.frames * decoded.width * decoded.height * 3
        guard decoded.data.count == expected else {
            throw MiniMaxH3Error.invalidFramePayload(expected: expected, actual: decoded.data.count)
        }
        try decoded.data.write(to: rgbURL)

        var hasAudio = false
        if includeAudio {
            guard let rate = decoded.audioSampleRate, rate > 0,
                  let channels = decoded.audioChannels, channels > 0,
                  ["s16le", "pcm_s16le"].contains(decoded.audioFormat?.lowercased() ?? ""),
                  let audio = decoded.audioData, !audio.isEmpty else {
                throw MiniMaxH3Error.invalidAudioPayload(
                    "Expected non-empty PCM s16le audio metadata and samples.")
            }
            guard audio.count % (channels * 2) == 0 else {
                throw MiniMaxH3Error.invalidAudioPayload("PCM byte count is not sample-aligned.")
            }
            try audio.write(to: pcmURL)
            hasAudio = true
        }
        return MiniMaxH3DecodedMetadata(
            frames: decoded.frames,
            width: decoded.width,
            height: decoded.height,
            fps: decoded.fps,
            audioSampleRate: decoded.audioSampleRate,
            audioChannels: decoded.audioChannels,
            hasAudio: hasAudio)
    }

    static func makePayload(
        request: GenerationRequest,
        prompt: String? = nil,
        sourceImageData: Data?,
        seed: Int
    ) -> MiniMaxH3GenerationPayload {
        MiniMaxH3GenerationPayload(
            prompt: prompt ?? MiniMaxH3PromptCompiler.compile(
                rendererNeutralPrompt: request.prompt,
                isImageToVideo: sourceImageData != nil),
            width: request.parameters.width,
            height: request.parameters.height,
            numFrames: request.parameters.numFrames,
            steps: request.parameters.numInferenceSteps,
            seed: seed,
            firstFrameImage: sourceImageData,
            chainWindows: request.minimaxH3ChainWindows ?? 1)
    }

    static func muxArguments(
        rgbPath: String,
        pcmPath: String?,
        outputPath: String,
        metadata: MiniMaxH3DecodedMetadata
    ) -> [String] {
        var arguments = [
            "-y",
            "-f", "rawvideo",
            "-pixel_format", "rgb24",
            "-video_size", "\(metadata.width)x\(metadata.height)",
            "-framerate", Self.compactNumber(metadata.fps),
            "-i", rgbPath,
        ]
        if let pcmPath, let rate = metadata.audioSampleRate, let channels = metadata.audioChannels {
            arguments += [
                "-f", "s16le",
                "-ar", String(rate),
                "-ac", String(channels),
                "-i", pcmPath,
            ]
        }
        arguments += [
            "-c:v", "libx264",
            "-pix_fmt", "yuv420p",
            "-movflags", "+faststart",
        ]
        if pcmPath != nil {
            // H3 audio can be a few milliseconds shorter than its returned
            // RGB sequence. Padding it means `-shortest` stops on video and
            // cannot discard the authoritative final frame.
            arguments += ["-af", "apad", "-c:a", "aac", "-shortest"]
        } else {
            arguments += ["-an"]
        }
        arguments.append(outputPath)
        return arguments
    }

    private static func mux(
        ffmpegPath: String,
        rgbURL: URL,
        pcmURL: URL?,
        outputURL: URL,
        metadata: MiniMaxH3DecodedMetadata
    ) async throws {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: ffmpegPath)
                process.arguments = muxArguments(
                    rgbPath: rgbURL.path,
                    pcmPath: pcmURL?.path,
                    outputPath: outputURL.path,
                    metadata: metadata)
                let errorLog = rgbURL.deletingLastPathComponent()
                    .appendingPathComponent("ffmpeg.log")
                FileManager.default.createFile(atPath: errorLog.path, contents: nil)
                let logHandle = try? FileHandle(forWritingTo: errorLog)
                process.standardOutput = FileHandle.nullDevice
                process.standardError = logHandle ?? FileHandle.nullDevice
                process.terminationHandler = { finished in
                    try? logHandle?.close()
                    ProcessCancellationTracker.shared.unregister(finished)
                    if finished.terminationStatus == 0 {
                        continuation.resume()
                    } else {
                        let message = (try? String(contentsOf: errorLog, encoding: .utf8))
                            .map { String($0.suffix(1_000)) } ?? "Unknown FFmpeg error."
                        continuation.resume(throwing: MiniMaxH3Error.muxFailed(
                            exitCode: Int(finished.terminationStatus),
                            message: message))
                    }
                }
                do {
                    ProcessCancellationTracker.shared.register(process)
                    try process.run()
                } catch {
                    ProcessCancellationTracker.shared.unregister(process)
                    try? logHandle?.close()
                    continuation.resume(throwing: MiniMaxH3Error.muxFailed(
                        exitCode: -1, message: error.localizedDescription))
                }
            }
        }, onCancel: {
            ProcessCancellationTracker.shared.cancel()
        })
    }

    private static func compactNumber(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(value)
    }

    private static func serverErrorSummary(_ data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            return String(message.prefix(500))
        }
        if let text = String(data: data, encoding: .utf8), !text.isEmpty {
            return String(text.prefix(500))
        }
        return "No error detail returned."
    }
}
