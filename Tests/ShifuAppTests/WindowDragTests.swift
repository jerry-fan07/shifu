import AppKit
import Foundation
import ShifuCore
import SwiftUI
import Testing
@testable import ShifuApp

/// The title bar is the window's handle, and `.hiddenTitleBar` only leaves the
/// system's own strip draggable — 28 pt, where the bar you can see is 40. So
/// the bar carries a `WindowDragArea`, and the thing worth checking is what a
/// press actually lands on: hit testing is what decides whether the drag
/// happens, and it is the one part of this that can silently stop working when
/// something else is laid over the bar.
///
/// Hosted in a window built the way `.hiddenTitleBar` builds one, so the
/// traffic lights are really there to be shadowed.
@Suite struct WindowDragTests {
    private static let size = CGSize(width: 1_180, height: 760)

    @MainActor @Test func theWholeBarIsAHandle() {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("shifu-drag-\(getpid())", isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        setenv("SHIFU_HOME", home.path, 1)
        defer {
            unsetenv("SHIFU_HOME")
            try? FileManager.default.removeItem(at: home)
        }
        let onboarded = UserDefaults.standard.object(forKey: "shifu.onboarded")
        UserDefaults.standard.set(true, forKey: "shifu.onboarded")
        defer { UserDefaults.standard.set(onboarded, forKey: "shifu.onboarded") }

        let window = hostedWindow(view: MainWindow().environmentObject(LedgerStore()))
        defer { window.orderOut(nil) }
        // From the frame view, which is where a real press starts: the top
        // 28 pt of the window are also the system's own title bar view, and
        // this is the only way to see that it hands the press through.
        let frame = window.contentView!.superview!

        // Across the bar's width and through its depth — including the band
        // below the system's 28 pt strip, which is the part that used to
        // refuse the drag. Starting 3 pt in: the outermost couple of points
        // are the window's resize edge on every macOS window, checked below.
        let bar = Instrument.titleBarHeight
        for across in [90.0, 300.0, Self.size.width / 2, Self.size.width - 40] {
            for depth in [3.0, bar / 2, bar - 1] {
                let point = CGPoint(x: across, y: Self.size.height - depth)
                #expect(
                    frame.hitTest(point) is WindowDragView,
                    "no handle \(Int(depth)) pt down the bar at x=\(Int(across))")
            }
        }

        // The window's own edge stays the window's own edge: the top hairline
        // resizes, as it does everywhere else, and never starts a drag.
        let topEdge = CGPoint(x: Self.size.width / 2, y: Self.size.height - 1)
        #expect(!(frame.hitTest(topEdge) is WindowDragView))

        // A point below the bar is the page, and the page is not a handle —
        // otherwise selecting a row would throw the window across the desk.
        let belowTheBar = CGPoint(x: Self.size.width / 2, y: Self.size.height - bar - 4)
        #expect(!(frame.hitTest(belowTheBar) is WindowDragView))
    }

    /// First run draws no bar, so it needs saying separately: the window is
    /// still movable before onboarding finishes.
    @MainActor @Test func firstRunCanStillBeMoved() {
        let window = hostedWindow(view: OnboardingView())
        defer { window.orderOut(nil) }
        let frame = window.contentView!.superview!

        let point = CGPoint(
            x: Self.size.width / 2,
            y: Self.size.height - Instrument.titleBarHeight / 2)
        #expect(frame.hitTest(point) is WindowDragView)
    }

    /// The handle must not shadow the traffic lights: they sit in the window's
    /// own title bar view, above the content, and a press on one has to reach
    /// the button rather than start a drag.
    @MainActor @Test func theTrafficLightsKeepTheirClicks() {
        let window = hostedWindow(view: Color.clear.overlay(WindowDragArea()))
        defer { window.orderOut(nil) }
        let frame = window.contentView!.superview!

        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let light = window.standardWindowButton(button) else {
                Issue.record("no \(button) on the window")
                continue
            }
            let centre = light.convert(
                CGPoint(x: light.bounds.midX, y: light.bounds.midY), to: nil)
            #expect(frame.hitTest(centre) === light, "\(button) is shadowed")
        }
    }

    /// A window built the way SwiftUI's `.hiddenTitleBar` builds one: titled,
    /// so the traffic lights exist, with the content run up under them.
    @MainActor private func hostedWindow(view: some View) -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: Self.size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        let host = NSHostingView(rootView: view)
        // `.hiddenTitleBar` runs the content to the top of the window — the
        // traffic lights float over the bar rather than reserving a strip
        // above it, which is why the bar is padded clear of them. A hosting
        // view left to itself would inset the content instead, and then this
        // would be measuring a window nobody has.
        host.safeAreaRegions = []
        host.frame = CGRect(origin: .zero, size: Self.size)
        window.contentView = host
        window.orderBack(nil)
        host.layoutSubtreeIfNeeded()
        return window
    }
}
