import Foundation
@testable import LTXVideoGeneratorCore

func runAutoMoviePlanPreviewTests(_ t: TestKit) {

    func plannedProject(withOpeningReference: Bool = true) -> FilmProject {
        var project = FilmProject(title: "Preview")
        project.workflowMode = AutoMovieRunCoordinator.autoMovieWorkflowMode
        if withOpeningReference {
            project.openingReferenceImage = OpeningReferenceImage(
                projectRelativePath: "Assets/OpeningReference/o.png",
                originalFilename: "o.png", mimeType: "image/png", fileSizeBytes: 1)
        }
        var one = Shot(index: 0, title: "Approach",
                       summary: "She walks across the courtyard toward the gate.")
        one.durationSeconds = 5
        one.continuityMode = .cut
        one.camera = CameraPlan(shotScale: "medium-wide", angle: "eye-level", movement: "static")

        var two = Shot(index: 1, title: "Pause", summary: "She stops and looks up.")
        two.durationSeconds = 5
        two.continuityMode = .continueFromPrevious
        two.camera = CameraPlan(shotScale: "medium", angle: "eye-level", movement: "slow push-in")

        var three = Shot(index: 2, title: "React", summary: "She reacts.")
        three.durationSeconds = 5
        three.continuityMode = .continueFromPrevious
        three.camera = CameraPlan(shotScale: "close-up", angle: "eye-level", movement: "static")

        var four = Shot(index: 3, title: "Enter", summary: "She moves into the gate.")
        four.durationSeconds = 5
        four.continuityMode = .cut
        four.camera = CameraPlan(shotScale: "wide", angle: "eye-level", movement: "static")

        project.shots = [one, two, three, four]
        return project
    }

    t.suite("Auto Movie plan preview — the plan is readable before generation") {
        let preview = AutoMoviePlanPreview.make(project: plannedProject())
        t.checkEqual(preview.rows.count, 4, "every planned shot appears")
        t.checkEqual(preview.rows[0].number, 1, "shots are numbered from one")
        t.checkEqual(preview.rows[0].action, "She walks across the courtyard toward the gate.",
                     "the planned action is shown")
        t.checkEqual(preview.rows[2].framing, "Close-up", "the planned framing is shown")
        t.checkEqual(preview.rows[1].cameraMovement, "slow push-in",
                     "and the camera movement when the plan has one")
        t.check(!preview.hasAnyGenerated,
                "nothing is generated yet, and the preview says so")
    }

    t.suite("Auto Movie plan preview — durations are approximate") {
        let preview = AutoMoviePlanPreview.make(project: plannedProject())
        t.checkEqual(preview.rows[0].approximateDurationText, "~5 sec",
                     "a shot reads as approximate, never frame-exact")
        t.checkEqual(preview.totalApproximateSeconds, 20, "the total sums the planned beats")
        t.checkEqual(preview.totalDurationText, "Approx. 20 sec total",
                     "and is worded as an approximation")
        for row in preview.rows {
            t.check(row.approximateDurationText.hasPrefix("~"),
                    "shot \(row.number) never implies exact timing")
        }
    }

    t.suite("Auto Movie plan preview — sources match what generation will do") {
        let preview = AutoMoviePlanPreview.make(project: plannedProject())
        t.checkEqual(preview.rows[0].sourceDescription, "Opening Reference",
                     "shot 1 shows the opening reference it will actually start from")
        t.checkEqual(preview.rows[0].continuityIntent, "Cut",
                     "and its planned continuity intent")
        // Before generation a later shot has no inherited asset yet; the
        // preview must describe what it *will* use, not report text-to-video.
        t.checkEqual(preview.rows[1].sourceDescription, "Previous shot's last frame",
                     "a continuing shot says what it will inherit")
        t.checkEqual(preview.rows[1].continuityIntent, "Continue",
                     "and is labelled as a continuation")
        t.checkEqual(preview.rows[3].sourceDescription, "Text to video",
                     "a planned cut correctly shows it inherits nothing")

        // Without an opening reference shot 1 is text-to-video.
        let noRef = AutoMoviePlanPreview.make(project: plannedProject(withOpeningReference: false))
        t.checkEqual(noRef.rows[0].sourceDescription, "Text to video",
                     "with no opening reference the first shot is text-to-video")
    }

    t.suite("Auto Movie plan preview — progress and edge cases") {
        var partly = plannedProject()
        let take = Take(shotID: partly.shots[0].id, modelID: "m", seed: 1,
                        promptSnapshot: "p", settingsSnapshot: .default,
                        requestedWidth: 768, requestedHeight: 512,
                        fps: 24, requestedDuration: 5, status: .completed)
        partly.shots[0].takes = [take]
        let preview = AutoMoviePlanPreview.make(project: partly)
        t.check(preview.rows[0].isGenerated, "a shot with a completed take is marked generated")
        t.check(!preview.rows[1].isGenerated, "and one without is not")
        t.checkEqual(preview.generatedCount, 1, "the generated count is reported")

        // An unplanned project shows nothing rather than an empty frame.
        var empty = FilmProject(title: "Empty")
        empty.workflowMode = AutoMovieRunCoordinator.autoMovieWorkflowMode
        t.check(AutoMoviePlanPreview.make(project: empty).isEmpty,
                "a project with no shots has no preview")

        // A shot with no summary falls back to its title rather than blank.
        var untitled = plannedProject()
        untitled.shots[0].summary = ""
        t.checkEqual(AutoMoviePlanPreview.make(project: untitled).rows[0].action, "Approach",
                     "a shot with no summary shows its title")
    }

    t.suite("Auto Movie plan preview — previewing starts no generation") {
        // The preview is derived from stored plan data only. It reads the
        // project and touches neither the renderer nor the queue, so opening a
        // project can never begin work.
        var project = plannedProject()
        let before = try! JSONEncoder().encode(project)
        _ = AutoMoviePlanPreview.make(project: project)
        let after = try! JSONEncoder().encode(project)
        t.checkEqual(before, after, "building the preview mutates nothing")
        t.check(project.shots.allSatisfy { $0.takes.isEmpty },
                "and creates no takes")
        project.shots[0].takes = []
        t.check(AutoMoviePlanPreview.make(project: project).rows.count == 4,
                "the preview is a pure function of the plan")
    }
}
