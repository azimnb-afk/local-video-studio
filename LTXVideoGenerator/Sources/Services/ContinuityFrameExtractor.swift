import Foundation

/// Extracts the final usable frame of a rendered shot so the next shot can
/// start from it (existing single-image I2V bridge).
///
/// Uses the FFmpeg binary the app already depends on for assembly — no new
/// media dependency, no AVFoundation editor, no Python. Seek offsets are
/// derived from the real container duration reported by `MediaProbe` rather
/// than a hard-coded number of seconds, because shot lengths vary.
enum ContinuityFrameExtractor {

    enum ExtractionError: Error, Equatable {
        case ffmpegNotFound
        case sourceMissing(String)
        case unreadableSource(String)
        case extractionFailed(String)

        var userMessage: String {
            switch self {
            case .ffmpegNotFound:
                return "FFmpeg was not found, so the continuity frame could not be extracted."
            case .sourceMissing(let path):
                return "The previous shot's video is missing: \(path)"
            case .unreadableSource(let path):
                return "The previous shot's video could not be read: \(path)"
            case .extractionFailed(let detail):
                return "Extracting the final frame failed: \(detail)"
            }
        }
    }

    /// Writes the last usable frame of `videoPath` to `outputPath` (PNG).
    ///
    /// Strategy, in order:
    /// 1. `-sseof` — seek relative to end of file, the most reliable way to
    ///    land on a real decodable frame near the tail.
    /// 2. absolute seek slightly before the probed duration, for containers
    ///    where end-relative seeking is unavailable.
    /// 3. decode through the file and keep the last frame, which always works
    ///    but is the slowest, so it is only a final fallback.
    /// Extracts a frame at a percentage of the clip's duration.
    ///
    /// Identity refresh needs a frame from part-way through a preparation clip,
    /// not its end: the camera move it asks for completes early, and the last
    /// frame can have rotated past the wanted setup.
    static func extractFrame(videoPath: String, atPercent percent: Int, outputPath: String) throws {
        guard let ffmpeg = FinalAssemblyService.ffmpegPath() else {
            throw ExtractionError.ffmpegNotFound
        }
        guard FileManager.default.fileExists(atPath: videoPath) else {
            throw ExtractionError.sourceMissing(videoPath)
        }
        guard let info = MediaProbe.probe(path: videoPath),
              let duration = info.durationSeconds, duration > 0 else {
            throw ExtractionError.unreadableSource(videoPath)
        }
        let clamped = max(0, min(100, percent))
        // Stay strictly inside the clip so a 100% request still lands on a real
        // frame rather than seeking past the end.
        let target = min(duration * Double(clamped) / 100.0, max(0, duration - 0.04))
        let parent = URL(fileURLWithPath: outputPath).deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(atPath: outputPath)
        try run(ffmpeg: ffmpeg, arguments: [
            "-y", "-ss", "\(format(target))", "-i", videoPath,
            "-frames:v", "1", "-q:v", "2", "-update", "1", outputPath,
        ])
        guard isUsableImage(atPath: outputPath) else {
            try? FileManager.default.removeItem(atPath: outputPath)
            throw ExtractionError.extractionFailed("no usable frame at \(clamped)%")
        }
    }

    static func extractLastFrame(videoPath: String, outputPath: String) throws {
        guard let ffmpeg = FinalAssemblyService.ffmpegPath() else {
            throw ExtractionError.ffmpegNotFound
        }
        guard FileManager.default.fileExists(atPath: videoPath) else {
            throw ExtractionError.sourceMissing(videoPath)
        }
        guard let info = MediaProbe.probe(path: videoPath),
              let duration = info.durationSeconds, duration > 0 else {
            throw ExtractionError.unreadableSource(videoPath)
        }

        let parent = URL(fileURLWithPath: outputPath).deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        // Stay inside the clip: never seek before the first frame on very
        // short shots (a 1s take must not seek to -0.2s).
        let tailOffset = min(0.2, max(duration / 4, 0.04))
        let absoluteSeek = max(0, duration - tailOffset)

        let attempts: [[String]] = [
            ["-y", "-sseof", "-\(format(tailOffset))", "-i", videoPath,
             "-frames:v", "1", "-q:v", "2", "-update", "1", outputPath],
            ["-y", "-ss", "\(format(absoluteSeek))", "-i", videoPath,
             "-frames:v", "1", "-q:v", "2", "-update", "1", outputPath],
            ["-y", "-i", videoPath,
             "-vf", "select=eq(n\\,0)+1", "-fps_mode", "passthrough",
             "-q:v", "2", "-update", "1", outputPath],
        ]

        var lastDetail = ""
        for arguments in attempts {
            try? FileManager.default.removeItem(atPath: outputPath)
            do {
                try run(ffmpeg: ffmpeg, arguments: arguments)
            } catch let error as ExtractionError {
                if case .extractionFailed(let detail) = error { lastDetail = detail }
                continue
            }
            if isUsableImage(atPath: outputPath) { return }
            lastDetail = "ffmpeg produced no usable image"
        }
        try? FileManager.default.removeItem(atPath: outputPath)
        throw ExtractionError.extractionFailed(lastDetail.isEmpty ? "unknown error" : lastDetail)
    }

    /// A zero-byte or truncated file must never be handed to the renderer as a
    /// starting image.
    static func isUsableImage(atPath path: String) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? Int64, size > 0 else {
            return false
        }
        // PNG magic; ffmpeg writes PNG for a .png output path.
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        let header = handle.readData(ofLength: 8)
        return header.starts(with: [0x89, 0x50, 0x4E, 0x47])
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    private static func run(ffmpeg: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = arguments
        let stderr = Pipe()
        process.standardOutput = Pipe()
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            throw ExtractionError.extractionFailed(error.localizedDescription)
        }
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let message = String(data: errorData, encoding: .utf8) ?? ""
            throw ExtractionError.extractionFailed(String(message.suffix(500)))
        }
    }
}
