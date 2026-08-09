import AppKit
import ShifuCore
import Testing
@testable import ShifuApp

/// The box-drag for Snip (design.md §3.6).
///
/// Two things can go wrong here and only one of them is visible. The loud one
/// is `NudgeDemo`'s failure mode — a full-screen `.screenSaver` panel stranded
/// over everything the user owns — and it is covered the same way. The quiet
/// one is the coordinate flip: a drag that produces *a* rect, just not the one
/// the user drew, ships a feature that snips the wrong part of the screen and
/// looks like it works. `SnipRegionTests` pins the arithmetic; this pins the
/// path from an actual mouse drag to the rect the daemon is handed.
///
/// The panels are ordered in and straight back out within one turn of the run
/// loop, so nothing composites: this flashes no one's screen.
@MainActor
@Suite struct SnipOverlayTests {
    private func mouse(
        _ type: NSEvent.EventType, at point: CGPoint, in panel: NSPanel
    ) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, eventNumber: 0,
            clickCount: 1, pressure: 1)!
    }

    private func key(_ code: UInt16, in panel: NSPanel) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: "",
            charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
    }

    @Test func aDragBecomesTheRectTheDaemonIsHanded() async throws {
        let overlay = SnipOverlay()
        defer { overlay.cancel() }
        var picked: SnipRegion?
        overlay.present { picked = $0 }

        let panel = try #require(overlay.panels.first)
        let canvas = try #require(panel.contentView as? SnipCanvas)
        let screen = canvas.screenFrame
        // Panel coordinates are the screen's own, bottom-left origin.
        canvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 100, y: 120), in: panel))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 400, y: 300), in: panel))
        canvas.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 500, y: 420), in: panel))

        #expect(!overlay.isPresenting)
        try await Task.sleep(for: .milliseconds(400))
        let region = try #require(picked)
        #expect(region.displayID == canvas.displayID)
        #expect(region.left == 100)
        #expect(region.width == 400)
        #expect(region.height == 300)
        // Flipped: 420 up from the bottom is `height − 420` down from the top.
        #expect(region.top == Int(screen.height) - 420)
    }

    /// Dragging up-and-left is the same box as dragging down-and-right. Users
    /// do both, and a rect with a negative width is not a rect.
    @Test func draggingBackwardsGivesTheSameBox() async throws {
        let overlay = SnipOverlay()
        defer { overlay.cancel() }
        var picked: SnipRegion?
        overlay.present { picked = $0 }

        let panel = try #require(overlay.panels.first)
        let canvas = try #require(panel.contentView as? SnipCanvas)
        canvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 500, y: 420), in: panel))
        canvas.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 100, y: 120), in: panel))

        try await Task.sleep(for: .milliseconds(400))
        let region = try #require(picked)
        #expect(region.left == 100)
        #expect(region.width == 400)
        #expect(region.height == 300)
        #expect(region.top == Int(canvas.screenFrame.height) - 420)
    }

    /// A click that never became a drag is a click. Snipping a 2-pixel box
    /// because the mouse twitched would be a frame filed for nothing.
    @Test func aClickThatNeverBecameADragSnipsNothing() async throws {
        let overlay = SnipOverlay()
        defer { overlay.cancel() }
        var picked: SnipRegion?
        overlay.present { picked = $0 }

        let panel = try #require(overlay.panels.first)
        let canvas = try #require(panel.contentView as? SnipCanvas)
        canvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 300, y: 300), in: panel))
        canvas.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 302, y: 301), in: panel))

        #expect(!overlay.isPresenting)
        try await Task.sleep(for: .milliseconds(400))
        #expect(picked == nil)
    }

    @Test func escapeTakesNothingAndLeavesNothingOnScreen() async throws {
        let overlay = SnipOverlay()
        defer { overlay.cancel() }
        var picked: SnipRegion?
        overlay.present { picked = $0 }

        let panel = try #require(overlay.panels.first)
        let canvas = try #require(panel.contentView as? SnipCanvas)
        canvas.keyDown(with: key(53, in: panel))

        #expect(!overlay.isPresenting)
        #expect(overlay.panels.isEmpty)
        try await Task.sleep(for: .milliseconds(400))
        #expect(picked == nil)
    }

    /// ⏎ is the whole screen you are *looking at*, expressed as a region rather
    /// than as "no region" — otherwise a second monitor would snip the first.
    @Test func returnTakesTheWholeScreenItWasPressedOn() async throws {
        let overlay = SnipOverlay()
        defer { overlay.cancel() }
        var picked: SnipRegion?
        overlay.present { picked = $0 }

        let panel = try #require(overlay.panels.first)
        let canvas = try #require(panel.contentView as? SnipCanvas)
        canvas.keyDown(with: key(36, in: panel))

        try await Task.sleep(for: .milliseconds(400))
        let region = try #require(picked)
        #expect(region == SnipRegion(
            displayID: canvas.displayID, left: 0, top: 0,
            width: Int(canvas.screenFrame.width), height: Int(canvas.screenFrame.height)))
    }

    /// `NudgeDemo`'s failure mode, and worse here: a second present would strand
    /// a dimming layer over every screen that the first cancel can't reach.
    @Test func presentingTwiceDoesNotStackOverlays() {
        let overlay = SnipOverlay()
        defer { overlay.cancel() }

        overlay.present { _ in }
        let shown = overlay.panels.count
        #expect(shown == NSScreen.screens.count)

        overlay.present { _ in }
        #expect(overlay.panels.count == shown)
    }

    @Test func cancellingIsIdempotent() {
        let overlay = SnipOverlay()
        overlay.present { _ in }
        overlay.cancel()

        #expect(!overlay.isPresenting)
        overlay.cancel()
        #expect(!overlay.isPresenting)
    }
}
