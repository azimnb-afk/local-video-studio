import Foundation

/// Assembles selected takes into the final film. Hard cuts (MVP).
/// The actual MP4s (ffprobe) decide the strategy:
///   all compatible → ffmpeg concat demuxer with stream copy
///   otherwise      → normalize (re-encode to project settings) → concat
final class FinalAssemblyService {

    enum AssemblyError: Error, Equatable {
        case noSelectedTakes
        case missingTakeFile(String)
        case ffmpegNotFound
        case ffmpegFailed(String)
        case probeFailed(String)
    }

    struct AssemblyPlan: Equatable {
        var inputPaths: [String]
        var strategy: Strategy
        enum Strategy: String, Equatable {
            case streamCopy      // identical codecs/dimensions/fps → concat -c copy
            case normalizeReencode
        }
    }

    static let ffmpegCandidates = [
        "/opt/homebrew/bin/ffmpeg",
        "/usr/local/bin/ffmpeg",
        "/usr/bin/ffmpeg",
    ]

    static func ffmpegPath() -> String? {
        ffmpegCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Decides the assembly strategy from real file metadata.
    static func plan(for project: FilmProject) throws -> AssemblyPlan {
        let selected = project.shots.sorted { $0.index < $1.index }.compactMap(\.selectedTake)
        guard !selected.isEmpty else { throw AssemblyError.noSelectedTakes }

        var paths: [String] = []
        var infos: [MediaInfo] = []
        for take in selected {
            guard let path = take.outputPath, FileManager.default.fileExists(atPath: path) else {
                throw AssemblyError.missingTakeFile(take.outputPath ?? "(nil)")
            }
            guard let info = MediaProbe.probe(path: path) else {
                throw AssemblyError.probeFailed(path)
            }
            paths.append(path)
            infos.append(info)
        }

        let first = infos[0]
        let compatible = infos.allSatisfy {
            $0.videoCodec == first.videoCodec
                && $0.width == first.width && $0.height == first.height
                && abs(($0.fps ?? 0) - (first.fps ?? 0)) < 0.01
                && $0.audioCodec == first.audioCodec
                && $0.sampleRate == first.sampleRate
                && $0.channels == first.channels
        }
        return AssemblyPlan(inputPaths: paths, strategy: compatible ? .streamCopy : .normalizeReencode)
    }

    /// Runs the assembly. Blocking; call from a background context.
    static func assemble(project: FilmProject, outputPath: String) throws -> MediaInfo {
        let assemblyPlan = try plan(for: project)
        guard let ffmpeg = ffmpegPath() else { throw AssemblyError.ffmpegNotFound }

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ltx-assembly-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        var concatInputs = assemblyPlan.inputPaths

        if assemblyPlan.strategy == .normalizeReencode {
            // Normalize every input to the project's canonical format first.
            let width = project.settings.width
            let height = project.settings.height
            let fps = project.settings.fps
            concatInputs = []
            for (index, input) in assemblyPlan.inputPaths.enumerated() {
                let normalized = workDir.appendingPathComponent("norm_\(index).mp4").path
                try runFFmpeg([
                    "-y", "-i", input,
                    "-vf", "scale=\(width):\(height):force_original_aspect_ratio=decrease,pad=\(width):\(height):(ow-iw)/2:(oh-ih)/2,fps=\(fps)",
                    "-c:v", "libx264", "-preset", "medium", "-crf", "18", "-pix_fmt", "yuv420p",
                    "-c:a", "aac", "-ar", "48000", "-ac", "2",
                    normalized,
                ], ffmpeg: ffmpeg)
                concatInputs.append(normalized)
            }
        }

        // concat demuxer list (paths escaped for ffmpeg's list format).
        let listFile = workDir.appendingPathComponent("concat.txt")
        let listContent = concatInputs
            .map { "file '\($0.replacingOccurrences(of: "'", with: "'\\''"))'" }
            .joined(separator: "\n")
        try listContent.write(to: listFile, atomically: true, encoding: .utf8)

        try runFFmpeg([
            "-y", "-f", "concat", "-safe", "0", "-i", listFile.path,
            "-c", "copy",
            outputPath,
        ], ffmpeg: ffmpeg)

        guard let info = MediaProbe.probe(path: outputPath) else {
            throw AssemblyError.probeFailed(outputPath)
        }
        return info
    }

    private static func runFFmpeg(_ arguments: [String], ffmpeg: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = arguments
        let stderr = Pipe()
        process.standardOutput = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8) ?? ""
            throw AssemblyError.ffmpegFailed(String(message.suffix(2000)))
        }
    }
}
