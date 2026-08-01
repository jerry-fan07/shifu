import AppKit
import ShifuCore
import Testing
@testable import ShifuApp

/// The nudge demonstration takes the whole screen at `.screenSaver` level, so
/// its lifecycle is the one place in the app where a bug is not a wrong pixel
/// but a click-through amber overlay stranded over everything the user owns.
/// These cover the two ways that happens — a second present stacking windows
/// the first `dismiss` won't reach, and a `dismiss` that doesn't clean up —
/// plus the promise the page makes about what running it changes.
///
/// The windows are ordered in and straight back out within one turn of the run
/// loop, so nothing composites: this flashes no one's screen.
@Suite struct NudgeDemoTests {
    @MainActor @Test func presentingTwiceDoesNotStackOverlays() {
        let demo = NudgeDemo()
        defer { demo.dismiss() }

        demo.present()
        #expect(demo.isPresenting)
        #expect(demo.pulses == 1)
        // One vignette per display, plus the bar.
        #expect(demo.windowCount == NSScreen.screens.count + 1)
        let shown = demo.windowCount

        demo.present()
        #expect(demo.windowCount == shown)
        // The second call is a no-op end to end, not just window-wise: a
        // re-pulse here would restart the bar's playhead under the user.
        #expect(demo.pulses == 1)
    }

    @MainActor @Test func dismissLeavesNothingOnScreen() {
        let demo = NudgeDemo()
        demo.present()
        demo.dismiss()

        #expect(!demo.isPresenting)
        #expect(demo.windowCount == 0)
        #expect(demo.vignette == 0)
        #expect(demo.message == 0)
        // Idempotent: the bar's Done and the Escape monitor can both land.
        demo.dismiss()
        #expect(!demo.isPresenting)
    }

    @MainActor @Test func againFiresAnotherPulse() {
        let demo = NudgeDemo()
        defer { demo.dismiss() }
        demo.present()
        demo.fire()
        // The trigger has to *change* for the playhead to restart — a replayed
        // 0→1 animation is coalesced into no animation at all.
        #expect(demo.pulses == 2)
    }

    /// "Done" returns to the Focus Mode beat with the switch where it was:
    /// running the demonstration is not consent to turn Focus Mode on.
    /// Asserted against whatever the switch happens to be rather than a fixed
    /// state, so the claim is the one that matters — the demo doesn't move it.
    @MainActor @Test func runningTheDemoLeavesTheSwitchAlone() {
        let before = FocusModeFile.isOn()
        let demo = NudgeDemo()
        demo.present()
        demo.fire()
        demo.dismiss()
        #expect(FocusModeFile.isOn() == before)
    }
}
