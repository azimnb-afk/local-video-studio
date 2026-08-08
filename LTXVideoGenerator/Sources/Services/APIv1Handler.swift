import Foundation

/// v1 localhost API logic, separated from socket handling for testability.
/// Security model: loopback-only listener + installation token + asset-ID
/// indirection (clients NEVER pass filesystem paths) + bounded request sizes
/// + adult policy enforced here (not just in UI).
enum APIv1 {

    static let maxVariations = 20
    /// JSON request body cap (base64 image uploads included).
    static let maxRequestBytes = 48 * 1024 * 1024
    /// Decoded asset cap.
    static let maxAssetBytes = 32 * 1024 * 1024

    struct HTTPReply {
        var status: Int
        var body: [String: Any]
    }

    // MARK: Installation token

    /// Random token created on first use, stored in Application Support.
    /// Clients read it from disk (same user) and send `Authorization: Bearer <token>`.
    final class TokenStore {
        private let url: URL
        private(set) var token: String

        init(directory: URL? = nil) {
            let dir = directory ?? FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("LTXVideoGenerator", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            url = dir.appendingPathComponent("api_token")
            if let existing = try? String(contentsOf: url, encoding: .utf8),
               !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                token = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                var bytes = [UInt8](repeating: 0, count: 32)
                _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
                token = "ltx_" + bytes.map { String(format: "%02x", $0) }.joined()
                try? token.write(to: url, atomically: true, encoding: .utf8)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
        }
    }

    static func authorize(headerValue: String?, expectedToken: String) -> Bool {
        guard let headerValue else { return false }
        let token: String
        if headerValue.lowercased().hasPrefix("bearer ") {
            token = String(headerValue.dropFirst("bearer ".count)).trimmingCharacters(in: .whitespaces)
        } else {
            token = headerValue.trimmingCharacters(in: .whitespaces)
        }
        // Constant-time-ish compare.
        guard token.utf8.count == expectedToken.utf8.count else { return false }
        var diff: UInt8 = 0
        for (a, b) in zip(token.utf8, expectedToken.utf8) { diff |= a ^ b }
        return diff == 0
    }

    // MARK: Asset sandbox

    /// Assets live only inside this sandbox; IDs are server-generated UUIDs.
    final class AssetStore {
        let directory: URL

        init(directory: URL? = nil) {
            self.directory = directory ?? FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("LTXVideoGenerator", isDirectory: true)
                .appendingPathComponent("APIAssets", isDirectory: true)
            try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        }

        /// Accepts only well-formed server-issued IDs; canonicalizes and refuses
        /// anything that escapes the sandbox (traversal, symlinks, absolute paths).
        func path(forAssetID assetID: String) -> String? {
            guard let uuid = UUID(uuidString: assetID) else { return nil }
            let candidate = directory.appendingPathComponent("\(uuid.uuidString).png")
            let canonicalDir = directory.resolvingSymlinksInPath().standardizedFileURL.path
            let canonical = candidate.resolvingSymlinksInPath().standardizedFileURL.path
            guard canonical.hasPrefix(canonicalDir + "/") else { return nil }
            guard FileManager.default.fileExists(atPath: canonical) else { return nil }
            return canonical
        }

        func store(imageData: Data) throws -> String {
            let id = UUID()
            let url = directory.appendingPathComponent("\(id.uuidString).png")
            try imageData.write(to: url, options: .atomic)
            return id.uuidString
        }
    }

    // MARK: Job payload validation (pure, unit-testable)

    struct JobPayload: Equatable {
        var task: String                  // "text_to_video" | "image_to_video"
        var prompt: String
        var negativePrompt: String
        var assetID: String?
        var durationSeconds: Double?
        var quality: String               // auto/high/compact/advanced
        var audio: Bool
        var modelID: String?              // nil/"auto" → selected model
        var adultMode: Bool
        var variations: Int
        var seed: Int?
    }

    enum ValidationError: Error, Equatable {
        case missingField(String)
        case invalidValue(String)
        case variationsOutOfRange
        case unknownTask(String)
        case i2vRequiresAsset
        case invalidAssetID
        case policyRejected(String)
    }

    static func parseJobPayload(_ json: [String: Any]) throws -> JobPayload {
        guard let prompt = json["prompt"] as? String,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError.missingField("prompt")
        }
        let task = (json["task"] as? String) ?? "text_to_video"
        guard task == "text_to_video" || task == "image_to_video" else {
            throw ValidationError.unknownTask(task)
        }
        let assetID = (json["input"] as? [String: Any])?["assetID"] as? String
        if task == "image_to_video" && assetID == nil {
            throw ValidationError.i2vRequiresAsset
        }
        let variations = (json["variations"] as? Int) ?? 1
        guard (1...maxVariations).contains(variations) else {
            throw ValidationError.variationsOutOfRange
        }
        let quality = (json["quality"] as? String) ?? "auto"
        guard QualityMode(rawValue: quality) != nil else {
            throw ValidationError.invalidValue("quality")
        }
        if let duration = json["duration"] as? Double, duration <= 0 || duration > 20 {
            throw ValidationError.invalidValue("duration")
        }
        return JobPayload(
            task: task,
            prompt: prompt,
            negativePrompt: (json["negative_prompt"] as? String) ?? "",
            assetID: assetID,
            durationSeconds: json["duration"] as? Double,
            quality: quality,
            audio: (json["audio"] as? Bool) ?? true,
            modelID: json["model"] as? String,
            adultMode: (json["adultMode"] as? Bool) ?? false,
            variations: variations,
            seed: json["seed"] as? Int
        )
    }

    /// Resolves + policy-checks the model for a job. Adult policy is enforced
    /// with the app's setting: a client cannot enable adult mode via API when
    /// the app has it off.
    static func resolveModel(
        payload: JobPayload,
        registry: ModelRegistry,
        appAdultModeEnabled: Bool
    ) throws -> ModelDescriptor {
        let effectiveAdultMode = payload.adultMode && appAdultModeEnabled
        let modelID: String
        if let requested = payload.modelID, requested != "auto" {
            modelID = requested
        } else {
            modelID = LTXModelCatalog.selectedModel().id
        }
        do {
            return try registry.validateForGeneration(modelID: modelID, adultMode: effectiveAdultMode)
        } catch let error as ModelPolicyError {
            throw ValidationError.policyRejected(error.userMessage)
        }
    }

    /// Builds the (1–20) generation requests for a validated job.
    static func makeRequests(
        payload: JobPayload,
        model: ModelDescriptor,
        sourceImagePath: String?,
        textEncoderID: String
    ) -> [GenerationRequest] {
        var params = GenerationParameters.default
        if let duration = payload.durationSeconds {
            params.numFrames = PromptCompiler.frameCount(forSeconds: duration, fps: params.fps)
        }
        return (0..<payload.variations).map { index in
            var p = params
            p.seed = payload.seed.map { $0 + index } ?? Int.random(in: 0..<Int(Int32.max))
            return GenerationRequest(
                prompt: payload.prompt,
                negativePrompt: payload.negativePrompt,
                sourceImagePath: sourceImagePath,
                disableAudio: !payload.audio,
                modelId: model.id,
                textEncoderId: textEncoderID,
                parameters: p,
                qualityMode: payload.quality,
                adultMode: payload.adultMode
            )
        }
    }
}
