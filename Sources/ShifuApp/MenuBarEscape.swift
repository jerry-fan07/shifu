import AppKit
import SwiftUI

// Escape closes the menu bar panel (design.md §7).
//
// `.menuBarExtraStyle(.window)` hands the panel a window of its own rather than
// an NSMenu, and that window has no responder that reads escape as "cancel" —
// it only goes away when you click somewhere else. Every other panel Shifu
// draws (the drop-down, the fullscreen player, the snip overlay) closes on
// escape, so this one has to as well.

/// Whether an escape belongs to the menu bar panel — the whole decision, in one
/// place a test can hold to the light.
enum MenuBarEscape {
    static let escapeKey: UInt16 = 53

    /// True when the panel is up and the keystroke isn't addressed to some
    /// other window of ours. A local monitor sees every key the app gets, so
    /// without the window check this would eat escape in the dashboard and the
    /// Review window too. `nil` counts as the panel's: the panel doesn't
    /// activate the app, so an undirected key press while it is the only thing
    /// showing can only have been meant for it.
    @MainActor static func closes(
        keyCode: UInt16, eventWindow: NSWindow?, panel: NSWindow?
    ) -> Bool {
        guard keyCode == escapeKey, let panel, panel.isVisible else { return false }
        return eventWindow == nil || eventWindow === panel
    }
}

/// A zero-sized view that gives the panel's content a handle on the window it
/// is drawn in — the same trick `RewindFullscreen` and `WindowCloseGuard` play
/// — and watches that window's keys for escape.
///
/// It closes the panel with the environment's `dismiss`, not by closing the
/// window: SwiftUI owns whether the panel is presented, and taking the window
/// down behind its back leaves it believing the panel is still up. Measured —
/// closing the window directly costs a click roughly every other time you next
/// reach for the menu bar, while `dismiss` reopened cleanly nine times out of
/// nine.
struct MenuBarEscapeCloser: NSViewRepresentable {
    let dismiss: DismissAction

    func makeNSView(context: Context) -> NSView {
        let view = EscapeAnchorView()
        context.coordinator.anchor = view
        context.coordinator.dismiss = dismiss
        context.coordinator.watch()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.dismiss = dismiss
        // Also here, not only in `makeNSView`: SwiftUI may keep this view
        // across opens of the panel, and a torn-down monitor has to come back.
        context.coordinator.watch()
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.tearDown()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor final class Coordinator {
        weak var anchor: NSView?
        var dismiss: DismissAction?
        private var monitor: Any?

        /// One monitor at a time — installing per open would stack them. The
        /// `isVisible` check in `closes` covers the gap between opens.
        func watch() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self,
                    MenuBarEscape.closes(
                        keyCode: event.keyCode, eventWindow: event.window,
                        panel: self.anchor?.window)
                else { return event }
                self.dismiss?()
                return nil
            }
        }

        func tearDown() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

/// Never takes a click — the menu lines above it do.
private final class EscapeAnchorView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
