import ShifuCore
import SwiftUI

/// One rail per day, on a shared clock, and what the run of them says
/// (design.md §7).
///
/// The point of the shared clock is that the week's shape is the *shift* of
/// the bands down the column, which separate day-charts never show. But it is
/// only drawn there — reading it still asks you to notice a diagonal in five
/// rows of noise, and nobody notices. So `Rhythms` reads the two ends of every
/// night out of the same blocks, and what it finds is drawn twice: as a mark
/// on the rail it came off, and as a line under the chart saying what the
/// marks mean. Neither is any use alone. The mark without the line is an
/// unexplained dot; the line without the mark is a claim you would have to
/// take on faith.
///
/// Split in two on purpose. This view does the expensive part — resampling
/// seven rails out of a week of blocks — and `WeekRails` below owns the hover
/// state, so lighting a row's marks re-runs the cheap half only. Hover used to
/// cost this page a pinned core; the fix was not to hover less but to keep the
/// state under the work.
struct WeekBand: View {
    let blocks: [LedgerBuilder.LabeledActivity]
    let lens: TimeLens
    let colors: [String: Color]
    let window: (from: Date, to: Date)
    let signals: [Rhythms.Signal]

    var body: some View {
        let clock = LedgerShapes.clock(blocks, from: window.from, to: window.to)
        WeekRails(rails: rails(on: clock), ticks: LedgerShapes.ticks(clock), signals: signals)
    }

    /// One rail per elapsed day, on the shared clock, with any rhythm marks
    /// that fall on it already placed.
    private func rails(on clock: LedgerShapes.Clock) -> [DayRail] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        var anchors: [Date: [(signal: Rhythms.Signal, mark: Rhythms.Mark)]] = [:]
        for signal in signals {
            for mark in signal.marks { anchors[mark.day, default: []].append((signal, mark)) }
        }

        return (0..<7).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: window.from),
                  day <= today
            else { return nil }
            let rail = clock.on(day)
            return DayRail(
                id: offset,
                label: day.formatted(.dateTime.weekday(.abbreviated)),
                isToday: day == today,
                segments: LedgerShapes.ribbon(
                    blocks, lens: lens, colors: colors, from: rail.from, to: rail.to),
                marks: (anchors[day] ?? []).compactMap { anchor in
                    LedgerShapes.position(of: anchor.mark.at, on: rail).map { place in
                        RailMark(
                            signal: anchor.signal.id, place: place,
                            caption: anchor.signal.caption(anchor.mark))
                    }
                })
        }
    }
}

/// One day of the week band, already resampled.
struct DayRail: Identifiable {
    let id: Int
    let label: String
    let isToday: Bool
    let segments: [RibbonSegment]
    let marks: [RailMark]
}

/// A rhythm mark, placed across the rail it belongs to.
struct RailMark: Identifiable {
    /// Which signal put it here, so hovering that signal's row can pick its
    /// own marks out of the week.
    let signal: String
    /// 0…1 across the rail.
    let place: Double
    let caption: String

    var id: String { "\(signal)@\(place)" }
}

/// The drawn half: rails, marks, axis, and the rhythm lines under them.
private struct WeekRails: View {
    let rails: [DayRail]
    let ticks: [LedgerShapes.AxisTick]
    let signals: [Rhythms.Signal]
    /// The rhythm line the pointer is on. Its marks stay lit and the rest
    /// step back, so the sentence and the dots it is about are one thing —
    /// which is the only way a reader can check a claim against the week.
    @State private var focus: String?

    /// The weekday gutter and the air after it, which the axis and the
    /// rhythm lines both hang off so all three columns start together.
    private static let gutter: CGFloat = 34
    private static let air: CGFloat = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(rails) { rail in
                HStack(spacing: Self.air) {
                    Figure(
                        rail.label, size: 10.5,
                        color: rail.isToday ? Instrument.ink : Instrument.faint)
                        .frame(width: Self.gutter, alignment: .leading)
                    Ribbon(segments: rail.segments, height: 15, corner: 3)
                        .overlay { RhythmMarks(marks: rail.marks, focus: focus) }
                }
            }
            RibbonAxis(ticks: ticks, leading: Self.gutter + Self.air)
            if !signals.isEmpty {
                RhythmLines(signals: signals, focus: $focus)
                    .padding(.leading, Self.gutter + Self.air)
            }
        }
    }
}

/// One rail's marks, laid over the bands.
private struct RhythmMarks: View {
    let marks: [RailMark]
    let focus: String?

    var body: some View {
        GeometryReader { proxy in
            ForEach(marks) { mark in
                RhythmMark(dimmed: focus != nil && focus != mark.signal)
                    // Under `position`, not over it: `help` claims the frame
                    // it is applied to, and a positioned view's frame is the
                    // whole rail — which would put this tooltip over every
                    // band the ribbon has already labelled.
                    .help(mark.caption)
                    .position(x: proxy.size.width * mark.place, y: proxy.size.height / 2)
            }
        }
    }
}

/// The mark itself: one bead of light — a solid core and the halo falling off
/// it.
///
/// It was a ring with a dot in the middle, which is a *target*: three concentric
/// edges, and the eye goes to the outermost one, so the mark read as wider than
/// the instant it names and its true centre was the emptiest part of it. A
/// filled core has one edge and its middle is its brightest point, which is
/// where the instant is.
///
/// One shape, not a stack of them: a single circle whose fill goes solid at the
/// middle and falls to nothing at the rim. Layering a core over a blurred disc
/// gets close, but the disc's own edge always shows faintly through the haze and
/// the mark is back to having two of them.
///
/// The falloff is steep on purpose. Run out gently to the rim and the ball and
/// its glow blend into one soft blob the size of the whole gradient; dropped to
/// almost nothing by two thirds of the radius, the ball keeps its edge and the
/// glow reads as light coming off it. That also keeps the mark well inside the
/// 5pt air between rails — a halo wide enough to reach the row above reads as a
/// smudge on the wrong day.
///
/// Warm, and the only warm thing in the band. Every other hue on a rail is a
/// series — a category, a theme, a task — and this is not one; `beacon` is a
/// lift of the instrument's token for a figure that wants looking at, which is
/// exactly what a mark is. It is also the one hue that separates from all five
/// chart slots at once, so a mark reads whatever band it lands on.
///
/// Static, and deliberately: design.md §7's bargain for an app you leave open
/// all day is that nothing ticks on its own. A mark announces itself by being
/// the wrong colour for a chart, not by pulsing at you.
private struct RhythmMark: View {
    var size: CGFloat = 12
    var dimmed = false

    var body: some View {
        Circle()
            .fill(RadialGradient(
                stops: [
                    // Solid to a little under half the radius — that disc is
                    // the ball, and its edge is the only edge in the mark. Past
                    // it the stops are close together and never hold a level,
                    // because any stretch that does reads as a second rim.
                    .init(color: Instrument.beacon, location: 0.42),
                    .init(color: Instrument.beacon.opacity(0.34), location: 0.52),
                    .init(color: Instrument.beacon.opacity(0.11), location: 0.64),
                    .init(color: Instrument.beacon.opacity(0.02), location: 0.80),
                    .init(color: Instrument.beacon.opacity(0), location: 1)
                ],
                center: .center, startRadius: 0, endRadius: size * 0.8))
            .frame(width: size * 1.6, height: size * 1.6)
            .opacity(dimmed ? 0.22 : 1)
    }
}

/// What the marks add up to, in a sentence each: the reading on the left, the
/// run it was read from on the right. Two lines at most — one per end of the
/// night — because a page that reports six trends is reporting none.
private struct RhythmLines: View {
    let signals: [Rhythms.Signal]
    @Binding var focus: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rule().padding(.top, 11).padding(.bottom, 9)
            Eyebrow("Rhythm").padding(.bottom, 6)
            ForEach(signals) { signal in
                HStack(spacing: 9) {
                    RhythmMark(size: 11)
                    Text(signal.headline)
                        .font(Instrument.sans(12.5))
                        .foregroundStyle(Instrument.body)
                        .lineLimit(1)
                    Spacer(minLength: 14)
                    Figure(signal.detail, size: 11, color: Instrument.faint)
                        .lineLimit(1)
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 6)
                .background(focus == signal.id ? Instrument.rowTint : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
                .help(signal.note)
                // Only ever clears its *own* focus: crossing straight from one
                // line to the next delivers the leaving row's `false` after
                // the entering row's `true`, and a plain assignment there
                // blanks the highlight the pointer is sitting on.
                .onHover { inside in
                    if inside { focus = signal.id } else if focus == signal.id { focus = nil }
                }
            }
            .padding(.leading, -6)
        }
    }
}
