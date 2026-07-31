import ShifuCore
import SwiftUI

// The load ahead (design.md §5.2). The Due tab's heatmap is the record of
// having shown up; this is the bill for it — the same instrument pointed the
// other way down the calendar.

/// Every scheduled card placed on the local day it comes due, with everything
/// already past due gathered into one figure at the left.
///
/// Pure arithmetic over already-read notes — no vault, no clock of its own —
/// so what the band claims can be checked in a test.
struct ReviewForecast {
    /// One day of the window. `id` is days from today, so 0 is today.
    struct Day: Identifiable {
        let id: Int
        let date: Date
        let dueCount: Int
        /// Everything due on or before this day, backlog included — what the
        /// queue would hold that morning if nothing were reviewed until then.
        let cumulative: Int

        var isToday: Bool { id == 0 }
    }

    /// Reviews whose day has already passed: how far behind the user is.
    var backlog = 0
    /// Today first, one entry per day of the window — including the empty ones,
    /// so the run reads as a calendar rather than as gaps between busy days.
    var days: [Day] = []
    /// Scheduled past the window. Named in the summary rather than drawn: one
    /// column holding a hundred days beside columns holding one would put a
    /// height on the axis that means nothing.
    var beyond = 0
    /// Never reviewed. These are born due (§5.2) but `ReviewGate` rations them
    /// at their deck's new-per-day cap, so they are a pool to start rather than
    /// a debt to clear — counting them as backlog would report a fresh
    /// hundred-card deck as a hundred reviews of neglect.
    var unstarted = 0

    var windowTotal: Int { days.reduce(0) { $0 + $1.dueCount } }

    /// The tallest column, backlog included — both share one axis, because the
    /// whole point of drawing them together is that they are the same unit.
    var peak: Int { max(backlog, days.map(\.dueCount).max() ?? 0) }

    /// Whether there is a schedule to draw at all. A deck nobody has reviewed
    /// yet has none — only a pool of new cards, which the shelf below already
    /// counts — and twenty-eight empty columns say nothing about it.
    var hasSchedule: Bool { backlog > 0 || beyond > 0 || windowTotal > 0 }

    /// Buckets `cards` by the local day their next review falls on.
    static func build(
        cards: [Note], span: Int = 28, now: Date = Date(), calendar: Calendar = .current
    ) -> ReviewForecast {
        let today = calendar.startOfDay(for: now)
        var forecast = ReviewForecast()
        var counts = [Int](repeating: 0, count: max(1, span))
        for card in cards {
            // No SRS state and a never-graded one are the same card to the
            // user — one that has not started — and `CardStatus` already reads
            // them that way.
            guard let srs = card.srs, srs.reps > 0 else {
                forecast.unstarted += 1
                continue
            }
            let due = calendar.startOfDay(for: srs.due)
            let offset = calendar.dateComponents([.day], from: today, to: due).day ?? 0
            if offset < 0 {
                forecast.backlog += 1
            } else if offset < counts.count {
                counts[offset] += 1
            } else {
                forecast.beyond += 1
            }
        }
        var running = forecast.backlog
        forecast.days = counts.enumerated().compactMap { offset, count in
            guard let date = calendar.date(byAdding: .day, value: offset, to: today)
            else { return nil }
            running += count
            return Day(id: offset, date: date, dueCount: count, cumulative: running)
        }
        return forecast
    }
}

/// The forecast as columns: one per day, scaled against a ruled count axis, with
/// the backlog set off behind its own hairline because it is not a day — it is
/// every day that already went by. Urgency is read twice over, from a column's
/// distance along the axis and from its hue, and every figure the chart carries
/// is also spelled out in the line under it.
struct ReviewForecastView: View {
    let forecast: ReviewForecast

    private static let plot: CGFloat = 84
    private static let axisWidth: CGFloat = 30
    private static let axisGap: CGFloat = 7
    /// Between day columns — the columns sit centred in what is left.
    private static let spacing: CGFloat = 3
    /// Ground that always stays between neighbouring columns, so a narrow
    /// window thins them instead of running them together.
    private static let minAir: CGFloat = 5
    /// Past this a column reads as a region rather than a mark.
    private static let maxThickness: CGFloat = 18
    /// The backlog's own zone, left of the divider.
    private static let backlogWidth: CGFloat = 42
    /// Ground either side of the divider. Wide enough that "Behind" and
    /// "Today" read as two labels rather than one phrase — the tick under a
    /// column overflows its slot, so the break has to be built into the plot.
    private static let dividerAir: CGFloat = 10
    /// The whole backlog zone, divider included, so the plot and the axis under
    /// it can't disagree about where the days start.
    private static var backlogZone: CGFloat { backlogWidth + dividerAir * 2 + 1 }
    /// The tick row's height — fixed, because a `Color.clear` spacer with only
    /// a width is vertically greedy and would stretch the whole band.
    private static let tickHeight: CGFloat = 12
    /// At most this many grid marks — more and the band reads as ruled paper.
    private static let marks = 4
    /// The steps a grid mark may take, coarsest last. Round counts only: the
    /// point of the grid is that a column lands near a figure you can hold in
    /// your head.
    private static let steps = [1, 2, 5, 10, 20, 25, 50, 100, 200, 250, 500, 1_000]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            header
            VStack(spacing: 0) {
                GeometryReader { proxy in
                    ZStack(alignment: .bottomLeading) {
                        grid
                        columns(thickness: thickness(across: proxy.size.width))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                }
                .frame(height: Self.plot)
                Rule().padding(.leading, Self.axisWidth)
                ticks
            }
        }
    }

    // MARK: - Scale

    /// The band less the topmost mark's own hairline, so a column at the
    /// ceiling meets that line instead of running a pixel past it.
    private var plotHeight: CGFloat { max(1, Self.plot - 1) }

    /// The smallest step that rules the peak in `marks` lines or fewer.
    private var step: Int {
        Self.steps.first { forecast.peak <= $0 * Self.marks } ?? Self.steps[Self.steps.count - 1]
    }

    /// The top of the scale: a whole number of steps, so the highest mark is
    /// the top of the band rather than a line floating under the peak.
    private var ceiling: Int { max(step, (forecast.peak + step - 1) / step * step) }

    private var levels: [Int] { Array(stride(from: step, through: ceiling, by: step)) }

    private func height(_ count: Int) -> CGFloat {
        plotHeight * CGFloat(count) / CGFloat(max(1, ceiling))
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Eyebrow(eyebrow)
            Spacer(minLength: 12)
            HStack(spacing: 12) {
                if forecast.backlog > 0 {
                    key(Instrument.overdue, "overdue")
                }
                key(Instrument.alert, "today")
                key(Instrument.accent, "scheduled")
            }
        }
    }

    private func key(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            SeriesSwatch(color: color)
            Text(label)
                .font(Instrument.mono(10))
                .foregroundStyle(Instrument.ghost)
        }
    }

    // MARK: - Plot

    /// The scale, ruled across the plot and drawn behind the columns — a mark
    /// is a reference to read a column against, not something laid over it.
    private var grid: some View {
        ZStack(alignment: .bottomLeading) {
            ForEach(levels, id: \.self) { level in
                mark(level).offset(y: -height(level))
            }
        }
    }

    /// One mark: its figure in the gutter, its hairline across the plot. The
    /// row is pinned to a 1pt frame so the line, not the label, sits at the
    /// level.
    private func mark(_ level: Int) -> some View {
        HStack(spacing: Self.axisGap) {
            Text("\(level)")
                .font(Instrument.mono(9.5))
                .monospacedDigit()
                .foregroundStyle(Instrument.ghost)
                .fixedSize()
                .frame(width: Self.axisWidth - Self.axisGap, alignment: .trailing)
            Rectangle().fill(Instrument.hairline).frame(height: 1)
        }
        .frame(height: 1)
    }

    private func columns(thickness: CGFloat) -> some View {
        HStack(alignment: .bottom, spacing: 0) {
            if forecast.backlog > 0 {
                column(
                    forecast.backlog, color: Instrument.overdue, thickness: thickness,
                    caption: "\(forecast.backlog) overdue — "
                        + "already past the day \(forecast.backlog == 1 ? "it was" : "they were") due")
                    .frame(width: Self.backlogWidth)
                divider
            }
            HStack(alignment: .bottom, spacing: Self.spacing) {
                ForEach(forecast.days) { day in
                    column(
                        day.dueCount,
                        color: day.isToday ? Instrument.alert : Instrument.accent,
                        thickness: thickness, caption: Self.caption(day))
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.leading, Self.axisWidth)
    }

    /// What separates "already late" from "still to come". The backlog shares
    /// the axis but not the calendar, and a column chart with no break here
    /// would read as though the wall were due on a particular Tuesday.
    private var divider: some View {
        Rectangle()
            .fill(Instrument.rule)
            .frame(width: 1, height: Self.plot)
            .padding(.horizontal, Self.dividerAir)
    }

    /// One column, with the whole band above it as its hover target — the
    /// marks here are a few points wide and an empty day is a hairline, so a
    /// hit area the size of the mark would be unreachable.
    private func column(
        _ count: Int, color: Color, thickness: CGFloat, caption: String
    ) -> some View {
        ZStack(alignment: .bottom) {
            Color.clear.frame(height: Self.plot)
            Rectangle()
                .fill(count > 0 ? color : Instrument.well)
                // A day with nothing due still shows a tick on the baseline, so
                // the eye can count along the run and know which day it is on.
                .frame(width: thickness, height: max(1, height(count)))
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 3, topTrailingRadius: 3))
        }
        .contentShape(Rectangle())
        .help(caption)
    }

    /// A column takes its slot less the air, up to the cap.
    private func thickness(across width: CGFloat) -> CGFloat {
        let count = CGFloat(max(1, forecast.days.count))
        let lead = Self.axisWidth + (forecast.backlog > 0 ? Self.backlogZone : 0)
        let slot = (width - lead - Self.spacing * (count - 1)) / count
        return max(2, min(Self.maxThickness, slot - Self.minAir))
    }

    // MARK: - Axis and summary

    /// Today, then one date a week. Labels overflow their column rather than
    /// squeeze it — at four weeks a slot is narrower than the date in it.
    private var ticks: some View {
        HStack(spacing: 0) {
            if forecast.backlog > 0 {
                // Centred on the bar, not on the zone, so the label sits under
                // the thing it names rather than under the divider.
                Text("Behind")
                    .fixedSize()
                    .frame(width: Self.backlogWidth, height: Self.tickHeight)
                Color.clear
                    .frame(width: Self.backlogZone - Self.backlogWidth, height: Self.tickHeight)
            }
            HStack(spacing: Self.spacing) {
                ForEach(forecast.days) { day in
                    ZStack {
                        Color.clear.frame(height: Self.tickHeight)
                        if let tick = Self.tick(day) {
                            Text(tick).fixedSize()
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .font(Instrument.mono(10))
        .foregroundStyle(Instrument.ghost)
        .padding(.leading, Self.axisWidth)
        .padding(.top, 5)
    }

    /// What the band is, and the one figure it holds that no column can show:
    /// the cards scheduled past the window. Everything else the chart claims is
    /// now spelled out per deck in the shelf below it — overdue in *behind*,
    /// never-reviewed under the deck's name — so a line under the chart
    /// repeating them was clutter. This isn't in the shelf, and dropping it
    /// silently would let a band showing an empty month stand for a deck with
    /// two hundred cards in it.
    private var eyebrow: String {
        let span = "Load ahead · \(max(1, forecast.days.count / 7)) weeks"
        guard forecast.beyond > 0 else { return span }
        return span + " · \(forecast.beyond) further out"
    }

    private static func tick(_ day: ReviewForecast.Day) -> String? {
        if day.isToday { return "Today" }
        guard day.id.isMultiple(of: 7) else { return nil }
        return day.date.formatted(.dateTime.month(.abbreviated).day())
    }

    private static func caption(_ day: ReviewForecast.Day) -> String {
        let when = day.isToday
            ? "Today"
            : day.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        let due = day.dueCount == 1 ? "1 card due" : "\(day.dueCount) cards due"
        return "\(when) · \(day.dueCount == 0 ? "nothing due" : due) · "
            + "\(day.cumulative) waiting by then"
    }
}

/// One deck's week, small enough to sit in a table cell: what it is already
/// behind on, set off from a mark per day. The band's grammar at table scale —
/// same three hues, same backlog-then-days order — so a row is read with what
/// was just learned from the chart above it.
///
/// A sibling of `Sparkline`, not a use of it: that one ramps by *recency* over
/// a run it normalises to itself, and both halves of that are wrong here. A
/// mark's hue has to mean how urgent it is, and the scale has to be shared, or
/// a deck with one card a day would draw the same row as one with fifty.
struct ForecastSpark: View {
    let forecast: ReviewForecast
    /// The busiest day anywhere in the table. Rows share it so that height
    /// means the same thing down the column — being comparable is the whole
    /// reason these sit in a table rather than on their own pages.
    let ceiling: Int

    private static let height: CGFloat = 22
    private static let mark: CGFloat = 8
    private static let gap: CGFloat = 3
    /// Between the backlog mark and the week — the table-sized version of the
    /// band's divider, which at this scale can only be ground. Wide, because
    /// the two marks it separates are the closest pair in the palette: overdue
    /// and today are one step apart by design, and abutting at this size they
    /// would read as a single block.
    private static let split: CGFloat = 10
    /// A day with nothing due. Not zero height: the eye counts along the week
    /// to find a day, so a missing mark would shift every day after it.
    private static let restHeight: CGFloat = 2
    /// The shortest a real mark may be drawn — twice the resting tick, so one
    /// card never reads as no cards however tall the table's ceiling is.
    private static let minHeight: CGFloat = 4

    var body: some View {
        HStack(alignment: .bottom, spacing: Self.gap) {
            bar(forecast.backlog, color: Instrument.overdue)
                .padding(.trailing, Self.split - Self.gap)
            ForEach(forecast.days) { day in
                bar(
                    day.dueCount,
                    color: day.isToday ? Instrument.alert : Instrument.accent)
            }
        }
        .frame(height: Self.height, alignment: .bottom)
        .help(caption)
    }

    private func bar(_ count: Int, color: Color) -> some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(count > 0 ? color : Instrument.well)
            .frame(
                width: Self.mark,
                height: count > 0
                    ? max(
                        Self.minHeight,
                        Self.height * CGFloat(count) / CGFloat(max(1, ceiling)))
                    : Self.restHeight)
    }

    private var caption: String {
        let week = forecast.windowTotal
        let behind = forecast.backlog == 1 ? "1 behind" : "\(forecast.backlog) behind"
        let ahead = "\(week) due over the next \(forecast.days.count) days"
        return forecast.backlog > 0 ? "\(behind) · \(ahead)" : ahead
    }
}
