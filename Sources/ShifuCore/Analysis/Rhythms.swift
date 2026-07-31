import Foundation

/// What the *shape* of a week says, over and above its totals (design.md §7).
///
/// The week's rails already draw when each day started and when it stopped.
/// What they cannot draw is that the whole column has been sliding left —
/// that is a fact about the run of days, not about any one of them. This reads
/// the two ends of every night out of the ledger and reports a run of them
/// only when it is doing something worth a mark: drifting steadily one way, or
/// holding to a time.
///
/// Deliberately hard to please. A claim the user cannot check against their
/// own week costs more trust than it buys, so every threshold here is set to
/// say nothing rather than something shaky, and every signal carries the marks
/// it was fitted from — the view draws them on the rails, so the claim is
/// always readable straight off the thing it is about.
public enum Rhythms {

    // MARK: - What the ledger can actually see

    /// The shortest quiet stretch that reads as a night rather than a break.
    static let nightFloorMs: Int64 = 3 * 3_600_000
    /// And the longest. Past this the machine was away, not asleep: a weekend
    /// off is one 63-hour gap, and without a ceiling it would land as a single
    /// "night" charged to whichever day it happened to start on.
    static let nightCeilingMs: Int64 = 16 * 3_600_000
    /// The hour a gap has to cover to count as a night. Almost nobody is at a
    /// screen at 4 AM, and asking that the *gap contain it* is what lets one
    /// rule serve both the person who turns in at 23:30 and the person who
    /// turns in at 02:30 — no per-day bucketing, no cutoff to tune per user.
    static let deadOfNightHour = 4
    /// And the shortest stretch of screen that can end a night or begin one.
    /// Waking the machine at 09:06, watching a build for three minutes and
    /// going back to bed is not the morning — but it *is* a tracked run, and
    /// the sessionizer's two-minute fold leaves it standing alone. Left in, it
    /// takes the daybreak an hour earlier than the day started and plants the
    /// mark on a stretch of rail the ribbon draws as empty, which is the one
    /// thing a mark drawn on the evidence must never do.
    static let runFloorMs: Int64 = 10 * 60_000

    /// Minutes past midnight, with everything before noon pushed onto the
    /// previous evening's clock — so 23:50 reads as 1430 and 00:10 as 1450,
    /// twenty minutes apart rather than a day. Without this a fit over a run
    /// of bedtimes that straddles midnight sees a 24-hour lurch and either
    /// invents a trend or destroys a real one.
    static func nightMinutes(_ instant: Date, calendar: Calendar) -> Double {
        let minutes = dayMinutes(instant, calendar: calendar)
        return minutes < 12 * 60 ? minutes + 24 * 60 : minutes
    }

    /// Wall-clock minutes past midnight — the components, not the elapsed
    /// interval, because "what time did you stop" means the clock on the wall
    /// even on the two days a year the two disagree.
    static func dayMinutes(_ instant: Date, calendar: Calendar) -> Double {
        let parts = calendar.dateComponents([.hour, .minute], from: instant)
        return Double((parts.hour ?? 0) * 60 + (parts.minute ?? 0))
    }

    /// A settle outside this band is not a bedtime. An afternoon away can be
    /// long enough to cover 4 AM (14:00 → 05:00 is fifteen hours) and would
    /// otherwise be read as a spectacularly early night. On the night clock.
    static let settleFrom = 18.0 * 60
    static let settleUntil = 32.0 * 60
    /// And a rise outside this one is not a morning.
    static let riseFrom = 3.0 * 60
    static let riseUntil = 14.0 * 60

    // MARK: - Marks and nights

    /// One end of one night, and the rail it belongs on.
    public struct Mark: Identifiable, Sendable, Equatable {
        /// Local midnight of the day this mark is drawn against — a settle at
        /// 23:50 belongs to that evening's rail, the rise it leads to belongs
        /// to the next one.
        public let day: Date
        public let at: Date

        public var id: Double { at.timeIntervalSince1970 }

        public init(day: Date, at: Date) {
            self.day = day
            self.at = at
        }
    }

    /// A night as the ledger saw it. Either end is nil at the window's own
    /// boundary, where there is no block to bound the quiet, or when the end
    /// falls outside the hours a night can plausibly have.
    public struct Night: Sendable, Equatable {
        public let settled: Mark?
        public let stirred: Mark?
    }

    /// One untracked stretch, and whether a block bounds each of its ends —
    /// the window's own edges bound the first and last, and a boundary can
    /// only ever carry the one mark it has a block for.
    private struct Quiet {
        let from: Date
        let to: Date
        let closes: Bool
        let opens: Bool
    }

    /// Every night inside `[from, to)`, oldest first.
    public static func nights(
        _ activities: [LedgerBuilder.LabeledActivity], from: Date, to: Date,
        calendar: Calendar = .current
    ) -> [Night] {
        let runs = tracked(activities, from: from, to: to)
        guard !runs.isEmpty else { return [] }

        // The quiet stretches: before the first run, between each pair, and
        // after the last. The two at the ends are bounded by the window rather
        // than by a block, so they can only carry one mark — which is worth
        // having, since Monday's rise and this morning's settle both live
        // there and a week only has five of each.
        var quiets = [Quiet(from: from, to: runs[0].from, closes: false, opens: true)]
        for index in 1..<runs.count {
            quiets.append(
                Quiet(from: runs[index - 1].to, to: runs[index].from, closes: true, opens: true))
        }
        quiets.append(
            Quiet(from: runs[runs.count - 1].to, to: to, closes: true, opens: false))

        return quiets.compactMap { quiet in
            guard isNight(from: quiet.from, to: quiet.to, calendar: calendar) else { return nil }
            let settled = quiet.closes ? settleMark(quiet.from, calendar: calendar) : nil
            let stirred = quiet.opens ? riseMark(quiet.to, calendar: calendar) : nil
            guard settled != nil || stirred != nil else { return nil }
            return Night(settled: settled, stirred: stirred)
        }
    }

    /// The window's tracked stretches, clipped to it, folded together, and
    /// stripped of the ones too short to bound a night.
    ///
    /// Blocks in a real ledger abut, touch, and — after a bad rebuild — overlap
    /// outright, so this merges by span rather than trusting them to be
    /// disjoint. The fold tolerance is the sessionizer's own gap threshold: a
    /// shorter break than that did not split a block, so it must not open a
    /// night here either. What survives the fold and is still under
    /// `runFloorMs` was a genuinely isolated few minutes at the screen, and the
    /// quiet is allowed to close straight over it.
    private static func tracked(
        _ activities: [LedgerBuilder.LabeledActivity], from: Date, to: Date
    ) -> [(from: Date, to: Date)] {
        let fromMs = Int64(from.timeIntervalSince1970 * 1_000)
        let toMs = Int64(to.timeIntervalSince1970 * 1_000)
        let clipped = activities
            .compactMap { activity -> (start: Int64, end: Int64)? in
                let start = max(activity.startedAt, fromMs)
                let end = min(activity.endedAt, toMs)
                return end > start ? (start, end) : nil
            }
            .sorted { $0.start < $1.start }

        var runs: [(start: Int64, end: Int64)] = []
        for span in clipped {
            if let last = runs.last, span.start - last.end <= Sessionizer.gapThresholdMs {
                runs[runs.count - 1].end = max(last.end, span.end)
            } else {
                runs.append(span)
            }
        }
        return runs
            .filter { $0.end - $0.start >= runFloorMs }
            .map {
                (Date(timeIntervalSince1970: Double($0.start) / 1_000),
                 Date(timeIntervalSince1970: Double($0.end) / 1_000))
            }
    }

    private static func isNight(from: Date, to: Date, calendar: Calendar) -> Bool {
        let length = Int64(to.timeIntervalSince(from) * 1_000)
        guard length >= nightFloorMs, length <= nightCeilingMs else { return false }
        // At most sixteen hours long, so it can only ever cover one of these.
        let midnight = calendar.startOfDay(for: from)
        return (0...1).contains { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: midnight),
                  let instant = calendar.date(byAdding: .hour, value: deadOfNightHour, to: day)
            else { return false }
            return instant >= from && instant < to
        }
    }

    private static func settleMark(_ at: Date, calendar: Calendar) -> Mark? {
        let minutes = nightMinutes(at, calendar: calendar)
        guard minutes >= settleFrom, minutes < settleUntil else { return nil }
        return Mark(day: calendar.startOfDay(for: at), at: at)
    }

    private static func riseMark(_ at: Date, calendar: Calendar) -> Mark? {
        let minutes = dayMinutes(at, calendar: calendar)
        guard minutes >= riseFrom, minutes < riseUntil else { return nil }
        return Mark(day: calendar.startOfDay(for: at), at: at)
    }

    // MARK: - Signals

    /// Which end of the night a signal reads.
    public enum Edge: String, Sendable {
        case nightfall, daybreak
    }

    /// What a run of marks is doing.
    public enum Shape: Sendable, Equatable {
        /// Moving, at this many minutes a day. Negative is earlier.
        case drifting(minutesPerDay: Double)
        /// Holding, within `spread` minutes either side of `centre` (minutes
        /// past midnight, on that edge's clock).
        case steady(centre: Double, spread: Double)
    }

    /// A run of marks that is doing something, and the marks behind it.
    public struct Signal: Identifiable, Sendable, Equatable {
        public let edge: Edge
        public let shape: Shape
        /// Oldest first — the run the shape was fitted from.
        public let marks: [Mark]

        public var id: String { edge.rawValue }
    }

    /// Fewer than this is an anecdote. Two points are a line through anything,
    /// so three is the smallest run that can disagree with itself.
    static let minimumMarks = 3
    /// Under this a "trend" is inside the noise of when a laptop lid happens
    /// to close.
    static let minimumSlopeMinutes = 8.0
    /// And the whole run has to have moved somewhere worth saying out loud.
    static let minimumDriftMinutes = 40.0
    /// How straight the run has to be, as |r|. A week gives three or four
    /// points; at that count a low bar fits a line to anything.
    static let minimumAgreement = 0.8
    /// Half the range a run may span and still read as one time of day.
    static let steadySpreadMinutes = 25.0

    /// What is worth marking on `[from, to)`. At most one signal per edge —
    /// a run is either drifting or holding, never both.
    public static func signals(
        _ activities: [LedgerBuilder.LabeledActivity], from: Date, to: Date,
        calendar: Calendar = .current
    ) -> [Signal] {
        let nights = nights(activities, from: from, to: to, calendar: calendar)
        return [
            signal(.nightfall, from: nights.compactMap(\.settled), calendar: calendar),
            signal(.daybreak, from: nights.compactMap(\.stirred), calendar: calendar)
        ].compactMap { $0 }
    }

    private static func signal(
        _ edge: Edge, from marks: [Mark], calendar: Calendar
    ) -> Signal? {
        guard marks.count >= minimumMarks, let origin = marks.first else { return nil }
        let base = index(of: origin, edge: edge, calendar: calendar)
        let points = marks.map { mark in
            (x: Double(calendar.dateComponents(
                [.day], from: base,
                to: index(of: mark, edge: edge, calendar: calendar)).day ?? 0),
             y: edge == .nightfall
                ? nightMinutes(mark.at, calendar: calendar)
                : dayMinutes(mark.at, calendar: calendar))
        }
        let span = (points.last?.x ?? 0) - (points.first?.x ?? 0)

        // Drifting wins the tie: a run can be tight enough to read as steady
        // and still be sliding, and "moving" is the more useful of the two
        // things to be told about your own week.
        if let line = fit(points), abs(line.slope) >= minimumSlopeMinutes,
           abs(line.slope) * span >= minimumDriftMinutes,
           abs(line.correlation) >= minimumAgreement {
            return Signal(edge: edge, shape: .drifting(minutesPerDay: line.slope), marks: marks)
        }

        let clock = points.map(\.y)
        guard let low = clock.min(), let high = clock.max(),
              (high - low) / 2 <= steadySpreadMinutes
        else { return nil }
        return Signal(
            edge: edge, shape: .steady(centre: (high + low) / 2, spread: (high - low) / 2),
            marks: marks)
    }

    /// The night a mark belongs to, as a day. A settle from 18:00 on counts
    /// against the morning it leads to, so an evening and the small hours
    /// after it are one night rather than two days.
    private static func index(of mark: Mark, edge: Edge, calendar: Calendar) -> Date {
        guard edge == .nightfall, calendar.component(.hour, from: mark.at) >= 12
        else { return mark.day }
        return calendar.date(byAdding: .day, value: 1, to: mark.day) ?? mark.day
    }

    /// Least squares, with Pearson's r for how much the line deserves to be
    /// believed. Nil when the run has no spread on an axis to fit against —
    /// a perfectly flat run of bedtimes is steady, not a zero-slope trend.
    private static func fit(
        _ points: [(x: Double, y: Double)]
    ) -> (slope: Double, correlation: Double)? {
        let count = Double(points.count)
        guard count >= 2 else { return nil }
        let meanX = points.reduce(0) { $0 + $1.x } / count
        let meanY = points.reduce(0) { $0 + $1.y } / count
        var covariance = 0.0
        var spreadX = 0.0
        var spreadY = 0.0
        for point in points {
            let offsetX = point.x - meanX
            let offsetY = point.y - meanY
            covariance += offsetX * offsetY
            spreadX += offsetX * offsetX
            spreadY += offsetY * offsetY
        }
        guard spreadX > 0, spreadY > 0 else { return nil }
        return (covariance / spreadX, covariance / (spreadX * spreadY).squareRoot())
    }
}

// MARK: - How a signal reads

extension Rhythms.Signal {
    /// "settling 38m earlier each night", "starting around 7:15 AM, ± 9m".
    public var headline: String {
        switch shape {
        case .drifting(let minutesPerDay):
            return "\(edge.verb) \(Rhythms.span(abs(minutesPerDay))) "
                + "\(minutesPerDay < 0 ? "earlier" : "later") \(edge.cadence)"
        case .steady(let centre, let spread):
            return "\(edge.verb) around \(clockLabel(centre)), ± \(Rhythms.span(spread))"
        }
    }

    /// The run itself: where it started and where it has got to.
    public var detail: String {
        guard let first = marks.first, let last = marks.last else { return "" }
        return "\(Rhythms.stamp(first.at)) → \(Rhythms.stamp(last.at))"
    }

    /// What was actually measured, for the tooltip — the headline is a
    /// reading, and this is the thing it was read from.
    public var note: String {
        switch edge {
        case .nightfall:
            return "The last block before the night's quiet, over \(marks.count) nights."
        case .daybreak:
            return "The first block after the night's quiet, over \(marks.count) mornings."
        }
    }

    /// What one mark of this signal is, for the tooltip over it on the rail.
    public func caption(_ mark: Rhythms.Mark) -> String {
        let what = edge == .nightfall ? "Last block of the night" : "First block of the day"
        return "\(what) — \(Rhythms.stamp(mark.at))"
    }

    private func clockLabel(_ minutes: Double) -> String {
        let calendar = Calendar.current
        let base = calendar.startOfDay(for: marks.last?.at ?? Date())
        let wrapped = minutes.truncatingRemainder(dividingBy: 24 * 60)
        return base.addingTimeInterval(wrapped * 60)
            .formatted(date: .omitted, time: .shortened)
    }
}

extension Rhythms.Edge {
    var verb: String {
        switch self {
        case .nightfall: return "settling"
        case .daybreak: return "starting"
        }
    }

    var cadence: String {
        switch self {
        case .nightfall: return "each night"
        case .daybreak: return "each morning"
        }
    }
}

extension Rhythms {
    /// "38m", "1h 5m" — the register the ledger's other durations use.
    static func span(_ minutes: Double) -> String {
        let whole = Int(minutes.rounded())
        guard whole >= 60 else { return "\(whole)m" }
        let rest = whole % 60
        return rest == 0 ? "\(whole / 60)h" : "\(whole / 60)h \(rest)m"
    }

    /// "Tue, 2:24 AM" — in the user's locale, like every other timestamp.
    public static func stamp(_ at: Date) -> String {
        at.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}
