import Foundation

/// A refresh anchor that was produced for a specific shot.
struct GeneratedIdentityAnchor: Codable, Equatable {
    /// Project-relative path of the managed image.
    var relativePath: String
    /// Project-relative path of the anchor it was transformed from.
    var sourceAnchorRelativePath: String
    var targetShotID: UUID
    /// Take the inherited frame came from, so a retake upstream can invalidate
    /// this anchor rather than silently reusing a stale one.
    var sourceTakeID: UUID?
    var generationMethod: String
    /// Where in the preparation clip the frame was taken from.
    var selectedFramePercent: Int
    var createdAt: Date
}

/// Produces an identity-bearing starting image for a shot whose inherited frame
/// cannot supply one.
///
/// Behind a protocol because the generator is the replaceable part. The current
/// implementation runs a short LTX preparation clip; a dedicated local still
/// model could take its place without the policy, selection or persistence
/// changing.
protocol IdentityAnchorGenerator {
    /// - Returns: the chosen frame's image data plus which candidate it was, or
    ///   nil when nothing usable could be produced.
    func generateAnchor(
        fromAnchorImage imageURL: URL,
        targetShot: Shot,
        settings: ProjectSettings
    ) async -> (imageData: Data, framePercent: Int)?
}

/// Builds the anchor with the existing LTX backend.
///
/// This is a *transformation*, not a continuation: it deliberately asks the
/// model to move the subject and camera into the state the next shot needs.
/// The change-focused CONTINUE policy must not be used here — telling the model
/// to keep everything as it is would produce exactly the frame we already have
/// (D-073 showed the same mistake preserving a character sheet as a prop).
///
/// The preparation clip is never part of the finished movie.
struct LTXTemporalRefreshGenerator: IdentityAnchorGenerator {

    /// 49 frames is a valid 8n+1 count for this backend and measured at
    /// roughly half the cost of a full shot while still completing the camera
    /// move (122 s against 270 s).
    static let frameCount = 49
    /// Candidate positions. The transformation completes well before the end,
    /// so late frames are not automatically best.
    static let candidatePercents = [40, 50, 65, 80, 99]
    /// Chosen from the measured candidate sweep: by ~80% the camera has settled
    /// into a closer framing and the face is legible, without over-rotating.
    static let preferredPercent = 80

    let bridge: LTXBridge
    let workingDirectory: URL

    init(bridge: LTXBridge = .shared, workingDirectory: URL = FileManager.default.temporaryDirectory) {
        self.bridge = bridge
        self.workingDirectory = workingDirectory
    }

    /// The transformation prompt. Names no character: the anchor image is the
    /// appearance source, and re-describing it is what caused D-071.
    static func prompt(for shot: Shot) -> String {
        let scale = (shot.camera.shotScale ?? "medium-close-up")
        return """
        The same protagonist remains visually recognizable, with the same face, \
        hair, clothing and colours. The location and lighting remain continuous. \
        She turns towards the camera so that her face becomes clearly visible, \
        and the camera settles into a \(scale) eye-level framing. Create a \
        natural cinematic setup suitable as the first frame of the next shot.
        """
    }

    func generateAnchor(
        fromAnchorImage imageURL: URL,
        targetShot: Shot,
        settings: ProjectSettings
    ) async -> (imageData: Data, framePercent: Int)? {
        let clipURL = workingDirectory
            .appendingPathComponent("identity-refresh-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: clipURL) }

        var params = GenerationParameters.default
        params.width = settings.width
        params.height = settings.height
        params.fps = settings.fps
        params.numFrames = Self.frameCount
        params.numInferenceSteps = settings.resolvedInferenceSteps
        params.seed = Int.random(in: 0..<Int(Int32.max))
        // The anchor is the appearance source and must survive intact, so it is
        // pinned as the first frame exactly, like a user-chosen starting image.
        params.imageStrength = 1.0

        // Reuses the ordinary render entry point. The clip is written to a
        // temporary file and deleted below — it never enters History, the
        // Videos folder, or the finished movie.
        let request = GenerationRequest(
            prompt: Self.prompt(for: targetShot),
            sourceImagePath: imageURL.path,
            disableAudio: true,
            modelId: settings.modelID,
            textEncoderId: settings.textEncoderID,
            parameters: params,
            generationSource: "identityRefresh"
        )
        do {
            _ = try await bridge.generate(
                request: request, outputPath: clipURL.path, progressHandler: { _, _ in })
        } catch {
            return nil
        }

        guard FileManager.default.fileExists(atPath: clipURL.path) else { return nil }
        let framePath = workingDirectory
            .appendingPathComponent("identity-refresh-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: framePath) }
        do {
            try ContinuityFrameExtractor.extractFrame(
                videoPath: clipURL.path,
                atPercent: Self.preferredPercent,
                outputPath: framePath.path
            )
        } catch {
            return nil
        }
        guard ContinuityFrameExtractor.isUsableImage(atPath: framePath.path),
              let data = try? Data(contentsOf: framePath) else { return nil }
        return (data, Self.preferredPercent)
    }
}
