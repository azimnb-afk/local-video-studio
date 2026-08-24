import Foundation

/// Service for deterministic post-generation video cropping.
///
/// When the model generation resolution is expanded beyond the requested dimensions
/// to satisfy backend grid alignment requirements (e.g. 64-pixel VAE constraints),
/// this service applies a precise centered crop to restore the exact requested
/// dimensions while preserving frame rate, frame count, and audio synchronization.
public enum PostGenerationCropService {

    public enum CropError: Error, Equatable, LocalizedError {
        case ffmpegNotFound
        case inputVideoMissing(String)
        case cropFailed(String)

        public var errorDescription: String? {
            switch self {
            case .ffmpegNotFound:
                return "FFmpeg was not found; unable to crop video."
            case .inputVideoMissing(let path):
                return "Input video missing for cropping: \(path)"
            case .cropFailed(let msg):
                return "Video cropping failed: \(msg)"
            }
        }
    }

    /// Crops `inputPath` according to `alignment` and replaces or writes to `outputPath`.
    /// If `insets` is nil or has no crop, this is a no-op and returns the original `inputPath`.
    @discardableResult
    public static func applyCropIfNeeded(
        videoPath: String,
        alignment: ResolutionAlignmentResult,
        fileManager: FileManager = .default
    ) throws -> String {
        guard let insets = alignment.crop, insets.hasCrop else {
            return videoPath
        }

        guard let ffmpeg = FinalAssemblyService.ffmpegPath() else {
            throw CropError.ffmpegNotFound
        }

        guard fileManager.fileExists(atPath: videoPath) else {
            throw CropError.inputVideoMissing(videoPath)
        }

        let outW = alignment.finalOutput.width
        let outH = alignment.finalOutput.height
        let cropX = insets.left
        let cropY = insets.top

        let tempCropURL = URL(fileURLWithPath: videoPath)
            .deletingLastPathComponent()
            .appendingPathComponent("temp-cropped-\(UUID().uuidString).mp4")

        let cropFilter = "crop=\(outW):\(outH):\(cropX):\(cropY)"

        let arguments = [
            "-y",
            "-i", videoPath,
            "-vf", cropFilter,
            "-c:v", "libx264",
            "-crf", "18",
            "-preset", "fast",
            "-c:a", "copy",
            "-movflags", "+faststart",
            tempCropURL.path
        ]

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = arguments
        let stderr = Pipe()
        process.standardOutput = Pipe()
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            try? fileManager.removeItem(at: tempCropURL)
            throw CropError.cropFailed(error.localizedDescription)
        }

        guard process.terminationStatus == 0,
              fileManager.fileExists(atPath: tempCropURL.path),
              let size = (try? fileManager.attributesOfItem(atPath: tempCropURL.path)[.size] as? NSNumber)?.int64Value,
              size > 0 else {
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            let errMsg = String(data: errData, encoding: .utf8) ?? "Unknown ffmpeg exit \(process.terminationStatus)"
            try? fileManager.removeItem(at: tempCropURL)
            throw CropError.cropFailed(errMsg)
        }

        // Atomically replace original video
        _ = try? fileManager.removeItem(atPath: videoPath)
        try fileManager.moveItem(at: tempCropURL, to: URL(fileURLWithPath: videoPath))

        return videoPath
    }
}
