import Foundation

/// Mixes a single Global BGM track into an already-assembled movie, once,
/// after `FinalAssemblyService` has produced the concatenated movie. Never
/// touches per-shot audio and never re-invokes any Shot's generation.
///
/// Design: the movie's *actual* probed duration is the source of truth for
/// the output. The BGM input is looped indefinitely (`-stream_loop -1`) and
/// then trimmed to exactly that duration — which naturally covers both "BGM
/// shorter than the movie" (loops to fill) and "BGM longer than the movie"
/// (trimmed down) with the same filter graph, and an explicit `-t` on the
/// output is a second safety net. The video stream is stream-copied
/// (`-c:v copy`), never re-encoded; only audio is touched.
enum FinalAudioMixer {
    static func mix(
        movieInputPath: String,
        movieInfo: MediaInfo,
        bgmInputPath: String,
        settings: FinalAudioSettings,
        outputPath: String,
        ffmpeg: String
    ) throws {
        guard let duration = movieInfo.durationSeconds, duration > 0 else {
            throw FinalAssemblyService.AssemblyError.bgmMixFailed(
                "Assembled movie has no usable duration; cannot apply BGM.")
        }

        let volume = max(0, min(1, settings.bgmVolume))
        let fadeIn = max(0, settings.fadeInSeconds)
        // Clamp so a fade-out longer than the movie can never produce a
        // negative start time.
        let fadeOutStart = max(0, duration - max(0, settings.fadeOutSeconds))
        let fadeOutLength = duration - fadeOutStart

        var bgmChain = "[1:a]atrim=0:\(fmt(duration)),asetpts=PTS-STARTPTS,volume=\(fmt(volume))"
        if fadeIn > 0 {
            bgmChain += ",afade=t=in:st=0:d=\(fmt(fadeIn))"
        }
        if fadeOutLength > 0 {
            bgmChain += ",afade=t=out:st=\(fmt(fadeOutStart)):d=\(fmt(fadeOutLength))"
        }
        bgmChain += "[bgm]"

        var filterComplex = bgmChain
        let mapArgs: [String]
        if movieInfo.hasAudio {
            // Original Shot audio (dialogue/footsteps/SFX/ambience) is
            // preserved by mixing it with BGM rather than replacing it. Same
            // amix convention AudioService.swift already uses for its own
            // voiceover+music mixing (pre-scaled volume per input, then
            // amix — no extra post-mix gain correction).
            filterComplex += ";[0:a][bgm]amix=inputs=2:duration=first:dropout_transition=0[aout]"
            mapArgs = ["-map", "0:v", "-map", "[aout]"]
        } else {
            mapArgs = ["-map", "0:v", "-map", "[bgm]"]
        }

        var arguments = [
            "-y",
            "-i", movieInputPath,
            "-stream_loop", "-1", "-i", bgmInputPath,
            "-filter_complex", filterComplex,
        ]
        arguments += mapArgs
        arguments += [
            "-c:v", "copy",
            "-c:a", "aac", "-ar", "48000", "-ac", "2",
            "-t", fmt(duration),
            outputPath,
        ]

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = arguments
        let stderr = Pipe()
        process.standardOutput = Pipe()
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            throw FinalAssemblyService.AssemblyError.bgmMixFailed(error.localizedDescription)
        }
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8) ?? ""
            throw FinalAssemblyService.AssemblyError.bgmMixFailed(String(message.suffix(2000)))
        }
    }

    private static func fmt(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}
