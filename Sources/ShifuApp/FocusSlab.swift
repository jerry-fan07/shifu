import ShifuCore
import SwiftUI

/// The ink slab: the running Focus session as one dark card — the stopwatch
/// overlaid on a candle chart of the session's focus index (`FocusCandles`).
/// Inverted on purpose, and the one card in an app that otherwise has none:
/// unmistakable while focus is on, gone the moment it is off.
///
/// The slab keeps its own ink because it is dark in *both* appearances —
/// Instrument's adaptive tokens would flip its text to near-black in light
/// mode. Candle green and red were validated against this surface with the
/// dataviz checks (deutan ΔE 12.0, both ≥ 3:1); the lightness gap between
/// them is the second cue when hue isn't one.
private enum Slab {
    static let surface = Color(light: 0x1B1A17, dark: 0x151412)
    static let ink = Color(light: 0xEDEBE3, dark: 0xEDEBE3)
    /// The session's gold, tying the slab to the ribbon's focus band.
    static let gold = Color(light: 0xD09A5C, dark: 0xD09A5C)
    static let up = Color(light: 0x55A863, dark: 0x55A863)
    static let down = Color(light: 0xB0453A, dark: 0xB0453A)
    /// A doji — a stretch that said nothing. Grey, because it is not a verdict.
    static let flat = Color(light: 0x59574F, dark: 0x59574F)
    /// Keeps the slab a shape on the dark ground, where surface alone can't.
    static let edge = Color(
        light: 0xFFFFFF, dark: 0xFFFFFF, lightAlpha: 0.07, darkAlpha: 0.09)
    static let corner: CGFloat = 6

    /// The stopwatch face, with a halo of the surface so the digits stay
    /// legible where a candle passes under them.
    static func digits(_ text: String, size: CGFloat) -> some View {
        Text(text)
            .font(Instrument.mono(size, .medium))
            .monospacedDigit()
            .tracking(size * -0.02)
            .foregroundStyle(ink)
            .shadow(color: surface.opacity(0.9), radius: 3)
            .shadow(color: surface.opacity(0.9), radius: 1)
    }
}

/// The session's candles, drawn left-to-right from its first minute. The
/// chart lays out `slots` slots and fills them as the session ages, so a
/// young session reads as a market that just opened, not a stretched smear.
private struct CandleChart: View {
    let candles: [FocusCandles.Candle]
    let slots: Int

    var body: some View {
        Canvas { context, size in
            guard !candles.isEmpty else { return }
            let slotWidth = size.width / CGFloat(max(slots, candles.count))
            let bodyWidth = max(1.5, slotWidth - max(1, min(2, slotWidth * 0.3)))
            var low = candles.map(\.low).min() ?? 0
            var high = candles.map(\.high).max() ?? 0
            // A floor on the range: one good minute is half the chart, not
            // all of it, and a flat session stays a line instead of noise.
            if high - low < 2 {
                let mid = (high + low) / 2
                low = mid - 1
                high = mid + 1
            }
            let inset: CGFloat = 2
            let scale = (size.height - inset * 2) / CGFloat(high - low)
            func place(_ value: Double) -> CGFloat {
                size.height - inset - CGFloat(value - low) * scale
            }
            for candle in candles {
                let color = switch candle.direction {
                case .up: Slab.up
                case .down: Slab.down
                case .flat: Slab.flat
                }
                let center = slotWidth * (CGFloat(candle.id) + 0.5)
                let wick = CGRect(
                    x: center - 0.5, y: place(candle.high),
                    width: 1, height: max(0, place(candle.low) - place(candle.high)))
                context.fill(Path(wick), with: .color(color.opacity(0.55)))
                let top = place(max(candle.open, candle.close))
                let body = CGRect(
                    x: center - bodyWidth / 2, y: top, width: bodyWidth,
                    height: max(1.5, place(min(candle.open, candle.close)) - top))
                context.fill(
                    Path(roundedRect: body, cornerRadius: 1), with: .color(color))
            }
        }
        .accessibilityHidden(true)
    }
}

/// The name and the switch — the one line both states of the rail's foot
/// share, and the reason turning Focus Mode on doesn't pop. It sits at the
/// *bottom* of the plain row and at the bottom of the slab, at the same inset
/// from the same edges, so opening the card grows it upward: the switch you
/// just clicked stays under the pointer, and only the chart is new. The name
/// takes the session's gold when on — the state light the row used to spend a
/// dot on, in the ink it already had.
struct FocusFootRow: View {
    let on: Bool
    var action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("Focus Mode")
                .font(Instrument.sans(13))
                .foregroundStyle(on ? Slab.gold : Instrument.railInk)
            Spacer(minLength: 0)
            ToggleSwitch(isOn: on, action: action)
        }
    }
}

/// The rail's slab: the stopwatch on its chart, over the name and the switch.
struct FocusSlabCompact: View {
    @EnvironmentObject private var store: LedgerStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .leading) {
                CandleChart(candles: candles, slots: 24)
                    .frame(height: 46)
                FocusTick { now in
                    Slab.digits(
                        FocusClock.stopwatch(store.focusClock(now: now).elapsed ?? 0),
                        size: 22)
                }
            }
            FocusFootRow(on: true) { store.toggleFocusMode() }
        }
        // Not one padding: the horizontal inset and the foot's clearance are
        // measured to land `FocusFootRow` exactly where the off row leaves it
        // (`FocusModeRailRow`) — change one and the switch jumps on open.
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 5)
        .background(Slab.surface, in: RoundedRectangle(cornerRadius: Slab.corner))
        .overlay {
            RoundedRectangle(cornerRadius: Slab.corner)
                .strokeBorder(Slab.edge, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Focus Mode on")
    }

    /// From the switch's own start to now, against today's blocks plus the
    /// live tail (`focusTailBlocks`) — so the candles move with the app in
    /// front of you, not with the analyzer's hourly fold.
    private var candles: [FocusCandles.Candle] {
        guard let started = store.focusStartedAt else { return [] }
        return FocusCandles.series(
            from: Int64(started.timeIntervalSince1970 * 1_000),
            to: Int64(Date().timeIntervalSince1970 * 1_000),
            activities: store.todayActivities + store.focusTailBlocks(), candles: 24)
    }
}

/// The Focus page's reading of the running session: the focus index as one
/// bare line, flush with the page — no card, no chrome — with the session's
/// stopwatch laid over it. The gold is the session's own hue, the hairline is
/// zero, and the dot is now. The digits wear the page's figure ink, not the
/// live green: the table row below already says "still running" in green,
/// and this one is the reading, not the alarm. A halo of the ground keeps
/// them legible where the line passes under; the tick is scoped to the
/// label, so the chart never redraws with it.
struct FocusSessionLine: View {
    let session: FocusReport.Session
    let blocks: [LedgerBuilder.LabeledActivity]

    var body: some View {
        ZStack(alignment: .leading) {
            chart
            FocusTick { now in
                Text(FocusClock.stopwatch(
                    now.timeIntervalSince1970 - Double(session.startedAt) / 1_000))
                    .font(Instrument.mono(24, .medium))
                    .monospacedDigit()
                    .tracking(-0.5)
                    .foregroundStyle(Instrument.ink)
                    .shadow(color: Instrument.ground.opacity(0.9), radius: 3)
                    .shadow(color: Instrument.ground.opacity(0.9), radius: 1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Focus index over this session")
    }

    private var chart: some View {
        let readings = FocusCandles.path(
            from: session.startedAt, to: session.endedAt, activities: blocks)
        return Canvas { context, size in
            guard readings.count > 1 else { return }
            var low = readings.min() ?? 0
            var high = readings.max() ?? 0
            // The same floor the candles keep: one good minute is a visible
            // rise, not the whole height, and a flat session stays a line.
            if high - low < 2 {
                let mid = (high + low) / 2
                low = mid - 1
                high = mid + 1
            }
            let inset: CGFloat = 3
            let scale = (size.height - inset * 2) / CGFloat(high - low)
            func place(_ reading: Double) -> CGFloat {
                size.height - inset - CGFloat(reading - low) * scale
            }
            let step = size.width / CGFloat(readings.count - 1)

            var zero = Path()
            zero.move(to: CGPoint(x: 0, y: place(0)))
            zero.addLine(to: CGPoint(x: size.width, y: place(0)))
            context.stroke(zero, with: .color(Instrument.hairline), lineWidth: 1)

            var line = Path()
            line.move(to: CGPoint(x: 0, y: place(readings[0])))
            for (index, reading) in readings.enumerated().dropFirst() {
                line.addLine(to: CGPoint(x: step * CGFloat(index), y: place(reading)))
            }
            context.stroke(
                line, with: .color(Instrument.warm),
                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))

            let head = CGRect(
                x: size.width - 2.5, y: place(readings[readings.count - 1]) - 2.5,
                width: 5, height: 5)
            context.fill(Path(ellipseIn: head), with: .color(Instrument.warm))
        }
        .frame(height: 44)
    }
}
