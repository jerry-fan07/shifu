import AppKit
import Testing
@testable import ShifuApp

/// Who owns an escape while the menu bar panel is up.
///
/// The keystroke itself can't be filmed — the status item is SwiftUI's own and
/// no test can click it — but the decision it hangs on can be, and every wrong
/// answer here is a bug someone would feel: swallowing escape in the dashboard,
/// or closing a panel that isn't showing.
@Suite struct MenuBarEscapeTests {
    @MainActor private func window() -> NSWindow {
        NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 300, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
    }

    @MainActor @Test func escapeInTheOpenPanelCloses() {
        let panel = window()
        panel.orderBack(nil)
        defer { panel.orderOut(nil) }

        #expect(MenuBarEscape.closes(
            keyCode: MenuBarEscape.escapeKey, eventWindow: panel, panel: panel))
        // Undirected: the panel doesn't activate the app, so a key press with
        // no window of ours attached still belongs to it.
        #expect(MenuBarEscape.closes(
            keyCode: MenuBarEscape.escapeKey, eventWindow: nil, panel: panel))
    }

    @MainActor @Test func escapeElsewhereIsLeftAlone() {
        let panel = window()
        let dashboard = window()
        panel.orderBack(nil)
        defer {
            panel.orderOut(nil)
            dashboard.orderOut(nil)
        }

        // Another window's escape — the fullscreen player's exit, a sheet's
        // cancel — must pass straight through the monitor.
        #expect(!MenuBarEscape.closes(
            keyCode: MenuBarEscape.escapeKey, eventWindow: dashboard, panel: panel))
        // And no other key closes anything.
        #expect(!MenuBarEscape.closes(keyCode: 36, eventWindow: panel, panel: panel))
    }

    @MainActor @Test func aClosedPanelStaysOutOfIt() {
        let panel = window()
        #expect(!panel.isVisible)
        #expect(!MenuBarEscape.closes(
            keyCode: MenuBarEscape.escapeKey, eventWindow: nil, panel: panel))
        #expect(!MenuBarEscape.closes(
            keyCode: MenuBarEscape.escapeKey, eventWindow: nil, panel: nil))
    }
}
