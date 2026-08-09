import AppKit
import Foundation
import ShifuCore
import SwiftUI
import Testing
@testable import ShifuApp

/// The fullscreen player's window and composition.
///
/// The window config is asserted because every line of it is a decision with a
/// failure mode: a borderless window that can't be key strands escape, one
/// that releases on close crashes the second exit, and snip-overlay levels
/// would park the player above every app on every Space. The composition is
/// *filmed* — it lives in a second window, so no `WindowShots` composite of
/// the main window can ever catch it.
@Suite struct RewindFullscreenTests {
    @MainActor @Test func windowIsAKeyablePlayerNotAnOverlay() {
        let frame = CGRect(x: 0, y: 0, width: 1_512, height: 982)
        let window = FullscreenPlayerWindow.make(frame: frame)
        defer { window.orderOut(nil) }

        #expect(window.frame == frame)
        #expect(window.canBecomeKey)
        #expect(!window.isReleasedWhenClosed)
        #expect(!window.styleMask.contains(.titled))
        // A player is an ordinary window: ⌘-tab must leave it behind. The
        // snip overlay's `.screenSaver` would not.
        #expect(window.level == .normal)
    }

    /// The fullscreen composition against real footage, written as a PNG to
    /// look at. Same camera and same opt-in as `WindowShots`: point
    /// `SHIFU_HOME` at a copy of ~/Shifu and set `SHIFU_SHOTS`.
    @MainActor @Test func composition() throws {
        guard let shots = ProcessInfo.processInfo.environment["SHIFU_SHOTS"] else { return }
        let directory = URL(fileURLWithPath: shots, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)

        // A screen-sized film, not the window default: fullscreen is the one
        // surface whose aspect is the display's own.
        let size = CGSize(width: 1_512, height: 982)
        // Both states, because "the bar is gone" is a claim about the *frame*
        // — the bottom eighth the controls were covering has to actually be
        // there in the second pair, not black.
        for (hidden, dark) in [(false, false), (false, true), (true, false), (true, true)] {
            let window = NSWindow(
                contentRect: CGRect(origin: .zero, size: size),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let host = NSHostingView(rootView: Self.player(chromeHidden: hidden))
            host.frame = CGRect(origin: .zero, size: size)
            window.contentView = host
            window.orderBack(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            host.layoutSubtreeIfNeeded()
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let name = "rewind-fullscreen\(hidden ? "-bare" : "")\(dark ? "-dark" : "").png"
                try bitmap.representation(using: .png, properties: [:])?
                    .write(to: directory.appendingPathComponent(name))
            }
            window.orderOut(nil)
        }
    }

    /// The page's own bar is private page state; the film needs the shape —
    /// footage edge to edge, the rail and the *player's* transport over its
    /// foot, the exit chip in the corner — not the page's exact wiring. The
    /// control bar is the real one, so a transport that stops looking like a
    /// player shows up in the shot.
    @MainActor private static func player(chromeHidden: Bool) -> some View {
        let chrome = FullscreenChrome()
        // Toggled rather than left to the idle watch: the film wants the state,
        // not the two and a half seconds of waiting for it.
        if chromeHidden { chrome.toggle() }
        let store = LedgerStore()
        store.refreshRewind()
        let frames = store.rewindFrames
        let frame = frames.last
        let span = RewindTimeline.span(
            now: Int64(Date().timeIntervalSince1970 * 1_000), settings: store.rewindSettings)
        let footage = (frames.last?.capturedAt ?? 0) - (frames.first?.capturedAt ?? 0)
        return RewindFullscreenPlayer(
            frame: frame,
            caption: frame.map { "\($0.width) × \($0.height)" },
            // Never `begin()`-ed: the idle watch is `FullscreenChromeTests`,
            // and a bar that hid itself mid-exposure would film as neither
            // state.
            chrome: chrome,
            onExit: {},
            bar: {
                RewindRail(
                    bands: RewindTimeline.bands(frames: frames, span: span),
                    marks: [], taskBands: [],
                    ticks: RewindTimeline.ticks(span: span),
                    fidelity: store.rewindSettings.fidelityLine,
                    playhead: 1, onScrub: { _ in })
                RewindControlBar(
                    clock: RewindClock(),
                    // Position in the footage, like the page's — the wall
                    // clock lives on the frame line, not on the transport.
                    position: RewindPlayback.duration(ms: footage),
                    total: RewindPlayback.duration(ms: footage),
                    enabled: !frames.isEmpty, atEnd: true, showsLive: true,
                    isFullscreen: true,
                    onStep: { _ in }, onSkip: { _ in }, onLive: {}, onFullscreen: {})
            })
    }
}
