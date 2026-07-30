import AppKit
import Foundation
import SwiftUI
import Testing
@testable import ShifuApp

/// The drop-down opens, closes, and is worth looking at.
///
/// It is the one control AppKit doesn't draw for us — a panel in a child
/// window, opened by a tap and closed by a click anywhere else — so the
/// open/close dance is driven here with real events. `SHIFU_SHOTS` also
/// writes what it drew: the panel is a window of its own, so the composite in
/// `WindowShots` never contains it.
///
/// Opt-in like `WindowShots`, and for a sharper reason: driving a click means
/// activating this process, which takes the focus off whatever you are doing.
///
///     SHIFU_SHOTS=/tmp/shifu-shots swift test --filter DropdownShots
@Suite struct DropdownShots {
    private static var outputDirectory: URL? {
        ProcessInfo.processInfo.environment["SHIFU_SHOTS"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
    }

    private struct Bench: View {
        let entries: [DropdownEntry]

        var body: some View {
            HStack(spacing: 8) {
                DropdownButton(label: "Sort: this week", entries: entries)
                DropdownButton(label: "New deck", entries: entries)
                Spacer()
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Instrument.ground)
        }
    }

    private static let benchSize = CGSize(width: 520, height: 420)
    /// The first pill's own middle, in window coordinates.
    private static let pill = CGPoint(x: 60, y: benchSize.height - 32)
    /// Empty page, well clear of both pills.
    private static let elsewhere = CGPoint(x: 300, y: 200)

    /// One test, not two: each drives this process's event queue and pumps
    /// its runloop, and a second one in the same process never gets to run.
    @MainActor @Test func opensClosesAndDraws() throws {
        guard let directory = Self.outputDirectory else { return }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)

        let short = ["this week", "all time", "last touched"]
        let long = ["All notes"] + (1...24).map { "Deck · a long-ish deck title \($0)" }
        for (name, labels, dark) in [
            ("dropdown-short", short, false), ("dropdown-long", long, true)
        ] {
            let entries = labels.enumerated().map { index, label in
                DropdownEntry(label, isOn: index == 1) {}
            }
            let window = hostWindow(Bench(entries: entries), dark: dark)
            defer { window.orderOut(nil) }

            #expect(window.childWindows?.isEmpty ?? true, "closed until it is clicked")
            click(Self.pill, in: window)
            #expect(window.childWindows?.count == 1, "a click on the pill opens the panel")
            shoot(window, to: directory.appendingPathComponent("\(name).png"))

            click(Self.elsewhere, in: window)
            #expect(window.childWindows?.isEmpty ?? true, "a click off it closes the panel")

            // The pill closes what it opened: that one click must not be read
            // as a dismissal followed by a fresh open.
            click(Self.pill, in: window)
            click(Self.pill, in: window)
            #expect(window.childWindows?.isEmpty ?? true, "clicking the pill again closes it")
        }
    }

    // MARK: - Driving a real window

    @MainActor private func hostWindow(_ view: some View, dark: Bool) -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: 300, y: 300), size: Self.benchSize),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view)
        window.contentView = host
        // An inactive process's window is clicked *to* activate it, and that
        // click never reaches the gesture.
        NSApp.setActivationPolicy(.accessory)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let deadline = Date().addingTimeInterval(3)
        while !window.isKeyWindow, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        return window
    }

    /// A click, down and up, pumped through `NSApp` — SwiftUI's tap gesture
    /// and the panel's own event monitor both hang off that dispatch, and
    /// neither sees an event handed straight to the window.
    @MainActor private func click(_ point: CGPoint, in window: NSWindow) {
        for phase in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: phase, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                clickCount: 1, pressure: phase == .leftMouseDown ? 1 : 0)
            else { continue }
            NSApp.postEvent(event, atStart: false)
        }
        let deadline = Date().addingTimeInterval(0.35)
        while let event = NSApp.nextEvent(
            matching: .any, until: deadline, inMode: .default, dequeue: true) {
            NSApp.sendEvent(event)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
    }

    /// The window and whatever hangs off it, in one image.
    @MainActor private func shoot(_ window: NSWindow, to url: URL) {
        guard let host = window.contentView,
              let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)
        else { return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let image = NSImage(size: host.bounds.size)
        image.addRepresentation(bitmap)
        image.lockFocus()
        for child in window.childWindows ?? [] {
            guard let content = child.contentView,
                  let shot = content.bitmapImageRepForCachingDisplay(in: content.bounds)
            else { continue }
            content.cacheDisplay(in: content.bounds, to: shot)
            shot.draw(
                in: CGRect(
                    origin: window.convertPoint(fromScreen: child.frame.origin),
                    size: content.bounds.size),
                from: .zero, operation: .sourceOver, fraction: 1,
                respectFlipped: true, hints: nil)
        }
        image.unlockFocus()
        guard let data = image.tiffRepresentation,
              let composite = NSBitmapImageRep(data: data)
        else { return }
        try? composite.representation(using: .png, properties: [:])?.write(to: url)
    }
}
