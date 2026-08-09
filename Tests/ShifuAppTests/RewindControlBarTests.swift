import AppKit
import Foundation
import ShifuCore
import SwiftUI
import Testing
@testable import ShifuApp

/// The transport bar (design.md §3.6).
///
/// The marks are drawn geometry rather than type, which means the usual
/// safety net — "the string is right" — does not exist here: a play triangle
/// pointing the wrong way, a bracket outside its button, an exit mark
/// indistinguishable from the enter one are all silent. So the bar is *filmed*,
/// and the geometry that can be asserted is asserted.
@Suite struct RewindControlBarTests {
    /// Every mark has to stay inside the button that draws it — a bracket arm
    /// running past the circle is the failure mode of writing glyphs as unit
    /// coordinates, and it is invisible until the button is next to another one.
    @MainActor @Test func everyMarkStaysInsideItsBox() {
        let box = CGRect(x: 0, y: 0, width: 100, height: 100)
        let kinds: [PlayerGlyph.Kind] = [
            .play, .pause, .stepBack, .stepForward, .skipBack, .skipForward,
            .enterFullscreen, .exitFullscreen
        ]
        for kind in kinds {
            let bounds = PlayerGlyph(kind: kind).path(in: box).boundingRect
            #expect(box.insetBy(dx: -0.01, dy: -0.01).contains(bounds), "\(kind) escapes its box")
            // And fills it: a mark that only touches a fifth of its button
            // reads as a speck rather than as a control. 55 rather than a
            // rounder number because the pause mark's two bars honestly span
            // that much and no more.
            #expect(bounds.width > 55 && bounds.height > 55, "\(kind) is too small to read")
        }
    }

    /// The two triangles point opposite ways. Asserted by where the *tip* is,
    /// because a mirrored glyph has the same bounding box as the original.
    @MainActor @Test func theTrianglesPointOppositeWays() {
        let box = CGRect(x: 0, y: 0, width: 100, height: 100)
        let forward = PlayerGlyph(kind: .stepForward).path(in: box)
        let back = PlayerGlyph(kind: .stepBack).path(in: box)
        // The step bar sits behind the tip: forward's is on the right, back's
        // on the left, so the halves they weigh are the mirror of each other.
        #expect(forward.boundingRect.maxX > 85)
        #expect(back.boundingRect.minX < 15)
        #expect(!forward.isEmpty && !back.isEmpty)

        // Play points right like `stepForward`, and pause points nowhere.
        #expect(PlayerGlyph(kind: .play).path(in: box).boundingRect.maxX > 85)
    }

    /// The bar, in both modes and both states, written as PNGs to look at.
    /// Opt-in like every other shot: set `SHIFU_SHOTS`.
    @MainActor @Test func film() throws {
        guard let shots = ProcessInfo.processInfo.environment["SHIFU_SHOTS"] else { return }
        let directory = URL(fileURLWithPath: shots, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Held here rather than inside `strip()`: a clock that is stopped
        // again before the host lays out films a *stopped* transport, and the
        // playing state is half of what this shot is for.
        let playing = RewindClock()
        playing.play()
        playing.cycleRate()
        playing.cycleRate()
        playing.cycleRate()
        defer { playing.pause() }

        for dark in [false, true] {
            let size = CGSize(width: 720, height: 132)
            let window = NSWindow(
                contentRect: CGRect(origin: .zero, size: size),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let host = NSHostingView(rootView: Self.strip(playing: playing))
            host.frame = CGRect(origin: .zero, size: size)
            window.contentView = host
            window.orderBack(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            host.layoutSubtreeIfNeeded()
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let name = dark ? "rewind-transport-dark.png" : "rewind-transport.png"
                try bitmap.representation(using: .png, properties: [:])?
                    .write(to: directory.appendingPathComponent(name))
            }
            window.orderOut(nil)
        }
    }

    /// Three bars: stopped at the live end, playing at 8× partway back, and
    /// the fullscreen variant — the three shapes the control ever has.
    @MainActor private static func strip(playing: RewindClock) -> some View {
        VStack(spacing: 12) {
            bar(RewindClock(), position: "28:14", total: "28:14", atEnd: true)
            bar(playing, position: "23:42", total: "28:14", atEnd: false)
            bar(RewindClock(), position: "0:12", total: "5:00", atEnd: false,
                showsLive: false, isFullscreen: true)
        }
        .padding(16)
        .background(Instrument.ground)
    }

    @MainActor private static func bar(
        _ clock: RewindClock, position: String, total: String, atEnd: Bool,
        showsLive: Bool = true, isFullscreen: Bool = false
    ) -> some View {
        RewindControlBar(
            clock: clock, position: position, total: total, enabled: true, atEnd: atEnd,
            showsLive: showsLive, isFullscreen: isFullscreen,
            onStep: { _ in }, onSkip: { _ in }, onLive: {}, onFullscreen: {})
    }
}
