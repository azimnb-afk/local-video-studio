import Foundation

public struct FFmpegDetector {
    public static let searchPaths = [
        "/opt/homebrew/bin/ffmpeg",
        "/usr/local/bin/ffmpeg",
        "/usr/bin/ffmpeg"
    ]
    
    public static func findFFmpeg() -> String? {
        return searchPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }
    
    public static var isAvailable: Bool {
        return findFFmpeg() != nil
    }
    
    public static func checkVersion(path: String) async -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["-version"]
        
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        
        do {
            try process.run()
            process.waitUntilExit()
            let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                // Return first line, e.g., "ffmpeg version 7.0.1 Copyright (c) 2000-2024 the FFmpeg developers"
                return output.components(separatedBy: .newlines).first
            }
        } catch {
            return nil
        }
        return nil
    }
}

public class DefaultFFmpegChecker: FFmpegChecking {
    public init() {}
    public func check() async -> SetupStatus {
        guard let path = FFmpegDetector.findFFmpeg() else {
            return .missing("FFmpeg is not installed. Install via Homebrew: brew install ffmpeg")
        }
        if let versionLine = await FFmpegDetector.checkVersion(path: path) {
            return .ready // optionally could include version string in ready state if enum supported it, but we can just return ready
        } else {
            return .invalid("Found FFmpeg at \(path) but it could not be executed.")
        }
    }
}
