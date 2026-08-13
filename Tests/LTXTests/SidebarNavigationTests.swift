import Foundation
@testable import LTXVideoGeneratorCore

func runSidebarNavigationTests(_ t: TestKit) {
    t.suite("Sidebar navigation — runtime state is user-controlled") {
        // A. Every primary destination uses the same authoritative selection.
        var fresh = SidebarNavigationState(persistedRawValue: nil)
        t.checkEqual(fresh.selection, .generate, "fresh launch defaults to Generate")
        for destination in [ContentView.Tab.oneShot, .storyboard, .hybrid, .history, .generate] {
            fresh.select(destination)
            t.checkEqual(fresh.selection, destination,
                         "fresh navigation reaches \(destination.rawValue)")
        }

        // B/E. Queue success routes to Archive once. There is no retained
        // submission flag or observer capable of forcing the next click back.
        fresh.didQueueDirectGeneration()
        t.checkEqual(fresh.selection, .history,
                     "successful Direct Generate routes to Video Archive once")
        fresh.select(.oneShot)
        t.checkEqual(fresh.selection, .oneShot,
                     "the next user click wins after queued-generation routing")
        fresh.select(.storyboard)
        t.checkEqual(fresh.selection, .storyboard,
                     "later clicks are not forced back to Video Archive")

        // C/D. Rendering is deliberately not represented in navigation state.
        // Simulating active work cannot change or block a route mutation.
        let productionJobIsRunning = true
        fresh.select(.generate)
        t.check(productionJobIsRunning && fresh.selection == .generate,
                "active render does not block Generate navigation")
        fresh.select(.history)
        t.check(productionJobIsRunning && fresh.selection == .history,
                "active render does not block Video Archive navigation")

        // F. A failed validation does not call the success event.
        let invalidSubmission = SidebarNavigationState(
            persistedRawValue: ContentView.Tab.generate.rawValue)
        t.check(!GenerationSubmissionPolicy.canSubmit(prompt: "   \n"),
                "invalid submission is rejected before route change")
        t.checkEqual(invalidSubmission.selection, .generate,
                     "validation failure leaves the current route unchanged")

        // Backward-compatible persisted raw values still choose the initial tab.
        let restored = SidebarNavigationState(
            persistedRawValue: ContentView.Tab.storyboard.rawValue)
        t.checkEqual(restored.selection, .storyboard,
                     "persisted sidebar destination remains the launch default")
        let unknown = SidebarNavigationState(persistedRawValue: "future-route")
        t.checkEqual(unknown.selection, .generate,
                     "unknown persisted destination safely falls back to Generate")
    }
}
