import AppKit
import ShifuCore
import SwiftUI

/// Shifu's mark in the menu bar: one mountain ridge, drawn in a single stroke.
/// Worn down to foothills when capture is paused, so the state is legible at
/// 18 points without a badge.
///
/// `MenuBarExtra(systemImage:)` can only take an SF Symbol and none of them is
/// this, so the figure is rendered once per state into an `NSImage` at menu
/// bar height and cached. Rendered as a *template*: this mark is monochrome by
/// design, and letting AppKit tint it is what keeps it right on a dark menu
/// bar, under a wallpaper, and while the item is pressed.
enum MenuBarMark {
    /// Menu bar items get 22 pt of height; 18 leaves the usual optical margin.
    private static let side: CGFloat = 18
    /// The stopwatch beside the mark. Smaller than the bar's own clock on
    /// purpose — this is Shifu's reading, not the system's, and it should sit
    /// a step behind the time of day rather than compete with it.
    private static let digits: CGFloat = 11.5
    private static let gap: CGFloat = 4

    @MainActor private static var cache: [Bool: NSImage] = [:]
    /// The timed mark can't use `cache`: its content changes every second, so
    /// keying it by state would grow an entry per tick for the life of the
    /// launch. One slot, replaced on each tick — which is all a stopwatch ever
    /// needs, since the only image anyone can be looking at is the current one.
    @MainActor private static var timed: (key: String, image: NSImage)?

    /// Nil if `ImageRenderer` can't produce a bitmap — the caller falls back to
    /// an SF Symbol rather than leaving a blank gap in the menu bar, which is
    /// what an empty `NSImage` would look like.
    @MainActor static func image(paused: Bool) -> NSImage? {
        if let cached = cache[paused] { return cached }
        guard let image = render(InstrumentMark(paused: paused)
            .frame(width: side, height: side)) else { return nil }
        cache[paused] = image
        return image
    }

    /// The mark with a running stopwatch beside it (design.md §4.4) — the
    /// always-visible half of the Focus Mode clock, so "how long have I been at
    /// this" is answered without opening anything.
    ///
    /// Drawn *into the same template image* rather than set as a `Text` next to
    /// it, for the reason the mark is one: AppKit tints a template, so the
    /// digits invert with the ridge when the item is pressed and stay legible
    /// on a dark bar. A separately-coloured label would go its own way in both
    /// cases.
    @MainActor static func image(paused: Bool, stopwatch: String) -> NSImage? {
        let key = "\(paused)-\(stopwatch)"
        if let timed, timed.key == key { return timed.image }
        let content = HStack(spacing: gap) {
            InstrumentMark(paused: paused)
                .frame(width: side, height: side)
            Text(stopwatch)
                // Tabular figures so the item only changes width when the
                // reading gains a digit, not on every rolling second.
                .font(Instrument.mono(digits, .medium))
                .monospacedDigit()
                .foregroundStyle(Color.black)
        }
        .frame(height: side)
        guard let image = render(content) else { return nil }
        timed = (key, image)
        return image
    }

    /// Renders at the screen's scale and marks the result a template — the ink
    /// is thrown away and only the coverage survives, which is why the fill
    /// above can be flat black.
    @MainActor private static func render(_ content: some View) -> NSImage? {
        let renderer = ImageRenderer(content: content)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let image = renderer.nsImage else { return nil }
        image.isTemplate = true
        return image
    }
}

/// What the menu bar item wears: the mark, and while Focus Mode is on, the
/// running session's stopwatch beside it.
///
/// Two objects, because they move at two rates. `store` says which mark to
/// draw and changes a few times a day; `stopwatch` carries the reading and
/// changes every second — and only while a session runs, so an idle Shifu
/// redraws its item exactly as rarely as it always has.
struct MenuBarLabel: View {
    @ObservedObject private var store: LedgerStore
    @ObservedObject private var stopwatch: FocusStopwatch

    init(store: LedgerStore) {
        _store = ObservedObject(wrappedValue: store)
        _stopwatch = ObservedObject(wrappedValue: store.focusStopwatch)
    }

    var body: some View {
        mark.accessibilityLabel(spoken)
    }

    @ViewBuilder private var mark: some View {
        if let image = stopwatch.elapsed
            .map({ MenuBarMark.image(paused: store.isPaused, stopwatch: FocusClock.stopwatch($0)) })
            ?? MenuBarMark.image(paused: store.isPaused) {
            Image(nsImage: image)
        } else {
            Image(systemName: store.isPaused ? "pause" : "chart.bar.xaxis")
        }
    }

    /// The stopwatch is drawn, so VoiceOver has to say it: the image's own
    /// label would announce the state and drop the one number the item was
    /// extended for.
    private var spoken: String {
        guard let elapsed = stopwatch.elapsed else {
            return store.isPaused ? "Shifu, resting" : "Shifu, watching"
        }
        return "Shifu, in focus \(FocusClock.stopwatch(elapsed))"
    }
}

/// The mark itself, also usable on screen: one ridge, high while watching and
/// worn down to two low hills while resting.
struct InstrumentMark: View {
    var paused = false

    /// The ridge as a polyline in unit space, y measured from the top. Both
    /// states start and end on the same base line at the same x, so the mark
    /// keeps its footing in the bar and only the country between changes.
    private static let watching: [CGPoint] = [
        .init(x: 0.08, y: 0.76), .init(x: 0.36, y: 0.24), .init(x: 0.56, y: 0.52),
        .init(x: 0.70, y: 0.36), .init(x: 0.92, y: 0.76)
    ]
    /// Two tiny peaks whose valley drops all the way back to the base line —
    /// at 18 points that reads as "smaller and calmer", where a flat line read
    /// as "broken".
    private static let resting: [CGPoint] = [
        .init(x: 0.08, y: 0.76), .init(x: 0.30, y: 0.52), .init(x: 0.50, y: 0.76),
        .init(x: 0.70, y: 0.52), .init(x: 0.92, y: 0.76)
    ]

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let points = paused ? Self.resting : Self.watching
            Path { path in
                for (index, point) in points.enumerated() {
                    let place = CGPoint(x: point.x * size.width, y: point.y * size.height)
                    if index == 0 { path.move(to: place) } else { path.addLine(to: place) }
                }
            }
            // Round joins keep the peaks from splintering once the stroke is
            // only ~2 pt wide; anything thinner disappears under a wallpaper.
            .stroke(
                Color.primary,
                style: StrokeStyle(
                    lineWidth: min(size.width, size.height) * 0.11,
                    lineCap: .round, lineJoin: .round))
        }
    }
}
