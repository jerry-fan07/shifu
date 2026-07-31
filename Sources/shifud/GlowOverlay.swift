import AppKit
import CoreGraphics
import CoreImage
import ScreenCaptureKit

/// The glow pulse (design.md §4.4): a full-screen, click-through overlay that
/// breathes a soft colored vignette at the edges of every screen for ~2 s,
/// then fades, with a translucent motivational line on the screen the user is
/// working on. The line's shade (black↔white) is picked from that display's
/// current average brightness, sampled once per pulse via ScreenCaptureKit
/// (same Screen Recording grant as the OCR rung, §3.2) — never persisted.
///
/// Two structural choices guard the pulse against the daemon's own workload:
///
/// - **Opacity animates on layers, not windows.** `NSWindow.animator()` needs
///   the main thread for every frame, and the capture ladder blocks that
///   thread with synchronous AX round-trips exactly when a pulse fires — a
///   pulse means the user is active in an off-task app, so captures are
///   streaming in. Core Animation commits once and renders out-of-process,
///   staying smooth through those stalls.
/// - **The lifecycle is wall-clock scheduled, not completion-chained.** Every
///   phase is a cancellable work item and `teardown()` is idempotent, so the
///   worst case for a stalled phase is a late fade — never windows latched on
///   screen with `isPulsing` stuck true, silently swallowing every future
///   pulse for the daemon's life.
///
/// A screen-layout change mid-pulse (wake, hotplug) dismisses the overlay
/// outright: the windows were sized for a snapshot of the layout, and AppKit
/// would otherwise migrate a dead display's window onto a surviving screen,
/// misaligned.
@MainActor
final class GlowOverlay: NSObject {
    static let message = "Believe in yourself"

    // Breathe in, hold at peak, breathe out — the hold is what makes the
    // velocity reversal read as a breath, not a corner.
    private static let breatheIn: TimeInterval = 1.6
    private static let hold: TimeInterval = 0.4
    private static let breatheOut: TimeInterval = 2.4
    private static let messageFade: TimeInterval = 0.8
    /// Teardown slack past the last animation frame, so cleanup never races
    /// the fade it follows.
    private static let teardownSlack: TimeInterval = 0.2
    /// How often to re-check for Mission Control across an in-flight pulse
    /// (§4.4). Only ever paid during a pulse, never on the idle path (§3.4).
    private static let missionControlCheckInterval: TimeInterval = 1.0

    private var windows: [NSWindow] = []
    private var messageLabel: NSTextField?
    private var phaseWork: [DispatchWorkItem] = []
    private var isPulsing = false

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
    }

    /// AppKit posts this on the main thread; the class is @MainActor.
    @objc private func screenParametersChanged() {
        teardown()
    }

    /// Fires the pulse, returning whether an overlay was actually shown.
    ///
    /// Skips (returns false) when Mission Control — a Dock full-screen overlay
    /// (also App Exposé / Launchpad) — is on screen: our windows sit at
    /// `.screenSaver` level with `.transient`, which — verified empirically on
    /// this machine — does NOT hide them behind the window picker, so a pulse
    /// would paint the amber vignette + text straight over the Mission Control
    /// UI (§4.4). The false return lets `FocusModeController` leave
    /// `lastPulseAt` untouched, so the next off-task capture (a heartbeat away)
    /// retries the nudge instead of losing it for a whole `pulseSpacing`.
    func pulse() -> Bool {
        guard !isPulsing else { return false }          // one pulse at a time
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return false }    // all displays gone: skip, don't latch
        guard !Self.missionControlActive() else {
            log("focus mode: glow pulse skipped — Mission Control active")
            return false
        }
        isPulsing = true

        let messageScreen = Self.screenUnderPointer(in: screens)
        for screen in screens {
            let window = makeOverlayWindow(for: screen, withMessage: screen === messageScreen)
            windows.append(window)
            window.orderFrontRegardless()
            // Force the vignette's (software) first draw now, so the ramp's
            // first frame presents real content instead of the gradient
            // popping in mid-fade once a busy main thread gets to it.
            window.displayIfNeeded()
            if let contentView = window.contentView {
                Self.fade(contentView, to: 1, over: Self.breatheIn)
            }
        }
        revealMessage(on: messageScreen)

        schedule(after: Self.breatheIn + Self.hold) { overlay in
            for window in overlay.windows {
                if let contentView = window.contentView {
                    Self.fade(contentView, to: 0, over: Self.breatheOut)
                }
            }
        }
        // Both the normal cleanup and the failsafe: wall-clock scheduled,
        // independent of any animation or earlier phase actually completing.
        schedule(after: Self.breatheIn + Self.hold + Self.breatheOut + Self.teardownSlack) {
            $0.teardown()
        }

        // Mission Control can also appear *mid-pulse* (the user hits F3 while
        // the vignette breathes), and our overlay draws on top of it (§4.4).
        // Poll a few times across the pulse and tear down the moment it does —
        // reusing the phase mechanism, so `teardown()` cancels the remaining
        // checks and only the first to detect it logs. No standing timer: the
        // cost is paid only while a pulse is live (§3.4 idle budget).
        for tick in stride(from: Self.missionControlCheckInterval,
                           to: Self.breatheIn + Self.hold + Self.breatheOut,
                           by: Self.missionControlCheckInterval) {
            schedule(after: tick) { overlay in
                guard overlay.isPulsing, Self.missionControlActive() else { return }
                log("focus mode: glow pulse dismissed — Mission Control appeared")
                overlay.teardown()
            }
        }
        return true
    }

    /// True while a Dock-owned full-screen overlay — Mission Control, and also
    /// App Exposé / Launchpad, all rendered by the Dock process — is on screen.
    /// Verified empirically on this machine: with Mission Control up, an
    /// on-screen window owned by "Dock" appears at layer 18 (the real Dock sits
    /// at layer 20) spanning the full display (e.g. 1512×982), and vanishes on
    /// dismiss. The window name is nil without a Screen Recording grant, so we
    /// key on owner + layer + size, never the name — unreadable metadata simply
    /// reads as false (pulse as usual), never a permanent block. Mission
    /// Control posts no NSNotification in our process, so polling the window
    /// list is the only available signal (§4.4).
    private static func missionControlActive() -> Bool {
        guard let infoList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return false }
        for info in infoList {
            guard (info[kCGWindowOwnerName as String] as? String) == "Dock" else { continue }
            let layer = info[kCGWindowLayer as String] as? Int ?? .max
            guard layer > 0, layer < 20 else { continue }   // below the real Dock (layer 20)
            guard let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let width = bounds["Width"] as? Double,
                  let height = bounds["Height"] as? Double else { continue }
            if width > 200, height > 200 { return true }     // full-screen backdrop
        }
        return false
    }

    /// Dismisses an in-flight pulse immediately; no-op when idle. Called when
    /// Focus Mode switches off — a nudge shouldn't outlive the contract.
    func dismiss() {
        teardown()
    }

    // MARK: - Lifecycle

    /// Idempotent: cancels pending phases, drops the windows, releases the
    /// `isPulsing` latch. Safe from any phase, `dismiss()`, or the
    /// screen-change observer, in any order, any number of times.
    private func teardown() {
        for item in phaseWork { item.cancel() }
        phaseWork = []
        for window in windows { window.orderOut(nil) }
        windows = []
        messageLabel = nil
        isPulsing = false
    }

    /// Runs `body` on the main actor after `delay`, tracked so `teardown()`
    /// can cancel it.
    private func schedule(after delay: TimeInterval, _ body: @escaping @MainActor (GlowOverlay) -> Void) {
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                body(self)
            }
        }
        phaseWork.append(item)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    // MARK: - Windows

    private func makeOverlayWindow(for screen: NSScreen, withMessage: Bool) -> NSWindow {
        let window = NSWindow(
            contentRect: screen.frame, styleMask: .borderless,
            backing: .buffered, defer: false
        )
        window.level = .screenSaver
        window.ignoresMouseEvents = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        // Window-local coordinates: origin .zero, not the screen's global origin.
        let contentView = VignetteView(frame: NSRect(origin: .zero, size: screen.frame.size))
        contentView.wantsLayer = true   // CA-driven opacity — see the type comment
        if withMessage {
            let label = makeMessageLabel(for: screen)
            contentView.addSubview(label)
            messageLabel = label
        }
        window.contentView = contentView
        contentView.alphaValue = 0
        return window
    }

    private func makeMessageLabel(for screen: NSScreen) -> NSTextField {
        let label = NSTextField(labelWithString: Self.message)
        // ≈84 pt on a 14" MacBook Pro, scaling with the display instead of
        // overflowing small screens or shrinking into large ones.
        label.font = .systemFont(ofSize: screen.frame.width / 18, weight: .medium)
        label.textColor = .white   // provisional; the sampled shade lands before reveal
        label.alignment = .center
        label.sizeToFit()
        label.wantsLayer = true
        label.alphaValue = 0       // revealed by revealMessage once the shade is known
        // Centered in the visible frame (menu bar and Dock excluded),
        // translated into window-local coordinates.
        let visible = screen.visibleFrame
        let size = label.frame.size
        label.frame = NSRect(
            x: visible.midX - screen.frame.origin.x - size.width / 2,
            y: visible.midY - screen.frame.origin.y - size.height / 2,
            width: size.width, height: size.height
        )
        return label
    }

    /// The message goes on the screen the user is looking at — the one under
    /// the pointer. Not `NSScreen.main`: that tracks the key window, which a
    /// headless accessory daemon never has, so it always degrades to the
    /// primary display no matter where the user works. Matching by identity
    /// (`===`) is sound only within the single `screens` snapshot the pulse
    /// took — AppKit doesn't promise stable `NSScreen` instances across calls.
    private static func screenUnderPointer(in screens: [NSScreen]) -> NSScreen? {
        let pointer = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? screens.first
    }

    /// Explicit Core Animation fade on the view's backing layer: committed
    /// once, then rendered out-of-process, so a stalled main thread can't
    /// drop frames or freeze the ramp. The model value is set through
    /// `alphaValue` (which AppKit mirrors into the layer) so a later layout
    /// pass can't snap the layer back to a stale value.
    private static func fade(_ view: NSView, to target: CGFloat, over duration: TimeInterval) {
        guard let layer = view.layer else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        // Presentation value first: a retarget mid-flight continues from the
        // currently rendered opacity rather than jumping.
        animation.fromValue = layer.presentation()?.opacity ?? layer.opacity
        animation.toValue = Float(target)
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        view.alphaValue = target
        layer.add(animation, forKey: "opacity")
    }

    // MARK: - Message shade (§4.4)

    /// The shade sample is a live ScreenCaptureKit round-trip that can take
    /// up to `luminanceSampleTimeout`, so it must not delay pulse onset: the
    /// vignette starts breathing immediately and the message fades in once
    /// its shade is known — always while the vignette is still ramping, so
    /// the staggered arrival reads as sequencing, not lag.
    private func revealMessage(on screen: NSScreen?) {
        guard messageLabel != nil, let screen else { return }
        let displayID = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? CGDirectDisplayID
        Task {
            let color = await Self.contrastingTextColor(for: displayID)
            // The pulse may have been torn down while the sample ran.
            guard let label = messageLabel, label.window != nil else { return }
            label.textColor = color
            Self.fade(label, to: 1, over: Self.messageFade)
        }
    }

    /// White on a dark background, black on a light one — whichever pole
    /// gives more contrast than any shade in between could. Falls back to
    /// white if the display can't be sampled (e.g. permission not yet
    /// granted) or doesn't answer within `luminanceSampleTimeout`.
    private static func contrastingTextColor(for displayID: CGDirectDisplayID?) async -> NSColor {
        let luminance = await luminanceWithTimeout(displayID: displayID)
        return luminance > 0.5 ? .black : .white
    }

    /// `displayLuminance` depends on the Screen Recording TCC grant and a
    /// live ScreenCaptureKit/XPC round-trip — neither is guaranteed to
    /// return. A pending permission prompt, or the display sleeping or
    /// disconnecting mid-call, can leave the `await` suspended forever.
    /// `try?` only covers a *thrown* failure; it does nothing for a call
    /// that never completes — and an unbounded await here would swallow the
    /// message reveal for the whole pulse.
    ///
    /// So: race the sample against a timer instead of awaiting it directly.
    /// `Task.sleep` resumes on schedule no matter what the sample is doing,
    /// so this always returns within `luminanceSampleTimeout`. Deliberately
    /// not a `TaskGroup` — a group waits for every child to finish, so a
    /// genuinely hung sample would hang the group exactly like the bug
    /// being fixed. The losing side here is abandoned, not cancelled
    /// (ScreenCaptureKit isn't guaranteed to honor cooperative
    /// cancellation) — a hung sample leaks its suspended Task, which is an
    /// accepted trade against the message dying for the pulse.
    private static let luminanceSampleTimeout: Duration = .seconds(1)

    private static func luminanceWithTimeout(displayID: CGDirectDisplayID?) async -> CGFloat {
        await withCheckedContinuation { continuation in
            // Fresh relay per call (not stored on self): a sample that's
            // still hanging from an earlier, already-timed-out pulse must
            // never be able to resolve a *later* pulse's continuation.
            let relay = LuminanceRelay(continuation: continuation)

            Task {
                let sampled = (try? await displayLuminance(displayID)) ?? 0.5
                relay.resume(with: sampled)
            }
            Task {
                try? await Task.sleep(for: luminanceSampleTimeout)
                relay.resume(with: 0.5)
            }
        }
    }

    private static func displayLuminance(_ displayID: CGDirectDisplayID?) async throws -> CGFloat {
        let content = try await SCShareableContent.excludingDesktopWindows(
            true, onScreenWindowsOnly: false
        )
        // Strict match only: sampling some *other* display would pick the
        // shade for a screen the message isn't on. Unmatched (nil ID, or the
        // display vanished mid-reconfiguration) reads as neutral → white.
        guard let display = content.displays.first(where: { $0.displayID == displayID })
        else { return 0.5 }

        let config = SCStreamConfiguration()
        config.width = 32
        config.height = 18
        config.showsCursor = false
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: config
        )
        return averageLuminance(of: image)
    }

    /// Built once and reused across every pulse. Core Image contexts carry
    /// substantial GPU/shader/buffer state and Apple's guidance is to avoid
    /// creating one per render; the render itself (32x18 down to 1 px) is
    /// microseconds, so a fresh context each pulse would dominate the cost
    /// for no benefit. Not a leak either way — the old context deallocated
    /// fine — just wasted setup.
    private static let ciContext = CIContext(options: [.workingColorSpace: NSNull()])

    /// Perceptual (WCAG-weighted) average luminance via Core Image, which
    /// resolves the capture's pixel format for us — no manual byte-order math.
    private static func averageLuminance(of image: CGImage) -> CGFloat {
        let ciImage = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: ciImage,
            kCIInputExtentKey: CIVector(cgRect: ciImage.extent)
        ]), let output = filter.outputImage else { return 0.5 }

        var pixel = [UInt8](repeating: 0, count: 4)
        ciContext.render(
            output, toBitmap: &pixel, rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil
        )
        let red = CGFloat(pixel[0]), green = CGFloat(pixel[1]), blue = CGFloat(pixel[2])
        return (0.2126 * red + 0.7152 * green + 0.0722 * blue) / 255
    }
}

/// Single-fire relay for `luminanceWithTimeout`'s race between the sample
/// and the timeout: whichever finishes first resumes the continuation, the
/// other is a no-op instead of a crash-inducing double resume. `@MainActor`
/// isolation is what makes the check-then-clear in `resume` atomic — no
/// `await` between them — regardless of which actor either racing `Task`
/// ends up inheriting.
@MainActor
private final class LuminanceRelay {
    private var continuation: CheckedContinuation<CGFloat, Never>?

    init(continuation: CheckedContinuation<CGFloat, Never>) {
        self.continuation = continuation
    }

    func resume(with value: CGFloat) {
        guard let pending = continuation else { return }
        continuation = nil
        pending.resume(returning: value)
    }
}

/// Amber vignette: transparent center, bold color at the edges.
private final class VignetteView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let edge = NSColor.systemOrange.withAlphaComponent(0.55)
        guard let gradient = NSGradient(
            colorsAndLocations: (.clear, 0.0), (.clear, 0.15), (edge, 1.0)
        ) else { return }
        gradient.draw(in: bounds, relativeCenterPosition: .zero)
    }
}
