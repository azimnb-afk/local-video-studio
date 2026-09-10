import CryptoKit
import Foundation

/// Whether a given model may accept a user-selected **Ending Image**.
///
/// Deliberately a hard allow-list of one, not a capability system. The
/// behaviour has been reproduced on exactly one tuple — the MiniMax H3 Standard
/// pack (`fl2va`, 2-bit text encoder / 4-bit DiT) on mlx-serve 26.8.9 — and this
/// type exists to stop that single verified result from being generalised.
///
/// The H3 High Quality pack's `config.json` also lists `fl2va` in its tasks, but
/// declaring a task is not the same as demonstrating the behaviour, and no
/// Ending Image generation has been run against it. It is therefore treated as
/// unsupported until someone measures it. Adding a model here should mean
/// "I generated with it and looked at the frames", nothing weaker.
enum H3EndingImageCapability {

    /// The one verified model id. See `MiniMaxH3Configuration.standardModelID`.
    static let verifiedModelIDs: Set<String> = [MiniMaxH3Configuration.standardModelID]

    static func supportsEndingImage(modelID: String?) -> Bool {
        guard let modelID else { return false }
        return verifiedModelIDs.contains(modelID)
    }

    /// User-facing reason a configured Ending Image cannot be used. Returns nil
    /// when the model does support it.
    ///
    /// Japanese to match the One Shot surface, and deliberately free of internal
    /// vocabulary (`fl2va`, `last_frame_image`, conditioning rows).
    static func unsupportedReason(modelID: String?) -> String? {
        guard !supportsEndingImage(modelID: modelID) else { return nil }
        return "選択中のモデルは終了画像に対応していません。終了画像を削除するか、"
            + "対応モデルに切り替えてください。"
    }

    /// Ending Image is only meaningful as the *end* of a transition that has a
    /// defined start. End-without-start has never been verified on this runtime,
    /// so it is rejected rather than silently reinterpreted as a start frame.
    static let endWithoutStartReason =
        "終了画像を使うには開始画像も必要です。開始画像を選ぶか、終了画像を削除してください。"

    /// SHA-256 of a file's contents, used to detect an Ending Image being
    /// edited or replaced while its job waits in the queue. Nil when the file
    /// cannot be read — callers treat that as "cannot verify", never as "fine".
    static func contentHash(ofFileAt path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Why an Ending Image was refused. Distinct cases so the queue, the backend and
/// the UI can each say precisely what happened instead of failing generically.
enum H3EndingImageValidationError: Error, Equatable, LocalizedError {
    /// The selected model is not on the verified allow-list.
    case unsupportedModel(String)
    /// An Ending Image was supplied without a Starting Image.
    case endWithoutStart
    /// The file is gone or unreadable at execution time.
    case missingFile(String)
    /// The file still exists but its contents changed after submission.
    case contentChanged(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedModel(let reason):
            return reason
        case .endWithoutStart:
            return H3EndingImageCapability.endWithoutStartReason
        case .missingFile(let path):
            return "終了画像が見つかりません（\(URL(fileURLWithPath: path).lastPathComponent)）。"
                + "選び直すか、終了画像を削除してから生成してください。"
        case .contentChanged(let path):
            return "終了画像の内容が、生成をリクエストした時点から変更されています"
                + "（\(URL(fileURLWithPath: path).lastPathComponent)）。"
                + "意図しない画像で生成しないよう、生成を中止しました。選び直してください。"
        }
    }
}

/// One place that decides whether a request's Ending Image may be used.
///
/// Called at submission (to reject a bad configuration before queueing) and
/// again immediately before execution (to catch a file that changed or vanished
/// while the job waited). Both callers get the same answer for the same inputs.
enum H3EndingImageValidator {

    /// Submission-time check: model support and start/end pairing only. The file
    /// is not hashed here; `verifyAtExecution` does that against the hash the
    /// request recorded.
    static func validateAtSubmission(
        modelID: String?,
        startImagePath: String?,
        endingImagePath: String?
    ) -> H3EndingImageValidationError? {
        let ending = endingImagePath?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let ending, !ending.isEmpty else { return nil }

        if let reason = H3EndingImageCapability.unsupportedReason(modelID: modelID) {
            return .unsupportedModel(reason)
        }
        let start = startImagePath?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start, !start.isEmpty else { return .endWithoutStart }
        return nil
    }

    /// Execution-time check. Fails closed: a file that cannot be read, or whose
    /// contents no longer match the hash recorded at submission, stops the
    /// generation. It never silently drops the Ending Image and continues as a
    /// start-only generation — that would produce a different video than the
    /// user asked for, without telling them.
    static func verifyAtExecution(
        endingImagePath: String?,
        expectedContentHash: String?,
        fileManager: FileManager = .default
    ) -> H3EndingImageValidationError? {
        let ending = endingImagePath?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let ending, !ending.isEmpty else { return nil }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: ending, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              fileManager.isReadableFile(atPath: ending) else {
            return .missingFile(ending)
        }
        // A request recorded before this field existed has no hash to compare;
        // the file's existence is all that can be checked.
        guard let expectedContentHash, !expectedContentHash.isEmpty else { return nil }
        guard let actual = H3EndingImageCapability.contentHash(ofFileAt: ending) else {
            return .missingFile(ending)
        }
        return actual == expectedContentHash ? nil : .contentChanged(ending)
    }
}
