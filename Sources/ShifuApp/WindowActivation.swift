import AppKit

// Menu bar app with real windows (design.md §7): LSUIElement=true starts the
// app as `.accessory` (no Dock icon), but that policy also breaks activation
// when a window is raised from Mission Control — the previously active app
// stays active and reclaims focus once Mission Control dismisses. Ice/Stats
// and friends handle this by flipping the activation policy dynamically:
// `.regular` while a real window is visible (accepting the transient Dock
// icon as the trade-off — it also restores Cmd-Tab), back to `.accessory`
// once the last one closes.
@MainActor
final class WindowActivationController: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = NotificationCenter.default
        // willClose fires while the window still reports visible, so recount
        // on the next runloop turn after the window actually disappears.
        center.addObserver(
            self, selector: #selector(windowClosed),
            name: NSWindow.willCloseNotification, object: nil)
        center.addObserver(
            self, selector: #selector(windowBecameMain),
            name: NSWindow.didBecomeMainNotification, object: nil)
        center.addObserver(
            self, selector: #selector(windowOcclusionChanged),
            name: NSWindow.didChangeOcclusionStateNotification, object: nil)
    }

    @objc
    private func windowClosed(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.recount()
        }
    }

    // Occlusion state changes in both directions (shown *and* hidden behind
    // another window) — only recount here, never activate, or switching away
    // to an overlapping app would immediately yank focus back to Shifu.
    @objc
    private func windowOcclusionChanged(_ notification: Notification) {
        recount()
    }

    // becomeMain only fires when this window is gaining focus, so it's safe
    // to claim activation here — covers the Mission Control path, where a
    // window can be raised without transferring app activation.
    @objc
    private func windowBecameMain(_ notification: Notification) {
        recount()
        if let window = notification.object as? NSWindow,
            window.styleMask.contains(.titled), !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func recount() {
        // MenuBarExtra keeps an always-visible borderless NSStatusBarWindow
        // in NSApp.windows; excluding non-titled windows keeps that one from
        // pinning the app to `.regular` forever.
        let hasVisibleWindow = NSApp.windows.contains {
            $0.styleMask.contains(.titled) && $0.isVisible
        }
        NSApp.setActivationPolicy(hasVisibleWindow ? .regular : .accessory)
    }
}
