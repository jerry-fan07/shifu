import AppKit
import ShifuCore

/// The box-drag for Snip (design.md §3.6) — the one piece of Rewind that has to
/// live in the app, because it is the only process with a screen to draw on.
///
/// It draws a selection; it does **not** take a picture. The rect goes to the
/// daemon in the `snip_request` line and the daemon captures it, which is the
/// same split every other Rewind verb uses and the reason invariant 4 still
/// reads "only `RewindShot` may encode a frame": nothing here touches pixels
/// that aren't its own.
///
/// **Non-activating panels.** The overlay must not steal frontmost from the app
/// being snipped — the daemon reads `NSWorkspace.frontmostApplication` to name
/// the source, and an overlay that activated Shifu would file every snip under
/// Shifu. `.nonactivatingPanel` also keeps the target window drawn *active*,
/// which matters when the thing you are snipping is a focus ring or a selection.
@MainActor
final class SnipOverlay {
    static let shared = SnipOverlay()

    /// How long to let the window server compose the overlay away before the
    /// daemon is told to shoot. The `SCShareableContent` round-trip on the far
    /// side is already tens of milliseconds, so this is slack on top of slack —
    /// but "the dimming layer is in the snip" is the one bug that would make the
    /// feature useless, and it is cheap to make impossible.
    static let settleDelay: TimeInterval = 0.12

    /// Visible for tests: the whole feature is a drag, and the drag can only
    /// be driven through a real panel.
    private(set) var panels: [SnipPanel] = []
    private var onPick: ((SnipRegion) -> Void)?

    var isPresenting: Bool { !panels.isEmpty }

    /// Puts a canvas over every screen and calls `onPick` once, with the box the
    /// user dragged. Cancelling — escape, a right-click, or a drag too small to
    /// have been meant — calls nothing at all.
    func present(onPick: @escaping (SnipRegion) -> Void) {
        guard panels.isEmpty else { return }
        self.onPick = onPick

        for screen in NSScreen.screens {
            guard let displayID = Self.displayID(of: screen) else { continue }
            let panel = SnipPanel(
                contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered, defer: false)
            let canvas = SnipCanvas(frame: NSRect(origin: .zero, size: screen.frame.size))
            canvas.screenFrame = screen.frame
            canvas.displayID = displayID
            canvas.onFinish = { [weak self] region in self?.finish(region) }
            canvas.onCancel = { [weak self] in self?.finish(nil) }
            panel.contentView = canvas
            // Above full-screen apps and the menu bar, and present on whichever
            // Space the user is on — a snip is asked for from wherever you are.
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.isMovable = false
            panel.animationBehavior = .none
            panel.ignoresMouseEvents = false
            panel.setFrame(screen.frame, display: false)
            panel.orderFrontRegardless()
            panels.append(panel)
        }

        // One panel takes key so escape has somewhere to land. A non-activating
        // panel can be key while its app is inactive — that is what the style
        // mask buys, and it is why this doesn't have to activate Shifu.
        panels.first?.makeKeyAndOrderFront(nil)
        if panels.isEmpty { self.onPick = nil }
    }

    /// Takes the overlay down without snipping anything. Idempotent.
    ///
    /// The user's own ways out — escape, a right-click — go through here, and
    /// it exists as a method rather than as private state so there *is* a door
    /// from outside: a full-screen panel at `.screenSaver` level that only its
    /// own key handler can dismiss is one stuck event away from being stranded
    /// over everything the user owns. Nothing else calls it yet.
    func cancel() { finish(nil) }

    /// Takes the overlay down and, if there was a selection, hands it on after
    /// the panels have actually left the screen.
    private func finish(_ region: SnipRegion?) {
        guard !panels.isEmpty else { return }
        panels.forEach { $0.orderOut(nil) }
        panels = []
        let pick = onPick
        onPick = nil
        guard let region, region.isUsable, let pick else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay) {
            pick(region)
        }
    }

    /// `CGDirectDisplayID` for a screen — the id the daemon matches against
    /// `SCShareableContent.displays` so a box dragged on the second monitor
    /// crops the second monitor.
    private static func displayID(of screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

/// A borderless panel that can still be key. Borderless windows refuse key
/// status by default, and without it escape has nowhere to go.
final class SnipPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// One screen's worth of selection: the dim, the box, and the readout.
///
/// Drawn in AppKit rather than SwiftUI on purpose — this is a transient
/// full-screen scratch layer that redraws on every mouse-drag, and a hosting
/// view would put a whole view graph in the path of a 60 Hz rubber band.
final class SnipCanvas: NSView {
    var screenFrame: CGRect = .zero
    var displayID: UInt32 = 0
    var onFinish: (SnipRegion) -> Void = { _ in }
    var onCancel: () -> Void = {}

    private var anchor: CGPoint?
    private var current: CGPoint?

    private enum Key {
        static let escape: UInt16 = 53
        static let carriageReturn: UInt16 = 36
        static let enter: UInt16 = 76
    }

    override var acceptsFirstResponder: Bool { true }
    /// The overlay belongs to an inactive app; without this the click that
    /// starts the drag would be spent activating instead.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isFlipped: Bool { false }

    /// The box in this view's own coordinates. Nil until a drag starts.
    private var selection: CGRect? {
        guard let anchor, let current else { return nil }
        return CGRect(
            x: min(anchor.x, current.x), y: min(anchor.y, current.y),
            width: abs(current.x - anchor.x), height: abs(current.y - anchor.y))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        // Dim everything *except* the selection — the bright hole is the whole
        // affordance: what stays bright is exactly what gets captured. An
        // even-odd path rather than a `.copy` punch, because this view is
        // layer-backed and clearing pixels out of a layer is not reliable.
        NSColor.black.withAlphaComponent(0.35).setFill()
        guard let selection, selection.width >= 1, selection.height >= 1 else {
            bounds.fill()
            drawHint()
            return
        }
        let dim = NSBezierPath(rect: bounds)
        dim.append(NSBezierPath(rect: selection))
        dim.windingRule = .evenOdd
        dim.fill()

        // Two strokes, dark under light: the box has to be visible over both a
        // white document and a dark terminal, and one colour can't be.
        NSColor.black.withAlphaComponent(0.55).setStroke()
        NSBezierPath(rect: selection.insetBy(dx: -1.5, dy: -1.5)).stroke()
        NSColor.white.setStroke()
        let border = NSBezierPath(rect: selection.insetBy(dx: -0.5, dy: -0.5))
        border.lineWidth = 1
        border.stroke()

        drawReadout(for: selection)
    }

    private func drawHint() {
        let text = "Drag to snip   ·   ⏎ whole screen   ·   esc cancel"
        let size = text.size(withAttributes: Self.hintAttributes)
        let origin = CGPoint(
            x: bounds.midX - size.width / 2, y: bounds.maxY - size.height - 44)
        drawPlate(text, at: origin)
    }

    /// The pixel size of the box, parked just outside it so it never covers the
    /// thing being selected — and flipped inside when the box is at an edge.
    private func drawReadout(for selection: CGRect) {
        let text = "\(Int(selection.width.rounded())) × \(Int(selection.height.rounded()))"
        let size = text.size(withAttributes: Self.hintAttributes)
        var origin = CGPoint(x: selection.minX, y: selection.minY - size.height - 10)
        if origin.y < bounds.minY + 4 { origin.y = selection.maxY + 10 }
        origin.x = min(max(origin.x, bounds.minX + 4), bounds.maxX - size.width - 12)
        drawPlate(text, at: origin)
    }

    /// A line of white text on a dark rounded plate, so it reads over whatever
    /// is behind the dim.
    private func drawPlate(_ text: String, at origin: CGPoint) {
        let size = text.size(withAttributes: Self.hintAttributes)
        let plate = CGRect(
            x: origin.x - 8, y: origin.y - 4, width: size.width + 16, height: size.height + 8)
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: plate, xRadius: 6, yRadius: 6).fill()
        text.draw(at: origin, withAttributes: Self.hintAttributes)
    }

    private static let hintAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 12, weight: .medium),
        .foregroundColor: NSColor.white
    ]

    // MARK: Events

    override func mouseDown(with event: NSEvent) {
        anchor = convert(event.locationInWindow, from: nil)
        current = anchor
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        guard let selection else { return onCancel() }
        let region = SnipRegion.from(
            selection: selection.offsetBy(dx: screenFrame.minX, dy: screenFrame.minY),
            on: screenFrame, displayID: displayID)
        // A click that never became a drag is a click, not a 3-pixel snip.
        guard region.isUsable else { return onCancel() }
        onFinish(region)
    }

    /// Right-click cancels, so there is a way out that doesn't need the panel to
    /// have key status.
    override func rightMouseDown(with event: NSEvent) { onCancel() }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case Key.escape:
            onCancel()
        case Key.carriageReturn, Key.enter:
            // The whole screen this canvas covers — not "no region", so a
            // second monitor still snips the monitor you are looking at.
            onFinish(SnipRegion.from(
                selection: screenFrame, on: screenFrame, displayID: displayID))
        default:
            super.keyDown(with: event)
        }
    }
}
