import Foundation
import Combine
@testable import LTXVideoGeneratorCore

/// Each render attempt writes its own file; only a completed attempt the queue
/// still owns becomes the request's output.
///
/// The output file was named for the request and Retry keeps the request's id,
/// so attempt 1 and attempt 2 were told to write the same file — a surviving
/// attempt 1 could overwrite the video attempt 2 had just produced, whether or
/// not anything managed to stop its process.
func runRenderAttemptOutputTests(_ t: TestKit) {

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RenderAttempt-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let fm = FileManager.default
    defer { try? fm.removeItem(at: root) }

    func spin(maxTurns: Int = 400, until done: () -> Bool) -> Bool {
        for _ in 0..<maxTurns {
            if done() { return true }
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005))
        }
        return done()
    }
    func write(_ path: String, _ text: String) {
        try? fm.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: path, contents: Data(text.utf8))
    }
    func read(_ path: String) -> String? {
        fm.contents(atPath: path).flatMap { String(data: $0, encoding: .utf8) }
    }

    t.suite("RENDERORPHAN — staging and adoption") {
        let videos = root.appendingPathComponent("Videos", isDirectory: true)
        let id = UUID()
        let one = RenderAttemptOutput.stagingPath(outputDirectory: videos, requestID: id, attempt: 1)
        let two = RenderAttemptOutput.stagingPath(outputDirectory: videos, requestID: id, attempt: 2)
        let canonical = videos.appendingPathComponent("\(id.uuidString).mp4").path
        t.check(one != two && one != canonical && two != canonical,
                "RENDERORPHAN_5 each attempt has its own staging file, never the output itself")
        t.checkEqual(URL(fileURLWithPath: two).pathComponents.suffix(4),
                     [".lvs-render-staging", id.uuidString, "attempt-2", "render.mp4"],
                     "RENDERORPHAN_5 under the request's own staging directory")

        // RENDERORPHAN_7 — adoption moves the render and its side files.
        write(one, "attempt 1")
        write(two, "attempt 2")
        write(URL(fileURLWithPath: two).deletingLastPathComponent().appendingPathComponent("render_audio.wav").path, "audio 2")
        write(videos.appendingPathComponent("notes.txt").path, "keep")
        do {
            let adopted = try RenderAttemptOutput.promote(returnedPath: two, stagingPath: two, canonicalPath: canonical)
            t.checkEqual(adopted, canonical, "RENDERORPHAN_7 the adopted path is the request's output")
        } catch { t.check(false, "RENDERORPHAN_7 adoption threw \(error)") }
        t.checkEqual(read(canonical), "attempt 2", "RENDERORPHAN_7 the completed attempt becomes the output")
        t.checkEqual(read(videos.appendingPathComponent("\(id.uuidString)_audio.wav").path), "audio 2",
                     "RENDERORPHAN_7 with the side file it wrote, renamed alongside")
        t.check(!fm.fileExists(atPath: URL(fileURLWithPath: two).deletingLastPathComponent().path),
                "RENDERORPHAN_7 its staging directory is gone")
        t.checkEqual(read(one), "attempt 1", "RENDERORPHAN_6 attempt 1's own staging file is not touched by attempt 2")

        // RENDERORPHAN_6 — attempt 1 writes late; the output is untouched.
        write(one, "attempt 1 late")
        t.checkEqual(read(canonical), "attempt 2", "RENDERORPHAN_6 a late attempt 1 does not change the adopted output")

        // Refusals.
        let empty = RenderAttemptOutput.stagingPath(outputDirectory: videos, requestID: UUID(), attempt: 1)
        write(empty, "")
        let emptyCanonical = videos.appendingPathComponent("empty.mp4").path
        write(emptyCanonical, "previous")
        var threw = false
        do { _ = try RenderAttemptOutput.promote(returnedPath: empty, stagingPath: empty, canonicalPath: emptyCanonical) } catch { threw = true }
        t.check(threw && read(emptyCanonical) == "previous", "RENDERORPHAN_7 an empty render is not adopted")
        let elsewhere = root.appendingPathComponent("elsewhere.mp4").path
        write(elsewhere, "backend chose its own path")
        t.checkEqual(try? RenderAttemptOutput.promote(returnedPath: elsewhere, stagingPath: two, canonicalPath: canonical), elsewhere,
                     "RENDERORPHAN_7 a backend that returned another path keeps it; nothing is moved")

        // discard: only exact staging shapes.
        RenderAttemptOutput.discard(stagingPath: canonical)
        RenderAttemptOutput.discard(stagingPath: videos.appendingPathComponent("notes.txt").path)
        t.check(read(canonical) == "attempt 2" && read(videos.appendingPathComponent("notes.txt").path) == "keep",
                "RENDERORPHAN_7 discarding refuses anything that is not an attempt's staging file")
        let three = RenderAttemptOutput.stagingPath(outputDirectory: videos, requestID: id, attempt: 3)
        write(three, "attempt 3")
        RenderAttemptOutput.discard(stagingPath: one)
        t.check(!fm.fileExists(atPath: one) && read(three) == "attempt 3",
                "RENDERORPHAN_6 discarding attempt 1 leaves attempt 3's staging alone")
    }

    // MARK: Attempt output isolation, through the renderer

    t.suite("RENDERORPHAN — each attempt renders to its own file") {
        MainActor.assumeIsolated {
            final class Renders: @unchecked Sendable {
                var paths: [Int: String] = [:]
                var behavior: [Int: String] = [:]   // "write:<text>" | "cancel"
            }
            let renders = Renders()
            let historyRoot = root.appendingPathComponent("history", isDirectory: true)
            let history = HistoryManager(rootDirectory: historyRoot)
            let service = GenerationService(historyManager: history)
            var settled: [RunOutcomeRecord] = []
            let sink = service.$lastRunSettlement.sink { if let s = $0 { settled.append(s) } }
            defer { sink.cancel() }
            service.preflight = GenerationPreflight(
                pythonPath: { "/scratch/python" },
                ensurePythonReady: { _ in (true, "", nil) },
                configurePython: { _ in },
                loadModel: { _ in true },
                storage: { _, _ in .healthy(availableBytes: 1 << 40) })
            service.renderOverride = { request, path in
                let attempt = request.attemptNumber ?? 1
                renders.paths[attempt] = path
                let behavior = renders.behavior[attempt] ?? "write:attempt \(attempt)"
                if behavior == "cancel" { throw LTXError.cancelled }
                try? FileManager.default.createDirectory(
                    at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: path, contents: Data(behavior.dropFirst(6).utf8))
                return (path, 7, nil)
            }

            var request = GenerationRequest(
                prompt: "p", modelId: "ltx23_distilled_q4",
                parameters: GenerationParameters(numInferenceSteps: 15, guidanceScale: 3, width: 512, height: 320,
                                                 numFrames: 81, fps: 24, seed: 7, vaeTilingMode: "auto", imageStrength: 1))
            request.attemptNumber = 1
            let customOutput = UserDefaults.standard.string(forKey: "outputDirectory") ?? ""
            let videos = customOutput.isEmpty ? history.videosDirectory : URL(fileURLWithPath: customOutput)
            let canonical = videos.appendingPathComponent("\(request.id.uuidString).mp4").path

            // Attempt 1 dies mid-render: nothing is adopted.
            renders.behavior[1] = "cancel"
            service.addBatch([request])
            t.check(spin { renders.paths[1] != nil && !service.isProcessing && service.queue.isEmpty },
                    "RENDERORPHAN_6 attempt 1 ends")
            t.check(!fm.fileExists(atPath: canonical), "RENDERORPHAN_6 attempt 1, stopped mid-render, adopted nothing")

            // Retry: the same request id, attempt 2.
            var retry = request
            retry.attemptNumber = 2
            retry.status = .pending
            service.addBatch([retry])
            t.check(spin { settled.contains { $0.runID == request.id && $0.attemptNumber == 2 } },
                    "RENDERORPHAN_7 attempt 2 completes")
            let one = renders.paths[1] ?? "", two = renders.paths[2] ?? ""
            t.check(!one.isEmpty && one != two, "RENDERORPHAN_RED RENDERORPHAN_5 attempts 1 and 2 render to different files")
            t.check(two != canonical, "RENDERORPHAN_7 a backend never writes the adopted file directly")
            t.checkEqual(read(canonical), "attempt 2", "RENDERORPHAN_7 attempt 2's completed render is adopted")
            let outcome = settled.last { $0.runID == request.id && $0.attemptNumber == 2 }
            t.checkEqual(outcome?.outputPath, canonical, "RENDERORPHAN_7 and settled with the adopted path")
            t.check(history.results.contains { $0.videoPath == canonical }, "RENDERORPHAN_7 History records the adopted file")

            // The orphaned attempt 1 finishes late, writing where it was told to.
            if !one.isEmpty {
                try? fm.createDirectory(at: URL(fileURLWithPath: one).deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
                fm.createFile(atPath: one, contents: Data("attempt 1 late".utf8))
            }
            t.checkEqual(read(canonical), "attempt 2", "RENDERORPHAN_RED RENDERORPHAN_6 attempt 1's late output does not overwrite attempt 2's")

            // A render that succeeds after its request was cancelled is not adopted.
            var cancelled = GenerationRequest(
                prompt: "q", modelId: "ltx23_distilled_q4", parameters: request.parameters)
            cancelled.attemptNumber = 1
            let cancelledCanonical = videos.appendingPathComponent("\(cancelled.id.uuidString).mp4").path
            service.renderOverride = { [weak service] req, path in
                await MainActor.run { service?.cancelCurrent() }
                try? FileManager.default.createDirectory(
                    at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: path, contents: Data("too late".utf8))
                return (path, 7, nil)
            }
            service.addBatch([cancelled])
            t.check(spin { !service.isProcessing && service.queue.isEmpty }, "RENDERORPHAN_7 the cancelled render ends")
            t.check(!fm.fileExists(atPath: cancelledCanonical), "RENDERORPHAN_7 a render cancelled before it finished is not adopted")
        }
    }

}
