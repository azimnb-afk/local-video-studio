import Foundation

/// ffprobe wrapper. The actual MP4 on disk — not requested settings — is the
/// source of truth for resolution, fps, duration and codecs.
struct MediaInfo: Codable, Equatable {
    var width: Int?
    var height: Int?
    var fps: Double?
    var durationSeconds: Double?
    /// Native packet/frame count reported by ffprobe when the container makes
    /// one available. A missing value is intentionally not estimated.
    var frameCount: Int?
    var videoCodec: String?
    var audioCodec: String?
    var sampleRate: Int?
    var channels: Int?
    var bitRate: Int?

    var hasAudio: Bool { audioCodec != nil }
}

enum MediaProbe {
    /// Candidate ffprobe locations (Homebrew arm64/x86, system PATH).
    static let ffprobeCandidates = [
        "/opt/homebrew/bin/ffprobe",
        "/usr/local/bin/ffprobe",
        "/usr/bin/ffprobe",
    ]

    static func ffprobePath() -> String? {
        ffprobeCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func probe(path: String) -> MediaInfo? {
        guard let ffprobe = ffprobePath(),
              FileManager.default.fileExists(atPath: path) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffprobe)
        process.arguments = [
            "-v", "error",
            "-print_format", "json",
            "-show_streams", "-show_format",
            path,
        ]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        var info = MediaInfo()
        if let format = json["format"] as? [String: Any] {
            info.durationSeconds = (format["duration"] as? String).flatMap(Double.init)
            info.bitRate = (format["bit_rate"] as? String).flatMap(Int.init)
        }
        for stream in json["streams"] as? [[String: Any]] ?? [] {
            switch stream["codec_type"] as? String {
            case "video":
                info.width = stream["width"] as? Int
                info.height = stream["height"] as? Int
                info.videoCodec = stream["codec_name"] as? String
                if let rate = stream["r_frame_rate"] as? String {
                    let parts = rate.split(separator: "/").compactMap { Double($0) }
                    if parts.count == 2, parts[1] != 0 {
                        info.fps = parts[0] / parts[1]
                    } else if parts.count == 1 {
                        info.fps = parts[0]
                    }
                }
                if let frames = stream["nb_frames"] as? String {
                    info.frameCount = Int(frames)
                } else if let frames = stream["nb_frames"] as? Int {
                    info.frameCount = frames
                }
            case "audio":
                info.audioCodec = stream["codec_name"] as? String
                info.sampleRate = (stream["sample_rate"] as? String).flatMap(Int.init)
                info.channels = stream["channels"] as? Int
            default:
                break
            }
        }
        return info
    }
}
