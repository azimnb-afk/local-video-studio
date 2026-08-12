import Foundation

/// Mixes Global BGM and/or Ambience tracks into an already-assembled movie, once,
/// after `FinalAssemblyService` has produced the concatenated movie. Never
/// touches per-shot audio and never re-invokes any Shot's generation.
///
/// Design: the movie's *actual* probed duration is the source of truth for
/// the output. The audio inputs are looped indefinitely (`-stream_loop -1`) and
/// then trimmed to exactly that duration. The video stream is stream-copied
/// (`-c:v copy`), never re-encoded; only audio is touched.
enum FinalAudioMixer {
    static func mix(
        movieInputPath: String,
        movieInfo: MediaInfo,
        bgmInputPath: String?,
        ambienceInputPath: String?,
        settings: FinalAudioSettings,
        outputPath: String,
        ffmpeg: String
    ) throws {
        guard let duration = movieInfo.durationSeconds, duration > 0 else {
            throw FinalAssemblyService.AssemblyError.bgmMixFailed(
                "Assembled movie has no usable duration; cannot apply audio.")
        }
        
        var arguments = [
            "-y",
            "-i", movieInputPath
        ]
        
        var inputIndex = 1
        var filterComplex = ""
        var mixInputs = [String]()
        
        if movieInfo.hasAudio {
            mixInputs.append("[0:a]")
        }
        
        if let bgmInputPath {
            arguments.append(contentsOf: ["-stream_loop", "-1", "-i", bgmInputPath])
            let volume = max(0, min(1, settings.bgmVolume))
            let fadeIn = max(0, settings.fadeInSeconds)
            let fadeOutStart = max(0, duration - max(0, settings.fadeOutSeconds))
            let fadeOutLength = duration - fadeOutStart
            
            var chain = "[\(inputIndex):a]atrim=0:\(fmt(duration)),asetpts=PTS-STARTPTS,volume=\(fmt(volume))"
            if fadeIn > 0 { chain += ",afade=t=in:st=0:d=\(fmt(fadeIn))" }
            if fadeOutLength > 0 { chain += ",afade=t=out:st=\(fmt(fadeOutStart)):d=\(fmt(fadeOutLength))" }
            chain += "[bgmOut]"
            filterComplex += (filterComplex.isEmpty ? "" : ";") + chain
            mixInputs.append("[bgmOut]")
            inputIndex += 1
        }
        
        if let ambienceInputPath {
            arguments.append(contentsOf: ["-stream_loop", "-1", "-i", ambienceInputPath])
            let volume = max(0, min(1, settings.ambienceVolume))
            let fadeIn = max(0, settings.ambienceFadeInSeconds)
            let fadeOutStart = max(0, duration - max(0, settings.ambienceFadeOutSeconds))
            let fadeOutLength = duration - fadeOutStart
            
            var chain = "[\(inputIndex):a]atrim=0:\(fmt(duration)),asetpts=PTS-STARTPTS,volume=\(fmt(volume))"
            if fadeIn > 0 { chain += ",afade=t=in:st=0:d=\(fmt(fadeIn))" }
            if fadeOutLength > 0 { chain += ",afade=t=out:st=\(fmt(fadeOutStart)):d=\(fmt(fadeOutLength))" }
            chain += "[ambOut]"
            filterComplex += (filterComplex.isEmpty ? "" : ";") + chain
            mixInputs.append("[ambOut]")
            inputIndex += 1
        }
        
        if mixInputs.count > 1 {
            // `normalize=0` is essential, not cosmetic: amix normalizes by
            // default, which divides EVERY input by the number of inputs. With
            // the default on, enabling BGM silently dropped the movie's own
            // dialogue/footsteps/SFX by ~6 dB, and enabling BGM + Ambience
            // together dropped it by ~9.5 dB (measured, see the production mix
            // matrix tests). Global tracks are meant to sit *under* existing
            // Shot audio at their own configured volume, so each input keeps
            // the level it was given and the movie's audio stays at unity.
            // `alimiter` then catches the summed peaks so preserving that
            // level cannot introduce hard clipping; `level=disabled` stops it
            // from applying its own make-up gain and re-scaling the mix.
            filterComplex += (filterComplex.isEmpty ? "" : ";")
                + "\(mixInputs.joined())amix=inputs=\(mixInputs.count):duration=first:dropout_transition=0:normalize=0,"
                + "alimiter=limit=0.95:level=disabled[aout]"
            arguments.append(contentsOf: ["-filter_complex", filterComplex, "-map", "0:v", "-map", "[aout]"])
        } else if mixInputs.count == 1 {
            if filterComplex.isEmpty {
                arguments.append(contentsOf: ["-map", "0:v", "-map", "0:a"])
            } else {
                arguments.append(contentsOf: ["-filter_complex", filterComplex, "-map", "0:v", "-map", mixInputs[0]])
            }
        } else {
            arguments.append(contentsOf: ["-map", "0:v"])
        }
        
        arguments.append(contentsOf: [
            "-c:v", "copy",
            "-c:a", "aac", "-ar", "48000", "-ac", "2",
            "-t", fmt(duration),
            outputPath
        ])

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
