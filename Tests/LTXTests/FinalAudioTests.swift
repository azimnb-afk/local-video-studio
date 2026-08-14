import Foundation
@testable import LTXVideoGeneratorCore

/// Generates a small synthetic sine-wave audio fixture at test runtime (never
/// committed to the repository), the same `lavfi`-based approach already used
/// to build the repository-owned video fixtures in `Tests/LTXTests/Fixtures`.
private func makeSyntheticBGM(seconds: Double, frequency: Int, ffmpeg: String) -> String? {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("ltx-bgm-fixture-\(UUID().uuidString).wav").path
    let process = Process()
    process.executableURL = URL(fileURLWithPath: ffmpeg)
    process.arguments = [
        "-y", "-f", "lavfi", "-i", "sine=frequency=\(frequency):duration=\(seconds)",
        "-ar", "44100", "-ac", "2",
        path,
    ]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return nil
    }
    return process.terminationStatus == 0 ? path : nil
}

/// Builds a small synthetic movie at test runtime (never committed). With
/// `withAudio`, its audio is a pure sine at `frequency` Hz so a later
/// band-energy measurement can tell the movie's own audio apart from the
/// Global BGM/Ambience tracks mixed on top of it.
private func makeSyntheticMovie(withAudio: Bool, frequency: Int, seconds: Double, ffmpeg: String) -> String? {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("ltx-movie-fixture-\(UUID().uuidString).mp4").path
    var args = ["-y", "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=24:duration=\(seconds)"]
    if withAudio {
        args += ["-f", "lavfi", "-i", "sine=frequency=\(frequency):duration=\(seconds)"]
    }
    args += ["-c:v", "libx264", "-pix_fmt", "yuv420p"]
    if withAudio { args += ["-c:a", "aac", "-ar", "48000", "-ac", "2", "-shortest"] }
    args += [path]

    let process = Process()
    process.executableURL = URL(fileURLWithPath: ffmpeg)
    process.arguments = args
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return nil
    }
    return process.terminationStatus == 0 ? path : nil
}

/// Mean volume (dB) of `path` after isolating a narrow band around
/// `frequency` with ffmpeg's own `bandpass` + `volumedetect`. A tone that is
/// actually present measures far higher than one that is not; AAC encoding
/// and filter skirts mean an absent tone is never exactly silent, so callers
/// compare relative levels with a wide margin rather than testing for zero.
private func bandEnergyDB(path: String, frequency: Int, ffmpeg: String) -> Double? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: ffmpeg)
    process.arguments = [
        "-i", path,
        "-af", "bandpass=f=\(frequency):width_type=h:w=40,volumedetect",
        "-f", "null", "-",
    ]
    let stderrPipe = Pipe()
    process.standardOutput = Pipe()
    process.standardError = stderrPipe
    do {
        try process.run()
    } catch {
        return nil
    }
    let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    let text = String(data: data, encoding: .utf8) ?? ""
    guard let marker = text.range(of: "mean_volume: ") else { return nil }
    let tail = text[marker.upperBound...]
    return Double(tail.prefix(while: { $0 != " " }))
}

func runFinalAudioTests(_ t: TestKit) {
    t.suite("Final Audio — persistence") {
        // A. Old project JSON without `finalAudio` at all must decode with
        // BGM and Ambience off, reproducing every project written before this feature.
        let legacyJSON = """
        {"id":"\(UUID().uuidString)","title":"Legacy"}
        """.data(using: .utf8)!
        do {
            let decoded = try JSONDecoder().decode(FilmProject.self, from: legacyJSON)
            t.checkEqual(decoded.finalAudio.bgmEnabled, false, "legacy project without finalAudio decodes with BGM off")
            t.check(decoded.finalAudio.bgmAsset == nil, "legacy project has no BGM asset")
            t.checkEqual(decoded.finalAudio.ambienceEnabled, false, "legacy project without finalAudio decodes with Ambience off")
            t.check(decoded.finalAudio.ambienceAsset == nil, "legacy project has no Ambience asset")
            t.checkEqual(decoded.finalAudio.isActive, false, "legacy project's finalAudio is not active")
        } catch {
            t.check(false, "legacy project without finalAudio failed to decode: \(error)")
        }

        // B. BGM-era project JSON without Ambience fields must decode with Ambience off.
        let bgmEraJSON = """
        {"id":"\(UUID().uuidString)","title":"BGM-era", "finalAudio": {"bgmEnabled": true, "bgmVolume": 0.5}}
        """.data(using: .utf8)!
        do {
            let decoded = try JSONDecoder().decode(FilmProject.self, from: bgmEraJSON)
            t.checkEqual(decoded.finalAudio.bgmEnabled, true, "BGM-era project decodes BGM enabled correctly")
            t.checkEqual(decoded.finalAudio.ambienceEnabled, false, "BGM-era project defaults Ambience to off")
        } catch {
            t.check(false, "BGM-era project without Ambience failed to decode: \(error)")
        }

        // A fresh project also defaults to BGM off and Ambience off.
        let fresh = FilmProject(title: "Fresh")
        t.checkEqual(fresh.finalAudio.bgmEnabled, false, "new project defaults to BGM off")
        t.checkEqual(fresh.finalAudio.ambienceEnabled, false, "new project defaults to Ambience off")

        // Settings round-trip through Codable.
        var withAudio = FilmProject(title: "WithAudio")
        withAudio.finalAudio.bgmEnabled = true
        withAudio.finalAudio.bgmAsset = FinalAudioAsset(
            projectRelativePath: "Assets/FinalAudio/bgm-test.mp3",
            originalFilename: "forest_theme.mp3",
            mimeType: "audio/mpeg",
            fileSizeBytes: 12345
        )
        withAudio.finalAudio.bgmVolume = 0.4
        withAudio.finalAudio.fadeInSeconds = 2
        withAudio.finalAudio.fadeOutSeconds = 3
        withAudio.finalAudio.ambienceEnabled = true
        withAudio.finalAudio.ambienceAsset = FinalAudioAsset(
            projectRelativePath: "Assets/FinalAudio/amb-test.wav",
            originalFilename: "room_tone.wav",
            mimeType: "audio/wav",
            fileSizeBytes: 6789
        )
        withAudio.finalAudio.ambienceVolume = 0.2
        withAudio.finalAudio.ambienceFadeInSeconds = 1
        withAudio.finalAudio.ambienceFadeOutSeconds = 1
        do {
            let data = try JSONEncoder().encode(withAudio)
            let decoded = try JSONDecoder().decode(FilmProject.self, from: data)
            t.checkEqual(decoded.finalAudio, withAudio.finalAudio, "FinalAudioSettings round-trips through Codable")
            t.checkEqual(decoded.finalAudio.bgmAsset?.originalFilename, "forest_theme.mp3", "imported BGM reference persists")
            t.checkEqual(decoded.finalAudio.ambienceAsset?.originalFilename, "room_tone.wav", "imported Ambience reference persists")
        } catch {
            t.check(false, "round-trip failed: \(error)")
        }
    }

    t.suite("Final Audio — asset import") {
        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ltx-finalaudio-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpRoot) }
        let store = FilmProjectStore(projectsDirectory: tmpRoot)
        let projectID = UUID()

        guard let ffmpeg = FinalAssemblyService.ffmpegPath(),
              let sourcePath = makeSyntheticBGM(seconds: 0.5, frequency: 440, ffmpeg: ffmpeg) else {
            t.check(true, "ffmpeg unavailable — asset import integration skipped")
            return
        }
        defer { try? FileManager.default.removeItem(atPath: sourcePath) }

        do {
            let asset = try store.importFinalAudioAsset(from: URL(fileURLWithPath: sourcePath), projectID: projectID)
            t.check(asset.projectRelativePath.hasPrefix("Assets/FinalAudio/"), "imported asset lives under the project's FinalAudio directory")
            let resolved = store.managedProjectAssetURL(projectID: projectID, relativePath: asset.projectRelativePath)
            t.check(resolved != nil && FileManager.default.fileExists(atPath: resolved!.path), "imported file actually exists at its managed path")

            let ambAsset = try store.importFinalAmbienceAsset(from: URL(fileURLWithPath: sourcePath), projectID: projectID)
            t.check(ambAsset.projectRelativePath.hasPrefix("Assets/FinalAudio/"), "imported ambience asset lives under FinalAudio")
            t.check(ambAsset.projectRelativePath.contains("ambience-"), "imported ambience uses correct prefix")
            let ambResolved = store.managedProjectAssetURL(projectID: projectID, relativePath: ambAsset.projectRelativePath)
            t.check(ambResolved != nil && FileManager.default.fileExists(atPath: ambResolved!.path), "imported ambience actually exists")

            // Unsupported format is rejected before touching the filesystem.
            let badSource = FileManager.default.temporaryDirectory.appendingPathComponent("not-audio-\(UUID().uuidString).txt")
            try? "not audio".write(to: badSource, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: badSource) }
            do {
                _ = try store.importFinalAudioAsset(from: badSource, projectID: projectID)
                t.check(false, "unsupported format should have thrown")
            } catch FilmProjectStore.StoreError.unsupportedFinalBGMFormat {
                t.check(true, "unsupported format correctly rejected")
            } catch {
                t.check(false, "unexpected error for unsupported format: \(error)")
            }
        } catch {
            t.check(false, "import threw \(error)")
        }
    }

    t.suite("Final Audio — mix service (real ffmpeg, synthetic fixtures, no LTX)") {
        let a = TestFixtures.videoWithAudioA   // h264+aac, ~1s
        let b = TestFixtures.videoWithAudioB   // h264+aac, ~1s
        let videoOnly = TestFixtures.videoOnly // h264, no audio, ~1s
        guard let ffmpeg = FinalAssemblyService.ffmpegPath(),
              FileManager.default.fileExists(atPath: a),
              FileManager.default.fileExists(atPath: videoOnly) else {
            t.check(true, "ffmpeg or baseline media unavailable — mix integration skipped")
            return
        }

        func project(withPaths paths: [String], bgm: FinalAudioSettings) -> FilmProject {
            var project = FilmProject(title: "BGM")
            for (i, path) in paths.enumerated() {
                var shot = Shot(index: i, title: "S\(i)", summary: "x")
                var take = Take(shotID: shot.id, modelID: "m", seed: i, promptSnapshot: "p",
                                settingsSnapshot: .default, requestedWidth: 512, requestedHeight: 320,
                                fps: 24, requestedDuration: 1, status: .completed)
                take.outputPath = path
                shot.takes = [take]
                shot.selectedTakeID = take.id
                project.shots.append(shot)
            }
            project.settings.width = 512
            project.settings.height = 320
            project.finalAudio = bgm
            return project
        }

        func settings(assetPath: String, volume: Double = 0.3, fadeIn: Double = 0, fadeOut: Double = 0) -> FinalAudioSettings {
            var s = FinalAudioSettings()
            s.bgmEnabled = true
            s.bgmAsset = FinalAudioAsset(projectRelativePath: assetPath, originalFilename: "test.wav")
            s.bgmVolume = volume
            s.fadeInSeconds = fadeIn
            s.fadeOutSeconds = fadeOut
            return s
        }

        // A store whose managed-asset resolution we bypass: FinalAssemblyService
        // takes a `store` for path resolution, so point it at a tmp root that
        // actually contains the synthetic BGM at the expected relative path.
        let tmpStoreRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ltx-mix-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpStoreRoot) }
        let store = FilmProjectStore(projectsDirectory: tmpStoreRoot)

        func placeBGM(seconds: Double, frequency: Int, projectID: UUID) -> String? {
            guard let src = makeSyntheticBGM(seconds: seconds, frequency: frequency, ffmpeg: ffmpeg) else { return nil }
            defer { try? FileManager.default.removeItem(atPath: src) }
            let dir = store.finalAudioDirectory(projectID: projectID)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent("bgm.wav")
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(at: URL(fileURLWithPath: src), to: dest)
            return FileManager.default.fileExists(atPath: dest.path) ? "Assets/FinalAudio/bgm.wav" : nil
        }

        // Test 1: movie WITH audio + a short BGM (loops/extends to fill).
        do {
            let proj = project(withPaths: [a, b], bgm: FinalAudioSettings())
            guard let relPath = placeBGM(seconds: 0.3, frequency: 440, projectID: proj.id) else {
                t.check(false, "could not stage short synthetic BGM"); return
            }
            var withBGM = proj
            withBGM.finalAudio = settings(assetPath: relPath, volume: 0.3, fadeIn: 0.2, fadeOut: 0.2)

            let out = FileManager.default.temporaryDirectory
                .appendingPathComponent("ltx-bgm-out-\(UUID().uuidString).mp4").path
            defer { try? FileManager.default.removeItem(atPath: out) }
            do {
                let info = try FinalAssemblyService.assemble(project: withBGM, outputPath: out, store: store)
                t.check(FileManager.default.fileExists(atPath: out), "output MP4 exists")
                t.check(info.width == 512 && info.height == 320, "video stream preserved (dimensions)")
                t.check(info.hasAudio, "output has an audio stream")
                // Movie's own two ~1s takes concatenate to ~2s; BGM (0.3s) is
                // shorter and must loop/extend to match, not shrink the movie.
                t.check((info.durationSeconds ?? 0) > 1.7, "short BGM loops/extends — output duration follows the movie, not the BGM")
            } catch {
                t.check(false, "assemble with short BGM + movie audio threw \(error)")
            }
        }

        // Test 2: movie WITHOUT audio + a long BGM (trimmed down).
        do {
            var proj = project(withPaths: [videoOnly], bgm: FinalAudioSettings())
            guard let relPath = placeBGM(seconds: 5.0, frequency: 220, projectID: proj.id) else {
                t.check(false, "could not stage long synthetic BGM"); return
            }
            proj.finalAudio = settings(assetPath: relPath, volume: 0.5)

            let out = FileManager.default.temporaryDirectory
                .appendingPathComponent("ltx-bgm-out-\(UUID().uuidString).mp4").path
            defer { try? FileManager.default.removeItem(atPath: out) }
            do {
                let info = try FinalAssemblyService.assemble(project: proj, outputPath: out, store: store)
                t.check(info.hasAudio, "audio-less movie gains a BGM-only audio track")
                let duration = info.durationSeconds ?? 0
                // Single ~1s take; long BGM (5s) must be trimmed down to it.
                t.check(duration > 0.5 && duration < 2.0, "long BGM is trimmed — output duration ≈ movie duration (\(duration)s), not the BGM's")
            } catch {
                t.check(false, "assemble with long BGM + silent movie threw \(error)")
            }
        }

        // Test 3: BGM disabled — behaves exactly like assembly always has.
        do {
            let proj = project(withPaths: [a, b], bgm: FinalAudioSettings())
            t.checkEqual(proj.finalAudio.isActive, false, "default settings are inactive")
            let out = FileManager.default.temporaryDirectory
                .appendingPathComponent("ltx-nobgm-out-\(UUID().uuidString).mp4").path
            defer { try? FileManager.default.removeItem(atPath: out) }
            do {
                let info = try FinalAssemblyService.assemble(project: proj, outputPath: out, store: store)
                t.check(info.hasAudio, "BGM off: existing Shot audio still present, unchanged behavior")
                t.check((info.durationSeconds ?? 0) > 1.8, "BGM off: duration matches plain concat as before this feature")
            } catch {
                t.check(false, "BGM-off assembly threw \(error)")
            }
        }

        // Test 4: missing BGM asset fails safely and never disturbs an
        // existing Final Movie already at the destination.
        do {
            var proj = project(withPaths: [a, b], bgm: FinalAudioSettings())
            proj.finalAudio = settings(assetPath: "Assets/FinalAudio/does-not-exist.wav")

            let out = FileManager.default.temporaryDirectory
                .appendingPathComponent("ltx-bgm-missing-\(UUID().uuidString).mp4").path
            defer { try? FileManager.default.removeItem(atPath: out) }
            // Pre-seed an "existing Final Movie" at the destination.
            try? "not a real movie, just a sentinel".write(toFile: out, atomically: true, encoding: .utf8)
            let sentinelContents = try? String(contentsOfFile: out, encoding: .utf8)

            do {
                _ = try FinalAssemblyService.assemble(project: proj, outputPath: out, store: store)
                t.check(false, "missing BGM asset should have thrown")
            } catch FinalAssemblyService.AssemblyError.bgmFileMissing {
                t.check(true, "missing BGM asset correctly reported")
                let after = try? String(contentsOfFile: out, encoding: .utf8)
                t.checkEqual(after, sentinelContents, "existing Final Movie at the destination was never touched")
            } catch {
                t.check(false, "unexpected error for missing BGM: \(error)")
            }
        }
    }

    t.suite("Final Assembly — atomic replace") {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ltx-replace-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // 1. No existing output + successful replacement -> new output exists
        let dest1 = tmp.appendingPathComponent("dest1.txt").path
        let src1 = tmp.appendingPathComponent("src1.txt").path
        try? "new1".write(toFile: src1, atomically: true, encoding: .utf8)
        do {
            try FinalAssemblyService.replaceFile(at: dest1, with: src1)
            let result = try? String(contentsOfFile: dest1, encoding: .utf8)
            t.checkEqual(result, "new1", "replacement of non-existent destination succeeds")
        } catch {
            t.check(false, "replacement of non-existent threw: \(error)")
        }

        // 2. Existing valid output + successful replacement -> new output replaces old
        let dest2 = tmp.appendingPathComponent("dest2.txt").path
        let src2 = tmp.appendingPathComponent("src2.txt").path
        try? "old2".write(toFile: dest2, atomically: true, encoding: .utf8)
        try? "new2".write(toFile: src2, atomically: true, encoding: .utf8)
        do {
            try FinalAssemblyService.replaceFile(at: dest2, with: src2)
            let result = try? String(contentsOfFile: dest2, encoding: .utf8)
            t.checkEqual(result, "new2", "replacement of existing destination succeeds and overwrites")
        } catch {
            t.check(false, "replacement of existing threw: \(error)")
        }

        // 3. Existing valid output + replacement failure -> old output still exists and remains unchanged
        let dest3 = tmp.appendingPathComponent("dest3.txt").path
        let src3 = tmp.appendingPathComponent("src3.txt").path
        try? "old3".write(toFile: dest3, atomically: true, encoding: .utf8)
        // intentionally do not create src3 to force a failure in replaceFile
        do {
            try FinalAssemblyService.replaceFile(at: dest3, with: src3)
            t.check(false, "expected replacement to fail due to missing source")
        } catch {
            let result = try? String(contentsOfFile: dest3, encoding: .utf8)
            t.checkEqual(result, "old3", "failed replacement preserves existing destination")
        }
    }

    // MARK: - Production-path mix matrix
    //
    // Everything below drives the REAL production chain end to end:
    //   FilmProject + FilmProjectStore-managed assets
    //     -> FinalAssemblyService.assemble(project:outputPath:store:)
    //       -> FinalAudioMixer.mix(...)   (the shipping mixer, not a copy)
    //         -> real ffmpeg subprocess
    //           -> MediaProbe (real ffprobe)
    // No filter-graph logic is reimplemented here: the test only supplies
    // inputs and measures the resulting file, so a change in the production
    // mixer's argument construction is actually able to fail these tests.
    t.suite("Final Audio — production 7-way mix matrix (real FinalAssemblyService → FinalAudioMixer → ffmpeg)") {
        guard let ffmpeg = FinalAssemblyService.ffmpegPath(), MediaProbe.ffprobePath() != nil else {
            t.check(true, "ffmpeg/ffprobe unavailable — production mix matrix skipped")
            return
        }

        // Distinct tones so each component is independently detectable in the
        // final mix: movie audio 440 Hz, Global BGM 880 Hz, Ambience 220 Hz.
        let originalHz = 440, bgmHz = 880, ambienceHz = 220
        let movieSeconds = 2.0

        guard let movieWithAudio = makeSyntheticMovie(withAudio: true, frequency: originalHz, seconds: movieSeconds, ffmpeg: ffmpeg),
              let movieSilent = makeSyntheticMovie(withAudio: false, frequency: 0, seconds: movieSeconds, ffmpeg: ffmpeg) else {
            t.check(false, "could not build synthetic movies for the production matrix")
            return
        }
        defer {
            try? FileManager.default.removeItem(atPath: movieWithAudio)
            try? FileManager.default.removeItem(atPath: movieSilent)
        }

        let storeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ltx-matrix-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storeRoot) }
        let store = FilmProjectStore(projectsDirectory: storeRoot)

        /// Imports through the real store API so the managed-asset path the
        /// mixer later resolves is produced by production code, not hand-built.
        func importAsset(seconds: Double, frequency: Int, projectID: UUID, ambience: Bool) -> FinalAudioAsset? {
            guard let src = makeSyntheticBGM(seconds: seconds, frequency: frequency, ffmpeg: ffmpeg) else { return nil }
            defer { try? FileManager.default.removeItem(atPath: src) }
            let url = URL(fileURLWithPath: src)
            return ambience
                ? try? store.importFinalAmbienceAsset(from: url, projectID: projectID)
                : try? store.importFinalAudioAsset(from: url, projectID: projectID)
        }

        struct Scenario {
            let name: String
            let originalAudio: Bool
            let bgm: Bool
            let ambience: Bool
        }
        let scenarios = [
            Scenario(name: "1 orig=Y bgm=N amb=N", originalAudio: true,  bgm: false, ambience: false),
            Scenario(name: "2 orig=Y bgm=Y amb=N", originalAudio: true,  bgm: true,  ambience: false),
            Scenario(name: "3 orig=Y bgm=N amb=Y", originalAudio: true,  bgm: false, ambience: true),
            Scenario(name: "4 orig=Y bgm=Y amb=Y", originalAudio: true,  bgm: true,  ambience: true),
            Scenario(name: "5 orig=N bgm=Y amb=N", originalAudio: false, bgm: true,  ambience: false),
            Scenario(name: "6 orig=N bgm=N amb=Y", originalAudio: false, bgm: false, ambience: true),
            Scenario(name: "7 orig=N bgm=Y amb=Y", originalAudio: false, bgm: true,  ambience: true),
        ]

        for scenario in scenarios {
            var project = FilmProject(title: scenario.name)
            project.settings.width = 320
            project.settings.height = 240
            var shot = Shot(index: 0, title: "S0", summary: "x")
            var take = Take(shotID: shot.id, modelID: "m", seed: 0, promptSnapshot: "p",
                            settingsSnapshot: .default, requestedWidth: 320, requestedHeight: 240,
                            fps: 24, requestedDuration: movieSeconds, status: .completed)
            take.outputPath = scenario.originalAudio ? movieWithAudio : movieSilent
            shot.takes = [take]
            shot.selectedTakeID = take.id
            project.shots = [shot]

            if scenario.bgm {
                // 1s source: shorter than the 2s movie, so it must loop.
                guard let asset = importAsset(seconds: 1.0, frequency: bgmHz, projectID: project.id, ambience: false) else {
                    t.check(false, "\(scenario.name): could not import BGM asset"); continue
                }
                project.finalAudio.bgmEnabled = true
                project.finalAudio.bgmAsset = asset
                project.finalAudio.bgmVolume = 0.6
            }
            if scenario.ambience {
                // 3s source: longer than the 2s movie, so it must be trimmed.
                guard let asset = importAsset(seconds: 3.0, frequency: ambienceHz, projectID: project.id, ambience: true) else {
                    t.check(false, "\(scenario.name): could not import Ambience asset"); continue
                }
                project.finalAudio.ambienceEnabled = true
                project.finalAudio.ambienceAsset = asset
                project.finalAudio.ambienceVolume = 0.6
            }

            // Unique output per scenario so a stale file can never mask a failure.
            let out = FileManager.default.temporaryDirectory
                .appendingPathComponent("ltx-matrix-\(UUID().uuidString).mp4").path
            defer { try? FileManager.default.removeItem(atPath: out) }

            do {
                let info = try FinalAssemblyService.assemble(project: project, outputPath: out, store: store)
                t.check(FileManager.default.fileExists(atPath: out), "\(scenario.name): output file written")
                t.check(info.videoCodec != nil, "\(scenario.name): video stream present")

                let expectAudio = scenario.originalAudio || scenario.bgm || scenario.ambience
                t.checkEqual(info.hasAudio, expectAudio, "\(scenario.name): audio stream presence matches expectation")

                let duration = info.durationSeconds ?? 0
                t.check(abs(duration - movieSeconds) < 0.35,
                        "\(scenario.name): output duration \(String(format: "%.2f", duration))s follows the movie (\(movieSeconds)s), not the BGM/Ambience source lengths")

                // Objective component proof: each tone that should be in the
                // mix must measure clearly above every tone that should not.
                guard expectAudio,
                      let e440 = bandEnergyDB(path: out, frequency: originalHz, ffmpeg: ffmpeg),
                      let e880 = bandEnergyDB(path: out, frequency: bgmHz, ffmpeg: ffmpeg),
                      let e220 = bandEnergyDB(path: out, frequency: ambienceHz, ffmpeg: ffmpeg) else { continue }

                let present = [
                    (scenario.originalAudio, e440, "original \(originalHz)Hz"),
                    (scenario.bgm, e880, "BGM \(bgmHz)Hz"),
                    (scenario.ambience, e220, "ambience \(ambienceHz)Hz"),
                ]
                let onLevels = present.filter { $0.0 }
                let offLevels = present.filter { !$0.0 }
                let quietestOn = onLevels.map(\.1).min() ?? 0
                let loudestOff = offLevels.map(\.1).max()

                // 12 dB margin: measured separation in practice is ~20-30 dB,
                // so this discriminates reliably without being flaky about
                // AAC artifacts or bandpass skirts.
                if let loudestOff {
                    t.check(quietestOn > loudestOff + 12,
                            "\(scenario.name): enabled components (min \(String(format: "%.1f", quietestOn))dB) stand clearly above disabled ones (max \(String(format: "%.1f", loudestOff))dB)")
                } else {
                    t.check(true, "\(scenario.name): all three components enabled, nothing to compare against")
                }
                // Every enabled component must be individually audible, not
                // just loud in aggregate.
                for (_, level, label) in onLevels {
                    t.check(level > -45,
                            "\(scenario.name): \(label) is present in the mix (\(String(format: "%.1f", level))dB)")
                }
            } catch {
                t.check(false, "\(scenario.name): production assemble threw \(error)")
            }
        }
    }

    t.suite("Final Audio — production edge cases") {
        guard let ffmpeg = FinalAssemblyService.ffmpegPath(), MediaProbe.ffprobePath() != nil else {
            t.check(true, "ffmpeg/ffprobe unavailable — production edge cases skipped")
            return
        }
        let storeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ltx-edge-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storeRoot) }
        let store = FilmProjectStore(projectsDirectory: storeRoot)

        guard let movie = makeSyntheticMovie(withAudio: true, frequency: 440, seconds: 1.0, ffmpeg: ffmpeg) else {
            t.check(false, "could not build synthetic movie for edge cases"); return
        }
        defer { try? FileManager.default.removeItem(atPath: movie) }

        func baseProject(title: String) -> FilmProject {
            var project = FilmProject(title: title)
            project.settings.width = 320
            project.settings.height = 240
            var shot = Shot(index: 0, title: "S0", summary: "x")
            var take = Take(shotID: shot.id, modelID: "m", seed: 0, promptSnapshot: "p",
                            settingsSnapshot: .default, requestedWidth: 320, requestedHeight: 240,
                            fps: 24, requestedDuration: 1, status: .completed)
            take.outputPath = movie
            shot.takes = [take]
            shot.selectedTakeID = take.id
            project.shots = [shot]
            return project
        }

        func importBGM(seconds: Double, projectID: UUID) -> FinalAudioAsset? {
            guard let src = makeSyntheticBGM(seconds: seconds, frequency: 880, ffmpeg: ffmpeg) else { return nil }
            defer { try? FileManager.default.removeItem(atPath: src) }
            return try? store.importFinalAudioAsset(from: URL(fileURLWithPath: src), projectID: projectID)
        }

        // Fades far longer than the movie must not produce an invalid filter
        // graph or an ffmpeg failure — the movie is 1s and the fades are 5s.
        do {
            var project = baseProject(title: "LongFades")
            guard let asset = importBGM(seconds: 2.0, projectID: project.id) else {
                t.check(false, "could not import BGM for fade edge case"); return
            }
            project.finalAudio.bgmEnabled = true
            project.finalAudio.bgmAsset = asset
            project.finalAudio.fadeInSeconds = 5
            project.finalAudio.fadeOutSeconds = 5
            let out = FileManager.default.temporaryDirectory
                .appendingPathComponent("ltx-longfade-\(UUID().uuidString).mp4").path
            defer { try? FileManager.default.removeItem(atPath: out) }
            do {
                let info = try FinalAssemblyService.assemble(project: project, outputPath: out, store: store)
                t.check(info.hasAudio, "fade longer than the movie still produces a valid audio stream")
                t.check(abs((info.durationSeconds ?? 0) - 1.0) < 0.35, "fade longer than the movie does not distort output duration")
            } catch {
                t.check(false, "fade-longer-than-movie threw \(error)")
            }
        }

        // A corrupt/unplayable BGM file must fail as a mix error and leave an
        // existing Final Movie byte-identical.
        do {
            var project = baseProject(title: "CorruptBGM")
            let dir = store.finalAudioDirectory(projectID: project.id)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let corrupt = dir.appendingPathComponent("bgm-corrupt.wav")
            try? Data("this is not audio data".utf8).write(to: corrupt)
            project.finalAudio.bgmEnabled = true
            project.finalAudio.bgmAsset = FinalAudioAsset(
                projectRelativePath: "Assets/FinalAudio/bgm-corrupt.wav", originalFilename: "bgm-corrupt.wav")

            let out = FileManager.default.temporaryDirectory
                .appendingPathComponent("ltx-corrupt-\(UUID().uuidString).mp4").path
            defer { try? FileManager.default.removeItem(atPath: out) }
            let sentinel = "EXISTING FINAL MOVIE — MUST SURVIVE"
            try? sentinel.write(toFile: out, atomically: true, encoding: .utf8)

            do {
                _ = try FinalAssemblyService.assemble(project: project, outputPath: out, store: store)
                t.check(false, "corrupt BGM should have failed the mix")
            } catch {
                let after = try? String(contentsOfFile: out, encoding: .utf8)
                t.checkEqual(after, sentinel, "a failed mix leaves the existing Final Movie byte-identical")
            }
        }

        // REGRESSION (measured defect, fixed): ffmpeg's amix normalizes by
        // default, dividing every input by the number of inputs. That silently
        // attenuated the movie's own dialogue/footsteps/SFX by ~6 dB when BGM
        // was enabled and ~9.5 dB with BGM + Ambience — the user's primary
        // audio getting quieter simply because a global track was switched on.
        // The mixer now passes `normalize=0` (+ a limiter for peak safety), so
        // Shot audio must stay at essentially the same level it has with no
        // Global Audio at all.
        do {
            guard let movie2s = makeSyntheticMovie(withAudio: true, frequency: 440, seconds: 2.0, ffmpeg: ffmpeg) else {
                t.check(false, "could not build movie for preservation test"); return
            }
            defer { try? FileManager.default.removeItem(atPath: movie2s) }

            func assembleAndMeasureOriginal(bgm: Bool, ambience: Bool) -> Double? {
                var project = FilmProject(title: "Preserve")
                project.settings.width = 320
                project.settings.height = 240
                var shot = Shot(index: 0, title: "S0", summary: "x")
                var take = Take(shotID: shot.id, modelID: "m", seed: 0, promptSnapshot: "p",
                                settingsSnapshot: .default, requestedWidth: 320, requestedHeight: 240,
                                fps: 24, requestedDuration: 2, status: .completed)
                take.outputPath = movie2s
                shot.takes = [take]
                shot.selectedTakeID = take.id
                project.shots = [shot]

                if bgm, let src = makeSyntheticBGM(seconds: 2.0, frequency: 880, ffmpeg: ffmpeg) {
                    defer { try? FileManager.default.removeItem(atPath: src) }
                    if let asset = try? store.importFinalAudioAsset(from: URL(fileURLWithPath: src), projectID: project.id) {
                        project.finalAudio.bgmEnabled = true
                        project.finalAudio.bgmAsset = asset
                        project.finalAudio.bgmVolume = 0.25   // shipping default
                    }
                }
                if ambience, let src = makeSyntheticBGM(seconds: 2.0, frequency: 220, ffmpeg: ffmpeg) {
                    defer { try? FileManager.default.removeItem(atPath: src) }
                    if let asset = try? store.importFinalAmbienceAsset(from: URL(fileURLWithPath: src), projectID: project.id) {
                        project.finalAudio.ambienceEnabled = true
                        project.finalAudio.ambienceAsset = asset
                        project.finalAudio.ambienceVolume = 0.20  // shipping default
                    }
                }

                let out = FileManager.default.temporaryDirectory
                    .appendingPathComponent("ltx-preserve-\(UUID().uuidString).mp4").path
                defer { try? FileManager.default.removeItem(atPath: out) }
                guard (try? FinalAssemblyService.assemble(project: project, outputPath: out, store: store)) != nil else { return nil }
                return bandEnergyDB(path: out, frequency: 440, ffmpeg: ffmpeg)
            }

            guard let baseline = assembleAndMeasureOriginal(bgm: false, ambience: false),
                  let withBGM = assembleAndMeasureOriginal(bgm: true, ambience: false),
                  let withBoth = assembleAndMeasureOriginal(bgm: true, ambience: true) else {
                t.check(false, "could not measure Shot-audio preservation levels")
                return
            }

            t.check(abs(withBGM - baseline) < 2.0,
                    "Shot audio keeps its level when BGM is enabled (baseline \(String(format: "%.1f", baseline))dB → \(String(format: "%.1f", withBGM))dB)")
            t.check(abs(withBoth - baseline) < 2.0,
                    "Shot audio keeps its level when BGM + Ambience are both enabled (baseline \(String(format: "%.1f", baseline))dB → \(String(format: "%.1f", withBoth))dB)")
        }

        // Removing one role's asset must never delete the other role's file.
        do {
            let projectID = UUID()
            guard let bgm = importBGM(seconds: 1.0, projectID: projectID),
                  let ambSrc = makeSyntheticBGM(seconds: 1.0, frequency: 220, ffmpeg: ffmpeg),
                  let amb = try? store.importFinalAmbienceAsset(from: URL(fileURLWithPath: ambSrc), projectID: projectID) else {
                t.check(false, "could not stage both roles for isolation test"); return
            }
            try? FileManager.default.removeItem(atPath: ambSrc)

            let bgmURL = store.managedProjectAssetURL(projectID: projectID, relativePath: bgm.projectRelativePath)
            let ambURL = store.managedProjectAssetURL(projectID: projectID, relativePath: amb.projectRelativePath)
            t.check(bgm.projectRelativePath != amb.projectRelativePath, "BGM and Ambience get distinct managed paths")

            store.removeManagedFinalAudioAsset(projectID: projectID, asset: bgm)
            t.check(!FileManager.default.fileExists(atPath: bgmURL?.path ?? ""), "removing BGM deletes the BGM file")
            t.check(FileManager.default.fileExists(atPath: ambURL?.path ?? ""), "removing BGM does NOT delete the Ambience file")

            store.removeManagedFinalAmbienceAsset(projectID: projectID, asset: amb)
            t.check(!FileManager.default.fileExists(atPath: ambURL?.path ?? ""), "removing Ambience deletes the Ambience file")
        }
    }
}
