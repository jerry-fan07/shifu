import AppKit
import ShifuCore
import SwiftUI

/// The first-run nudge demonstration (design.md §4.4, §7): onboarding's "Show
/// me the nudge" hands the whole screen to one real glow pulse, with a bar
/// along the bottom naming each phase as it goes past, then hands the window
/// back.
///
/// It takes the screen rather than drawing a thumbnail inside the window
/// because the thing being consented to is a full-screen event. A 90 pt
/// preview would answer "what colour is it" and leave the only question that
/// matters — how much of your attention does this take — to the first time it
/// fires unannounced.
///
/// The pulse is the daemon's in every respect the eye can check: `FocusNudge`
/// carries the phase durations, the vignette's grade and the line's size, so
/// the two cannot drift. It is not literally `GlowOverlay` — that lives in
/// `shifud`, which the app does not link and must not, since the daemon is the
/// process with no network in it (§8). The renderers differ for a reason of
/// their own: the daemon animates on Core Animation layers because the capture
/// ladder blocks its main thread exactly when a pulse fires, while the app's
/// main thread is idle behind an onboarding window and can drive the same
/// curve straight from SwiftUI.
///
/// Running it changes nothing. Focus Mode is not switched on, no session is
/// logged, and nothing is written — the demonstration is a picture of the
/// contract, not an acceptance of it.
@MainActor
final class NudgeDemo: ObservableObject {
    /// The vignette's opacity and the line's, 0…1. Published rather than
    /// animated per-window so that every display's overlay breathes off one
    /// clock — the real pulse fires on all of them at once.
    @Published var vignette = 0.0
    @Published var message = 0.0
    /// Pulses fired so far. The bar's playhead restarts on the change rather
    /// than on a re-run of the same value: a replayed 0→1 animation gets
    /// coalesced into no animation at all.
    @Published var pulses = 0

    private var windows: [NSWindow] = []
    private var escapeMonitor: Any?
    private var fadeOut: Task<Void, Never>?

    /// True while the screen is handed over, so a second click on the button
    /// behind the overlay can't stack a second set of windows on the first.
    private(set) var isPresenting = false

    /// How many windows the demonstration is currently holding — one vignette
    /// per display plus the bar. Exposed for the tests that guard the failure
    /// this class actually has: a stranded full-screen overlay.
    var windowCount: Int { windows.count }

    // MARK: - Lifecycle

    /// Takes the screen and fires the first pulse.
    func present() {
        guard !isPresenting else { return }
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        isPresenting = true

        // The line goes on the screen the user is looking at — the one under
        // the pointer, the same choice the daemon makes and for the same
        // reason: an accessory app's `NSScreen.main` tracks a key window it
        // may not have, and degrades to the primary display.
        let host = Self.screenUnderPointer(in: screens) ?? screens[0]
        for screen in screens {
            windows.append(overlayWindow(for: screen, carriesMessage: screen === host))
        }
        // Ordered last, so it sits above every vignette: it is the one part of
        // this that takes a click.
        let bar = barWindow(on: host)
        windows.append(bar)
        for window in windows { window.orderFrontRegardless() }
        // And made key, so Escape below lands here rather than depending on
        // whichever window happened to be key behind a full-screen overlay.
        bar.makeKeyAndOrderFront(nil)

        // The way out that doesn't need the pointer to have found the bar yet.
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }   // Escape
            self?.dismiss()
            return nil
        }
        NSApp.activate(ignoringOtherApps: true)
        fire()
    }

    /// Hands the window back. Idempotent, and safe from either exit.
    func dismiss() {
        guard isPresenting else { return }
        isPresenting = false
        fadeOut?.cancel()
        fadeOut = nil
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
        for window in windows { window.orderOut(nil) }
        windows = []
        vignette = 0
        message = 0
    }

    // MARK: - The pulse

    /// One breath, on `FocusNudge`'s clock. The line's fade is shorter than the
    /// vignette's ramp, so it lands while the glow is still rising — in the
    /// real pulse that stagger is the shade sample arriving late, and it reads
    /// as sequencing rather than lag either way.
    func fire() {
        fadeOut?.cancel()
        pulses += 1
        withAnimation(.easeInOut(duration: FocusNudge.breatheIn)) { vignette = 1 }
        withAnimation(.easeInOut(duration: FocusNudge.messageFade)) { message = 1 }
        fadeOut = Task { [weak self] in
            try? await Task.sleep(for: .seconds(FocusNudge.breatheIn + FocusNudge.hold))
            guard !Task.isCancelled, let self, isPresenting else { return }
            withAnimation(.easeInOut(duration: FocusNudge.breatheOut)) {
                vignette = 0
                message = 0
            }
        }
    }

    // MARK: - Windows

    /// One screen's vignette: click-through, above everything, and gone the
    /// moment the demonstration ends.
    private func overlayWindow(for screen: NSScreen, carriesMessage: Bool) -> NSWindow {
        let window = NSWindow(
            contentRect: screen.frame, styleMask: .borderless,
            backing: .buffered, defer: false)
        window.level = .screenSaver
        window.ignoresMouseEvents = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        window.contentView = NSHostingView(
            rootView: NudgePulse(
                demo: self,
                messageSize: screen.frame.width * FocusNudge.messageWidthFraction,
                carriesMessage: carriesMessage))
        return window
    }

    /// The bar along the bottom of the screen the line is on. Its own window
    /// rather than part of the overlay: everything above it is click-through,
    /// and this is the only thing here that is not.
    private func barWindow(on screen: NSScreen) -> NSWindow {
        let height: CGFloat = 80
        let window = KeyableWindow(
            contentRect: NSRect(
                x: screen.frame.minX, y: screen.frame.minY,
                width: screen.frame.width, height: height),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isMovable = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        window.contentView = NSHostingView(
            rootView: NudgeDemoBar(demo: self, again: { [weak self] in self?.fire() },
                                   done: { [weak self] in self?.dismiss() }))
        return window
    }

    /// Matching by identity is sound only inside the single `screens` snapshot
    /// the caller took — AppKit doesn't promise stable `NSScreen` instances.
    private static func screenUnderPointer(in screens: [NSScreen]) -> NSScreen? {
        let pointer = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(pointer, $0.frame, false) }
    }
}

/// A borderless window refuses key status by default, and the bar needs it: it
/// carries the demonstration's only keyboard affordance, and Escape has to work
/// even though everything else on screen is click-through.
private final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

// MARK: - The pulse, as drawn

/// One screen's worth of nudge: the amber vignette, and on one screen the line.
struct NudgePulse: View {
    @ObservedObject var demo: NudgeDemo
    let messageSize: CGFloat
    let carriesMessage: Bool

    var body: some View {
        ZStack {
            NudgeVignette()
                .opacity(demo.vignette)
            if carriesMessage {
                Text(FocusNudge.message)
                    // The system face at the daemon's size, not `Instrument`'s:
                    // the pulse is not a surface of the app, it is a thing that
                    // happens over whatever you were doing.
                    .font(.system(size: messageSize, weight: .medium))
                    .foregroundStyle(Color.nudgeShade)
                    .opacity(demo.message)
            }
        }
        .ignoresSafeArea()
    }
}

extension Color {
    /// The line's shade: black on a light appearance, white on a dark one.
    ///
    /// The real pulse picks this pole by sampling the display behind it (§4.4),
    /// which costs a Screen Recording grant. The app's copy deliberately
    /// won't: onboarding has just finished explaining that Screen Recording is
    /// the *daemon's* permission, and opening a second, differently-worded
    /// prompt for the app in the middle of a preview would undo that page. The
    /// appearance is the closest honest stand-in — a desktop is light when the
    /// system is, in almost every case where it matters.
    static let nudgeShade = Color(light: 0x000000, dark: 0xFFFFFF)
}

/// A scale model of the pulse, for the page that describes it before firing
/// one: the vignette on the same grade, with the line at the same fraction of
/// the screen's width, in a rectangle the shape of a display.
///
/// Screen-shaped is the whole trick. The grade only reads as *edges* on
/// something a screen's proportions — drawn as a squat banner, the same
/// gradient covers its own short axis and reads as a solid amber slab, which
/// is the one thing the nudge is not.
struct NudgeMiniature: View {
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                NudgeVignette()
                Text(FocusNudge.message)
                    .font(.system(
                        size: proxy.size.width * FocusNudge.messageWidthFraction,
                        weight: .medium))
                    .foregroundStyle(Color.nudgeShade)
            }
        }
        .aspectRatio(16.0 / 10.0, contentMode: .fit)
        .background(Instrument.well)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

/// The vignette: clear through the middle, amber at the corners, on
/// `FocusNudge`'s grade. Elliptical, so it reaches the corners of a wide
/// display at the same moment it reaches the corners of a square one.
///
/// Not private: onboarding's Focus Mode page draws a still of it, and a page
/// promising "this is what you'll see" has to draw the thing it means.
struct NudgeVignette: View {
    var body: some View {
        EllipticalGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .clear, location: FocusNudge.clearStop),
                .init(
                    color: Color(nsColor: .systemOrange).opacity(FocusNudge.edgeAlpha),
                    location: 1)
            ],
            center: .center,
            startRadiusFraction: 0,
            // Half the diagonal of the unit square: the far corner, which is
            // where the daemon's gradient ends too.
            endRadiusFraction: 0.5 * (2.0 as Double).squareRoot())
    }
}

// MARK: - The bar

/// What the pulse just did, to scale, with the two ways out. The bar is the
/// explanation the real nudge never gets to give: it names the phases, and it
/// shows how much of the gap between two pulses is silence.
struct NudgeDemoBar: View {
    @ObservedObject var demo: NudgeDemo
    let again: () -> Void
    let done: () -> Void

    var body: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Eyebrow("One pulse")
                    Text("This is the whole nudge. It is click-through, it fires on every "
                        + "display, and it captures nothing.")
                        .font(Instrument.sans(12.5))
                        .foregroundStyle(Instrument.secondary)
                        .lineLimit(1)
                }
                PhaseRail(trigger: demo.pulses)
            }
            HStack(spacing: 10) {
                OutlineButton(title: "Again", action: again)
                SolidButton(title: "Done", action: done)
            }
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Instrument.ground.opacity(0.94))
        .overlay(alignment: .top) { Rule(weight: .edge) }
    }
}

/// The pulse drawn against the gap it lives in: the three phases as bands, the
/// idle that follows as bare track, and a playhead sweeping the whole frame
/// once per pulse.
private struct PhaseRail: View {
    let trigger: Int

    /// The full frame the rail draws — one pulse plus the silence the daemon
    /// enforces after it (§4.4). Drawing the phases alone would put a 4.4 s
    /// event edge to edge and make it look relentless.
    private static let frame = FocusNudge.spacing

    private struct Phase {
        let label: String
        let seconds: TimeInterval
        let color: Color
    }

    /// One hue, three steps: this is one event's phases, not three series. The
    /// hold takes the hottest step because it is the peak of the breath.
    private static let phases = [
        Phase(label: "breathe in 1.6s", seconds: FocusNudge.breatheIn, color: Instrument.warm),
        Phase(label: "hold 0.4s", seconds: FocusNudge.hold, color: Instrument.beacon),
        Phase(
            label: "breathe out 2.4s", seconds: FocusNudge.breatheOut,
            color: Instrument.warm.opacity(0.55))
    ]

    private static let tail = "idle until the next off-task capture"

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            rail
            labels
        }
    }

    private var rail: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                ForEach(Array(Self.phases.enumerated()), id: \.offset) { _, phase in
                    Rectangle()
                        .fill(phase.color)
                        .frame(width: proxy.size.width * phase.seconds / Self.frame)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) { playhead(across: proxy.size.width) }
        }
        .frame(height: 6)
        .background(Instrument.well)
        .clipShape(Capsule())
    }

    /// Sweeps the frame once, then parks at the end — the real thing does not
    /// loop either, it waits for another off-task capture.
    private func playhead(across width: CGFloat) -> some View {
        KeyframeAnimator(initialValue: 0.0, trigger: trigger) { place in
            Rectangle()
                .fill(Instrument.ink)
                .frame(width: 1)
                .offset(x: width * place)
        } keyframes: { _ in
            LinearKeyframe(1.0, duration: Self.frame)
        }
    }

    /// Each phase named at its own start, in the terminal register. Placed
    /// rather than stacked, and pushed right off the previous label when a
    /// phase is too short to hold its own name — the hold is 4% of the frame
    /// and "HOLD 0.4S" is wider than that, so the alternative to nudging is
    /// two labels on top of each other.
    private var labels: some View {
        GeometryReader { proxy in
            ForEach(Self.placed(across: proxy.size.width), id: \.text) { label in
                Eyebrow(label.text, tracking: 1)
                    .fixedSize()
                    .offset(x: label.leading)
            }
        }
        .frame(height: Self.labelHeight)
    }

    private static let labelHeight = ("0" as NSString)
        .size(withAttributes: [.font: Instrument.monoFont(10)]).height

    private struct PlacedLabel {
        let text: String
        let leading: CGFloat
    }

    private static func placed(across width: CGFloat) -> [PlacedLabel] {
        // Wide enough that two tracked-out mono labels forced together read as
        // two labels: at 10 pt "HOLD 0.4S BREATHE OUT 2.4S" runs into one line.
        let gap: CGFloat = 22
        // Each label's own instant, in seconds from the start of the pulse:
        // the three phase starts, then the moment the idle begins.
        var starts: [TimeInterval] = []
        var elapsed: TimeInterval = 0
        for phase in phases {
            starts.append(elapsed)
            elapsed += phase.seconds
        }
        starts.append(elapsed)

        var placed: [PlacedLabel] = []
        var occupied: CGFloat = 0
        for (text, start) in zip(phases.map(\.label) + [tail], starts) {
            let leading = max(width * start / frame, occupied)
            placed.append(PlacedLabel(text: text, leading: leading))
            occupied = leading + measure(text) + gap
        }
        return placed
    }

    /// Measured rather than guessed: a label pushed off its neighbour by an
    /// estimated width overlaps it for real.
    private static func measure(_ text: String) -> CGFloat {
        (text.uppercased() as NSString)
            .size(withAttributes: [
                .font: Instrument.monoFont(10),
                .kern: 1
            ]).width
    }
}
