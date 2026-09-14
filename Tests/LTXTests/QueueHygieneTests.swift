import Foundation
@testable import LTXVideoGeneratorCore

/// Once failures stayed visible until dismissed, the queue started rendering
/// old backend reasons verbatim — Python tracebacks full of `/Users/<name>/…`
/// and model directories on external volumes. These pin what the panel shows,
/// and that the stored reason is never rewritten to get there.
func runQueueHygieneTests(_ t: TestKit) {

    func show(_ s: String) -> String { ProductionFailurePresenter.displayReason(s) }

    t.suite("Production Queue — failure text never shows private paths") {

        // QUEUEHYGIENE_1 — home directory, as Python quotes it.
        let py = #"File "/Users/alice/Library/Application Support/LocalVideoStudio/runner.py", line 12"#
        let pyShown = show(py)
        t.check(!pyShown.contains("alice"), "QUEUEHYGIENE_1 the username is not visible")
        t.check(!pyShown.contains("/Users/"), "QUEUEHYGIENE_1 nor the home path")
        t.check(!pyShown.contains("Application Support"),
                "QUEUEHYGIENE_1 nor the Application Support layout, spaces and all")
        t.checkEqual(pyShown, #"File "…/runner.py", line 12"#,
                     "QUEUEHYGIENE_5 the file name and line survive")

        // QUEUEHYGIENE_2 / _3 / _4 — machine-local temp roots.
        t.checkEqual(show("could not open /private/var/tmp/job-1/frame.png"),
                     "could not open …/frame.png",
                     "QUEUEHYGIENE_2 a /private/var path is shortened")
        t.checkEqual(show("wrote /var/folders/m8/w9cy/T/ltx2mlx-ABC/out.mp4 then crashed"),
                     "wrote …/out.mp4 then crashed",
                     "QUEUEHYGIENE_3 a /var/folders path is shortened")
        t.checkEqual(show("missing /tmp/render/last.png."),
                     "missing …/last.png.",
                     "QUEUEHYGIENE_4 a /tmp path is shortened, keeping the full stop")

        // Real shape from the Dev queue: an unquoted directory on a volume
        // whose name contains a space. Stopping at the first space would
        // leave "USBHDD/AIModels/…" behind.
        let volume = "Failed to load LTX model: LTX-2.5 (Experimental): The directory at "
            + "/Volumes/ELECOM USBHDD/AIModels/LTX-2.5/Distilled-GGUF does not appear to contain "
            + "a complete ltx-2-mlx model (missing required .safetensors components)."
        let volumeShown = show(volume)
        t.check(!volumeShown.contains("ELECOM") && !volumeShown.contains("AIModels"),
                "QUEUEHYGIENE_5 a path with a space in a folder name is removed whole")
        t.checkEqual(volumeShown,
                     "Failed to load LTX model: LTX-2.5 (Experimental): The directory at "
                     + "…/Distilled-GGUF does not appear to contain "
                     + "a complete ltx-2-mlx model (missing required .safetensors components).",
                     "QUEUEHYGIENE_5 and the surrounding explanation reads the same")

        // A bare home or volume root would leave the username / disk name as
        // its own "last component".
        t.checkEqual(show("cwd was /Users/alice"), "cwd was …",
                     "QUEUEHYGIENE_1 a bare home directory does not reveal the username")
        t.checkEqual(show("mounted at /Volumes/Secret Disk"), "mounted at … Disk",
                     "QUEUEHYGIENE_1 a bare volume root collapses its first token")

        // QUEUEHYGIENE_6 — nothing path-like, nothing changes.
        for plain in [
            "Generation failed: ltx-2-mlx exited with code 1.",
            "Generation failed: MiniMax H3 is not configured. Select the local MiniMax H3 model directory.",
            "One or more works did not finish. Retry to resume the unfinished ones.",
            "missing required .safetensors components (text_encoder/model)",
        ] {
            t.checkEqual(show(plain), plain, "QUEUEHYGIENE_6 unchanged: \(plain.prefix(40))")
        }

        // QUEUEHYGIENE_7 — the app's own messages already name files safely.
        let frozenChanged = "開始画像がキュー追加後に変更されています（scratch-start.png）。"
            + "意図しない画像で生成しないよう、生成を中止しました。再度キューに追加してください。"
        let frozenMissing = "開始画像が見つかりません（opening.png）。"
            + "キュー追加後に移動または削除された可能性があります。選び直してください。"
        t.checkEqual(show(frozenChanged), frozenChanged,
                     "QUEUEHYGIENE_7 the changed-image message is untouched")
        t.checkEqual(show(frozenMissing), frozenMissing,
                     "QUEUEHYGIENE_7 the missing-image message is untouched")

        // QUEUEHYGIENE_8 — URLs are not filesystem paths.
        for url in [
            "see https://huggingface.co/Users/models/tmp/readme",
            "download from http://example.com/var/folders/x.bin failed",
            "opened file:///Users/alice/x.png",
        ] {
            t.checkEqual(show(url), url, "QUEUEHYGIENE_8 URL left alone: \(url.prefix(30))")
        }

        // QUEUEHYGIENE_9 — a real multi-line traceback shape from the Dev queue.
        let traceback = """
            Generation failed: ltx-2-mlx exited with code 1.
            File "/Users/azimnb/ltx23appdev/ltx-2-mlx-ltx25-poc/packages/ltx-pipelines-mlx/src/ltx_pipelines_mlx/_base.py", line 433, in _decode_and_save_video
            return _impl(
            ^^^^^^
            File "/Users/azimnb/ltx23appdev/ltx-2-mlx-ltx25-poc/packages/ltx-pipelines-mlx/src/ltx_pipelines_mlx/utils/_orchestration.py", line 232, in decode_and_save_video
            video_decoder.decode
            """
        let tbShown = show(traceback)
        t.check(!tbShown.contains("azimnb"), "QUEUEHYGIENE_9 no username on any line")
        t.check(!tbShown.contains("/Users/"), "QUEUEHYGIENE_9 no home path on any line")
        t.checkEqual(tbShown.components(separatedBy: "\n").count,
                     traceback.components(separatedBy: "\n").count,
                     "QUEUEHYGIENE_9 the traceback keeps its line structure")
        t.check(tbShown.hasPrefix("Generation failed: ltx-2-mlx exited with code 1.\n"),
                "QUEUEHYGIENE_9 the headline error is intact")
        t.check(tbShown.contains(#"File "…/_base.py", line 433, in _decode_and_save_video"#),
                "QUEUEHYGIENE_9 first frame keeps file, line and function")
        t.check(tbShown.contains(#"File "…/_orchestration.py", line 232"#),
                "QUEUEHYGIENE_9 second frame too")

        // QUEUEHYGIENE_10 — display never writes back.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("QueueHygiene-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProductionQueueStore(fileURL: root.appendingPathComponent("q.json"))
        let coordinator = ProductionQueueCoordinator(store: store, restoreOnInit: false)
        coordinator.setPaused(true)
        let queued = coordinator.enqueue(
            ProductionJob(kind: .generate, title: "tb", snapshot: ProductionJobSnapshot()))
        coordinator.markFailed(jobID: queued.id, reason: traceback)
        for display in coordinator.activeDisplayJobs {
            _ = show(display.failureReason ?? "")
        }
        t.checkEqual(coordinator.job(id: queued.id)?.failureReason, traceback,
                     "QUEUEHYGIENE_10 the stored reason is byte-identical after display")
        store.flush()
        let reloaded = ProductionQueueCoordinator(store: store, restoreOnInit: true)
        t.checkEqual(reloaded.job(id: queued.id)?.failureReason, traceback,
                     "QUEUEHYGIENE_10 and on disk, full diagnostic paths included")
    }

    t.suite("Production Queue — Pause shows only when there is something to pause") {
        func job(_ state: ProductionJobState) -> ProductionJob {
            var j = ProductionJob(kind: .autoMovie, title: "\(state)", snapshot: ProductionJobSnapshot())
            j.state = state
            return j
        }
        func shows(_ states: [ProductionJobState], paused: Bool = false) -> Bool {
            ProductionQueueCoordinator.showsPauseControl(jobs: states.map(job), isPaused: paused)
        }

        t.check(shows([.running]), "QUEUEHYGIENE_11 a running job shows Pause")
        t.check(shows([.waiting]), "QUEUEHYGIENE_12 waiting work shows Pause")
        t.check(!shows([.failed]), "QUEUEHYGIENE_13 a failed-only queue hides Pause")
        t.check(!shows([.failed, .failed, .failed]),
                "QUEUEHYGIENE_13 however many failures it holds")
        t.check(shows([.failed, .running]), "QUEUEHYGIENE_14 failed + running shows Pause")
        t.check(!shows([.completed, .cancelled, .interrupted, .failed]),
                "QUEUEHYGIENE_15 a terminal-only queue hides Pause")
        t.check(!shows([]), "QUEUEHYGIENE_15 an empty queue hides it too")
        // A paused queue must keep saying so, or the next submission silently
        // never starts.
        t.check(shows([.failed], paused: true),
                "QUEUEHYGIENE_15 a paused queue keeps Resume visible")
    }
}
