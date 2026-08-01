import AppKit
import Foundation
import ShifuCore
import SwiftUI
import Testing
@testable import ShifuApp

/// The menu bar item is the one surface `WindowShots` can never film: it is
/// drawn by the system, outside any window this process owns. What *is*
/// checkable is the thing handed to it — one template `NSImage` per reading —
/// so this suite measures that image, and (under `SHIFU_SHOTS`) composites it
/// over both bars so the result can be read rather than reasoned about.
///
///     SHIFU_SHOTS=/tmp/shifu-shots swift test --filter MenuBarShots
@Suite struct MenuBarShots {
    /// Menu bar height is the one dimension that isn't ours to choose: an item
    /// taller than the bar is clipped, and clipping the ridge is what a badge
    /// would have looked like.
    @MainActor @Test func theStopwatchRidesAtMarkHeight() throws {
        let bare = try #require(MenuBarMark.image(paused: false))
        let timed = try #require(MenuBarMark.image(paused: false, stopwatch: "12:04"))
        #expect(timed.size.height == bare.size.height)
        #expect(timed.isTemplate)
        // Template, so AppKit tints it — the digits invert with the ridge when
        // the item is pressed instead of staying stubbornly one colour.
        #expect(timed.size.width > bare.size.width)
    }

    /// Tabular figures earn their keep here: an item that changed width on
    /// every rolling second would shove every other menu bar item left and
    /// right once a second, all day.
    @MainActor @Test func rollingSecondsDoNotMoveTheBar() throws {
        let early = try #require(MenuBarMark.image(paused: false, stopwatch: "12:04"))
        let width = early.size.width
        let later = try #require(MenuBarMark.image(paused: false, stopwatch: "12:38"))
        #expect(later.size.width == width)
        // Past the hour it *must* grow — that reading is three fields wide,
        // and squeezing it into the same box would mean dropping a digit.
        let hours = try #require(MenuBarMark.image(paused: false, stopwatch: "1:12:38"))
        #expect(hours.size.width > width)
    }

    /// One slot, replaced per tick: the reading changes every second, so a
    /// cache keyed by state would grow an entry a second for the launch.
    @MainActor @Test func theTimedMarkKeepsOnlyTheCurrentReading() throws {
        let first = try #require(MenuBarMark.image(paused: false, stopwatch: "3:00"))
        #expect(try #require(MenuBarMark.image(paused: false, stopwatch: "3:00")) === first)
        _ = MenuBarMark.image(paused: false, stopwatch: "3:01")
        #expect(try #require(MenuBarMark.image(paused: false, stopwatch: "3:00")) !== first)
    }

    /// The film: every state the item can be in, over both bars.
    @MainActor @Test func everyReading() throws {
        guard let raw = ProcessInfo.processInfo.environment["SHIFU_SHOTS"] else { return }
        let directory = URL(fileURLWithPath: raw, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)

        let readings: [(name: String, image: NSImage?)] = [
            ("watching", MenuBarMark.image(paused: false)),
            ("resting", MenuBarMark.image(paused: true)),
            ("focus-fresh", MenuBarMark.image(paused: false, stopwatch: "0:07")),
            ("focus-minutes", MenuBarMark.image(paused: false, stopwatch: "12:04")),
            ("focus-hours", MenuBarMark.image(paused: false, stopwatch: "3:24:11")),
            ("focus-paused", MenuBarMark.image(paused: true, stopwatch: "12:04"))
        ]
        for dark in [false, true] {
            shoot(
                strip(readings, dark: dark), dark: dark,
                to: directory.appendingPathComponent(
                    "menubar-\(dark ? "dark" : "light").png"))
        }
    }

    /// The bar, roughly: the items right-aligned against a 22 pt strip, with
    /// the system clock's own reading at the end for scale — the whole
    /// question about the stopwatch's size is how it sits next to that.
    ///
    /// The backdrop is painted rather than left to the window: a borderless
    /// `NSWindow` is white whatever its appearance, and a dark-mode shot of
    /// white ink on it is a blank page.
    @MainActor private func strip(
        _ readings: [(name: String, image: NSImage?)], dark: Bool
    ) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            ForEach(readings, id: \.name) { reading in
                HStack(spacing: 12) {
                    Text(reading.name)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let image = reading.image {
                        Image(nsImage: image)
                    }
                    Text("Thu 1 Aug  9:41 AM")
                        .font(.system(size: 13))
                }
                .frame(height: 22)
                .padding(.horizontal, 10)
            }
        }
        .frame(width: 520)
        .padding(.vertical, 8)
        // Not black: a real menu bar is translucent over a wallpaper, and the
        // grey is where a thin stroke is hardest to keep.
        .background(dark ? Color(white: 0.18) : Color(white: 0.97))
    }

    @MainActor private func shoot(_ view: some View, dark: Bool, to url: URL) {
        let size = CGSize(width: 520, height: 160)
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: size)
        window.contentView = host
        window.orderBack(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        host.layoutSubtreeIfNeeded()

        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
        window.orderOut(nil)
    }
}
