import AppKit
import Foundation
import SwiftUI
import Testing
@testable import ShifuApp

/// A click on a page's blank space lets go of whatever field held the
/// cursor. `PageBody`'s `FocusReliever` is the fix — before it, a click that
/// missed every row's own control did nothing, and the field editor stayed
/// first responder with its cursor blinking until another field claimed it.
@Suite struct FocusReliefTests {
    private struct Bench: View {
        @State private var text = "https://shifu-cloud.shifuapp.dev"

        var body: some View {
            PageBody {
                SettingField(placeholder: "endpoint", text: $text)
                    .frame(width: 200)
            }
        }
    }

    private static let benchSize = CGSize(width: 520, height: 420)
    /// Well clear of the field, in the page's empty run.
    private static let blank = CGPoint(x: 260, y: 120)

    @MainActor @Test func blankClickResignsTheFieldEditor() throws {
        let window = hostWindow(Bench())
        defer { window.orderOut(nil) }

        let fieldView = try #require(
            findTextField(in: window.contentView), "the bench has a text field")
        let fieldCenter = fieldView.convert(
            CGPoint(x: fieldView.bounds.midX, y: fieldView.bounds.midY), to: nil)
        click(fieldCenter, in: window)
        let editor = try #require(
            window.firstResponder as? NSText, "clicking the field gives it the cursor")
        #expect(editor.isKind(of: NSTextView.self))

        click(Self.blank, in: window)
        #expect(
            !(window.firstResponder is NSText),
            "clicking blank page space lets go of the field editor")
    }

    /// SwiftUI's `TextField` on macOS backs onto a real `NSTextField`, so the
    /// exact point to click is wherever layout actually put it — not a
    /// guess from padding constants that drift.
    private func findTextField(in view: NSView?) -> NSView? {
        guard let view else { return nil }
        if view is NSTextField { return view }
        for subview in view.subviews {
            if let match = findTextField(in: subview) { return match }
        }
        return nil
    }

    // MARK: - Driving a real window

    @MainActor private func hostWindow(_ view: some View) -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: 300, y: 300), size: Self.benchSize),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        let host = NSHostingView(rootView: view)
        window.contentView = host
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
}
