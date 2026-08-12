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

func runFinalAudioTests(_ t: TestKit) {
    t.suite("Final Audio — persistence") {
        // A. Old project JSON without `finalAudio` at all must decode with
        // BGM off, reproducing every project written before this feature.
        let legacyJSON = """
        {"id":"\(UUID().uuidString)","title":"Legacy"}
        """.data(using: .utf8)!
        do {
            let decoded = try JSONDecoder().decode(FilmProject.self, from: legacyJSON)
            t.checkEqual(decoded.finalAudio.bgmEnabled, false, "legacy project without finalAudio decodes with BGM off")
            t.check(decoded.finalAudio.bgmAsset == nil, "legacy project has no BGM asset")
            t.checkEqual(decoded.finalAudio.isActive, false, "legacy project's finalAudio is not active")
        } catch {
            t.check(false, "legacy project without finalAudio failed to decode: \(error)")
        }

        // A fresh project also defaults to BGM off.
        let fresh = FilmProject(title: "Fresh")
        t.checkEqual(fresh.finalAudio.bgmEnabled, false, "new project defaults to BGM off")

        // Settings round-trip through Codable.
        var withBGM = FilmProject(title: "WithBGM")
        withBGM.finalAudio.bgmEnabled = true
        withBGM.finalAudio.bgmAsset = FinalBGMAsset(
            projectRelativePath: "Assets/FinalAudio/bgm-test.mp3",
            originalFilename: "forest_theme.mp3",
            mimeType: "audio/mpeg",
            fileSizeBytes: 12345
        )
        withBGM.finalAudio.bgmVolume = 0.4
        withBGM.finalAudio.fadeInSeconds = 2
        withBGM.finalAudio.fadeOutSeconds = 3
        do {
            let data = try JSONEncoder().encode(withBGM)
            let decoded = try JSONDecoder().decode(FilmProject.self, from: data)
            t.checkEqual(decoded.finalAudio, withBGM.finalAudio, "FinalAudioSettings round-trips through Codable")
            t.checkEqual(decoded.finalAudio.bgmAsset?.originalFilename, "forest_theme.mp3", "imported asset reference persists")
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
            let asset = try store.importFinalBGMAsset(from: URL(fileURLWithPath: sourcePath), projectID: projectID)
            t.check(asset.projectRelativePath.hasPrefix("Assets/FinalAudio/"), "imported asset lives under the project's FinalAudio directory")
            let resolved = store.managedProjectAssetURL(projectID: projectID, relativePath: asset.projectRelativePath)
            t.check(resolved != nil && FileManager.default.fileExists(atPath: resolved!.path), "imported file actually exists at its managed path")

            // Unsupported format is rejected before touching the filesystem.
            let badSource = FileManager.default.temporaryDirectory.appendingPathComponent("not-audio-\(UUID().uuidString).txt")
            try? "not audio".write(to: badSource, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: badSource) }
            do {
                _ = try store.importFinalBGMAsset(from: badSource, projectID: projectID)
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
            s.bgmAsset = FinalBGMAsset(projectRelativePath: assetPath, originalFilename: "test.wav")
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
}
