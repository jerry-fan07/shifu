import AppKit
import Foundation
import Testing
@testable import ShifuApp

/// The fullscreen chrome's idle watch (design.md §3.6).
///
/// The bar sits over the footage, so "is it still there" is the difference
/// between watching a screen and watching seven eighths of one. Driven against
/// a real run loop for the same reason `RewindClockTests` is: a timer that
/// never fires would otherwise read as a bar that never hides.
@Suite struct FullscreenChromeTests {
    /// A short idle so the suite doesn't sit through the real 2.5 s.
    ///
    /// **The watch only looks twice a second**, so every moment here is
    /// uncertain by one tick either way: "still up" has to be checked before
    /// `idle - 0.5` and "gone" after `idle + 0.5`, or the test measures how
    /// loaded the machine is rather than what the chrome does. Hence 1.5 with
    /// 0.6/2.4 either side — margins of ~0.4 s, not ~0.1.
    private static let idle: TimeInterval = 1.5
    private static let wellBefore: TimeInterval = 0.6
    private static let wellAfter: TimeInterval = 2.4

    @MainActor private func chrome() -> FullscreenChrome {
        FullscreenChrome(idleSeconds: Self.idle)
    }

    @MainActor private func settle(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    @MainActor @Test func stillnessHidesItAndMotionBringsItBack() {
        let chrome = chrome()
        defer { chrome.end() }

        #expect(chrome.visible, "fullscreen opens with the controls up")
        chrome.begin()
        settle(Self.wellBefore)
        #expect(chrome.visible, "it must not vanish before it has been read")

        settle(Self.wellAfter - Self.wellBefore)
        #expect(!chrome.visible, "the bar never left the footage")

        chrome.stir()
        #expect(chrome.visible, "moving the pointer did not bring it back")
        settle(Self.wellBefore)
        #expect(chrome.visible, "the idle clock did not restart on motion")
    }

    /// The failure this guards against is the nastiest one available: reaching
    /// for the play button and having it disappear as your hand stops moving.
    @MainActor @Test func itNeverHidesUnderThePointer() {
        let chrome = chrome()
        defer { chrome.end() }

        chrome.begin()
        chrome.pinned = true
        settle(Self.wellAfter)
        #expect(chrome.visible, "the bar hid while the pointer was on it")

        // And leaving it starts the clock rather than hiding on the spot.
        chrome.pinned = false
        settle(Self.wellBefore)
        #expect(chrome.visible, "leaving the bar hid it instantly")
        settle(Self.wellAfter - Self.wellBefore)
        #expect(!chrome.visible, "leaving the bar never let it hide")
    }

    /// A click on the footage is the deliberate way to clear the screen, and
    /// the way back if a trackpad never quite goes still.
    @MainActor @Test func clickingTheFootageTogglesIt() {
        let chrome = chrome()
        defer { chrome.end() }

        chrome.begin()
        chrome.toggle()
        #expect(!chrome.visible)
        chrome.toggle()
        #expect(chrome.visible)
    }

    /// Leaving fullscreen while the chrome is hidden must not carry a hidden
    /// bar back into the next visit — and must stop the timer, or the watch
    /// outlives the window it was watching.
    @MainActor @Test func leavingResetsAndStopsTheWatch() {
        let chrome = chrome()
        chrome.begin()
        settle(Self.wellAfter)
        #expect(!chrome.visible)

        chrome.end()
        #expect(chrome.visible, "the next fullscreen would open with no controls")
        settle(Self.wellAfter)
        #expect(chrome.visible, "the idle watch outlived the window")

        // Idempotent: the page and the window both call it, either order.
        chrome.end()
        #expect(chrome.visible)
    }
}
