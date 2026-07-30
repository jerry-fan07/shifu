import ShifuCore
import SwiftUI

/// Turns labelled blocks into the shapes the Instrument layout draws: the day
/// as a single ribbon, the Timeline's stacked bars, and eight weeks of a theme
/// as a sparkline.
///
/// Pure functions over already-read rows — no database, no clock of their own —
/// so what the ribbon claims can be checked in a test.
enum LedgerShapes {
    /// The stretch of clock a ribbon covers, as hour-of-day bounds.
    ///
    /// Hours rather than dates because the week view draws one rail per day on
    /// a *shared* clock: an absolute window would make Monday's rail span from
    /// Monday morning to Thursday lunchtime, which is how you get seven rails
    /// that each show the whole week.
    struct Clock: Equatable {
        var startHour: Int
        var endHour: Int

        var span: Int { max(1, endHour - startHour) }

        /// This clock placed on one particular day.
        func on(_ day: Date, calendar: Calendar = .current) -> (from: Date, to: Date) {
            let midnight = calendar.startOfDay(for: day)
            return (
                calendar.date(byAdding: .hour, value: startHour, to: midnight) ?? midnight,
                calendar.date(byAdding: .hour, value: endHour, to: midnight) ?? midnight)
        }
    }

    /// The hours worth drawing: the earliest hour any block starts to the last
    /// hour any block ends, over the blocks *inside* `from...to`. An eight-hour
    /// day then fills the rail instead of sitting in the middle of a
    /// twenty-four-hour one. Empty windows fall back to a working day.
    static func clock(
        _ activities: [LedgerBuilder.LabeledActivity], from: Date, to: Date,
        calendar: Calendar = .current
    ) -> Clock {
        let fromMs = Int64(from.timeIntervalSince1970 * 1_000)
        let toMs = Int64(to.timeIntervalSince1970 * 1_000)
        var earliest = 24
        var latest = 0
        for activity in activities {
            let start = max(activity.startedAt, fromMs)
            let end = min(activity.endedAt, toMs)
            guard end > start else { continue }
            let startDate = Date(timeIntervalSince1970: Double(start) / 1_000)
            let endDate = Date(timeIntervalSince1970: Double(end) / 1_000)
            earliest = min(earliest, calendar.component(.hour, from: startDate))
            // Round the closing hour up, so a block ending at 17:20 shows the
            // rail running to 18 rather than being clipped mid-block.
            let endHour = calendar.component(.hour, from: endDate)
            let endMinute = calendar.component(.minute, from: endDate)
            latest = max(latest, endMinute > 0 || endHour == 0 ? endHour + 1 : endHour)
        }
        guard earliest < 24, latest > earliest else { return Clock(startHour: 7, endHour: 22) }
        // Three hours is the narrowest rail that still reads as a day.
        return Clock(startHour: earliest, endHour: max(latest, earliest + 3))
    }

    /// How many slots the rail is resampled into. A day of heartbeat-sized
    /// blocks would otherwise draw a barcode: 197 blocks of forty seconds each
    /// is *true*, and completely unreadable. Each column takes the group that
    /// held most of it, and equal neighbours merge — so the ribbon shows the
    /// shape of the morning, which is what it is for.
    static let columns = 200
    /// A column with less than this fraction of it tracked reads as a gap.
    private static let coverage = 0.25

    /// The window, resampled into bands. Gaps are preserved; everything else
    /// is the dominant group of its stretch.
    ///
    /// Blocks whose category is `private` draw hatched whatever the lens is:
    /// that time was measured but never read, and the ribbon should say so.
    static func ribbon(
        _ activities: [LedgerBuilder.LabeledActivity], lens: TimeLens,
        colors: [String: Color], from: Date, to: Date
    ) -> [RibbonSegment] {
        let fromMs = Int64(from.timeIntervalSince1970 * 1_000)
        let toMs = Int64(to.timeIntervalSince1970 * 1_000)
        guard toMs > fromMs else { return [] }
        let columnMs = Double(toMs - fromMs) / Double(columns)
        guard columnMs > 0 else { return [] }

        // column → group → ms, where nil group is time that was measured but
        // never read.
        var tallies = [[String?: Double]](repeating: [:], count: columns)
        for activity in activities {
            let start = max(activity.startedAt, fromMs)
            let end = min(activity.endedAt, toMs)
            guard end > start else { continue }
            let group: String? = activity.category == "private" ? nil : lens.label(activity)
            let first = Int(Double(start - fromMs) / columnMs)
            let last = Int(Double(end - fromMs - 1) / columnMs)
            for column in max(0, first)...min(columns - 1, max(0, last)) {
                let columnStart = Double(fromMs) + Double(column) * columnMs
                let overlap = min(Double(end), columnStart + columnMs)
                    - max(Double(start), columnStart)
                guard overlap > 0 else { continue }
                tallies[column][group, default: 0] += overlap
            }
        }

        var segments: [RibbonSegment] = []
        for tally in tallies {
            let tracked = tally.values.reduce(0, +)
            // The pair, not its key: the key is itself optional (nil means
            // private), and unwrapping straight to it would flatten "no
            // winner" and "the winner is private" into the same thing.
            guard tracked >= columnMs * coverage,
                  let winner = tally.max(by: { $0.value < $1.value })
            else {
                append(&segments, fill: .gap, caption: "")
                continue
            }
            if let group = winner.key {
                append(
                    &segments, fill: .series(colors[group] ?? Instrument.other),
                    caption: group)
            } else {
                append(&segments, fill: .hidden, caption: "Private — never read")
            }
        }
        return segments
    }

    /// Appends one column, folding it into the previous band when it is the
    /// same — the merge that turns two hundred columns back into a dozen
    /// stretches you can point at.
    private static func append(
        _ segments: inout [RibbonSegment], fill: RibbonSegment.Fill, caption: String
    ) {
        if let last = segments.last, last.fill == fill, last.caption == caption {
            segments[segments.count - 1] = RibbonSegment(
                id: last.id, weight: last.weight + 1, fill: fill, caption: caption)
            return
        }
        segments.append(RibbonSegment(
            id: segments.count, weight: 1, fill: fill, caption: caption))
    }

    /// One column's stretch of clock, with the axis label it wears — empty
    /// for hours that go unticked.
    struct Slot {
        let tick: String
        let from: Date
        let to: Date
    }

    /// The Timeline's chart: each slot of clock tallied and stacked by group.
    /// Slots are whatever stretch the caller cuts — the hours of a day, the
    /// days of a week.
    ///
    /// Groups stack in `order` — the Breakdown's ranking — so a group holds
    /// the same place in every column; anything `order` doesn't name is still
    /// drawn, after it, rather than silently dropped. A label the palette
    /// doesn't carry folds into "Other" the way the table folds it, and
    /// private time rides on top, hatched, whatever the lens is.
    static func bars(
        _ activities: [LedgerBuilder.LabeledActivity], lens: TimeLens,
        colors: [String: Color], order: [String], slots: [Slot]
    ) -> [BarStack] {
        slots.enumerated().map { index, slot in
            let fromMs = Int64(slot.from.timeIntervalSince1970 * 1_000)
            let toMs = Int64(slot.to.timeIntervalSince1970 * 1_000)
            var tallies: [String: Int64] = [:]
            var privateMs: Int64 = 0
            for activity in activities {
                let ms = min(activity.endedAt, toMs) - max(activity.startedAt, fromMs)
                guard ms > 0 else { continue }
                guard activity.category != "private" else {
                    privateMs += ms
                    continue
                }
                let label = lens.label(activity)
                let group = colors[label] != nil ? label : TimeBreakdown.otherLabel
                tallies[group, default: 0] += ms
            }

            let ranked = order.filter { tallies[$0] != nil }
                + tallies.keys
                    .filter { !order.contains($0) }
                    .sorted { (tallies[$0] ?? 0) > (tallies[$1] ?? 0) }
            var segments = ranked.enumerated().map { position, name in
                BarStack.Segment(
                    id: position, ms: tallies[name] ?? 0,
                    fill: .series(colors[name] ?? Instrument.other),
                    caption: "\(lens.display(name)) — "
                        + TimeBreakdown.duration(tallies[name] ?? 0))
            }
            if privateMs > 0 {
                segments.append(BarStack.Segment(
                    id: segments.count, ms: privateMs, fill: .hidden,
                    caption: "Private — never read · "
                        + TimeBreakdown.duration(privateMs)))
            }
            return BarStack(id: index, tick: slot.tick, segments: segments)
        }
    }

    /// The hours to tick under a rail: at most `limit`, evenly spaced, always
    /// including the first.
    static func ticks(_ clock: Clock, limit: Int = 8) -> [Int] {
        let step = max(1, Int((Double(clock.span) / Double(limit)).rounded(.up)))
        return stride(from: 0, to: clock.span, by: step).map { (clock.startHour + $0) % 24 }
    }

    /// Weekly totals per group over the trailing `weeks` calendar weeks,
    /// oldest first. Groups that never appear are absent; a group that appears
    /// always gets the full run of buckets, zeros included, so every sparkline
    /// in a table is the same width and covers the same weeks.
    static func weeklyTotals(
        _ activities: [LedgerBuilder.LabeledActivity], weeks: Int,
        now: Date = Date(), calendar: Calendar = .current,
        group: (LedgerBuilder.LabeledActivity) -> String?
    ) -> [String: [Double]] {
        let thisWeek = calendar.startOfWeek(for: now)
        var totals: [String: [Double]] = [:]
        for activity in activities {
            guard let name = group(activity) else { continue }
            let start = Date(timeIntervalSince1970: Double(activity.startedAt) / 1_000)
            let weekStart = calendar.startOfWeek(for: start)
            let back = calendar.dateComponents(
                [.weekOfYear], from: weekStart, to: thisWeek).weekOfYear ?? 0
            let bucket = weeks - 1 - back
            guard bucket >= 0, bucket < weeks else { continue }
            var run = totals[name] ?? Array(repeating: 0, count: weeks)
            run[bucket] += Double(activity.endedAt - activity.startedAt)
            totals[name] = run
        }
        return totals
    }
}

extension RibbonSegment.Fill: Equatable {
    static func == (lhs: RibbonSegment.Fill, rhs: RibbonSegment.Fill) -> Bool {
        switch (lhs, rhs) {
        case (.gap, .gap), (.hidden, .hidden): return true
        case (.series(let left), .series(let right)): return left == right
        default: return false
        }
    }
}
