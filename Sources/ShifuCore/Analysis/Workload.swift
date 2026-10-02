import Foundation

/// How the week's hours are spread across everything being carried at once,
/// and whether that spread is being kept up (design.md §4.6).
///
/// The ledger already says where the time went. What it cannot say on its own
/// is whether *enough* of it went to each thing you are in the middle of — a
/// front — and whether the whole set is more than the hours you have been
/// giving it. This reads eight rolling weeks of blocks and answers that with
/// one verdict and two lists: what to give time, and what has gone quiet.
///
/// Deliberately hard to please, like `Rhythms`: every verdict carries the
/// figures it was fitted from, and the one about *you* — slack — needs the
/// screen to have been just as busy, or it is a week away being mistaken for
/// a week lost. Pure over already-read rows: no database, no clock, no model.
public enum Workload {

    // MARK: - Inputs

    /// One ledger block with its task and theme resolved. `taskID` is nil for
    /// a block the grouper left unplaced, `themeKey` for one the clusterer
    /// has not filed; `themeID` is nil whenever the key has no `themes` row
    /// (a proposal is not a theme).
    public struct Block: Sendable, Equatable {
        public let startedAt: Int64
        public let endedAt: Int64
        public let category: String
        public let taskID: Int64?
        public let taskName: String?
        public let themeID: Int64?
        public let themeName: String?

        public init(
            startedAt: Int64, endedAt: Int64, category: String,
            taskID: Int64? = nil, taskName: String? = nil,
            themeID: Int64? = nil, themeName: String? = nil
        ) {
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.category = category
            self.taskID = taskID
            self.taskName = taskName
            self.themeID = themeID
            self.themeName = themeName
        }
    }

    /// What a front is: a task (the default — where the work actually is) or
    /// a theme (the initiatives the user named).
    public enum Unit: String, Sendable, CaseIterable, Hashable {
        case task, theme
    }

    // MARK: - The thresholds

    /// Rolling weeks read; index 0 is the seven days ending now.
    public static let weeks = 8
    public static let weekMs: Int64 = 7 * 86_400_000
    /// Weeks 1…4 are the history a front and the week are measured against.
    static let historyWeeks = 1...4
    /// Time across weeks 0–3 a task needs to count as a front at all. A
    /// roster is mostly one-off minutes; without a floor every stray
    /// twenty-minute subject is a "front" being neglected.
    static let frontFloorMs: Int64 = 60 * 60_000
    /// Established: worked in at least this many of weeks 1–3, so "slipping"
    /// is a change in a habit rather than a habit that never was.
    static let establishedWeeks = 2
    /// Slipping: this week under this share of the four-week mean…
    static let slippingShare = 0.25
    /// …and the mean itself is worth keeping up. An hour a week is the
    /// smallest habit worth a word: on the 2026-10-02 dogfood ledger the
    /// fronts under it were a lab setup and a reading list, both of them
    /// finished rather than neglected, and calling them slipping tipped the
    /// whole week into "spread thin".
    static let slippingMeanFloorMs: Int64 = 60 * 60_000
    static let risingShare = 1.5
    /// Quiet after this long untouched; new while first seen inside it.
    static let quietMs: Int64 = 14 * 86_400_000
    /// Weeks 1–4 with any tracked time needed before the week has a baseline.
    static let baselineWeeksNeeded = 3
    /// Spread thin: this many *effective* fronts (the entropy figure, not the
    /// headcount) with two or more slipping.
    static let spreadFronts = 5.0
    static let spreadSlipping = 2
    /// Slack: focused hours under this share of the baseline…
    static let slackShare = 0.7
    /// …while tracked hours held at least this share of theirs. Both falling
    /// is a week away from the screen, and that is not a verdict about focus.
    static let awayShare = 0.8
    /// Behind on a deadline: needed pace more than this many times the pace
    /// it is getting. Exactly on pace is not behind.
    static let behindRatio = 1.25
    /// A front counts as active this week from this much time.
    static let activeFloorMs: Int64 = 30 * 60_000

    // MARK: - Outputs

    public enum Status: String, Sendable, Equatable {
        case new, rising, steady, slipping, quiet
    }

    /// A front's open deadline, read as a pace: what it still needs per week
    /// against what it is getting. Nil-targeted deadlines carry only a date.
    public struct Pace: Sendable, Equatable {
        public let deadlineID: Int64
        public let title: String
        public let daysLeft: Int
        /// Effort still owed, or nil for a date-only deadline.
        public let remainingMs: Int64?
        /// Per week, from the remaining effort over the days left. Nil when
        /// there is no target, nothing left, or the date has passed — an
        /// overdue promise is flagged, not divided by zero into infinity.
        public let neededMsPerWeek: Int64?
        /// Per week, from the last seven days — or, for a deadline younger
        /// than that, from the days since it was made, scaled up: a promise
        /// made yesterday has not had a week to be kept.
        public let gettingMsPerWeek: Int64

        public var isOverdue: Bool { daysLeft < 0 }
        public var isBehind: Bool {
            guard let needed = neededMsPerWeek else { return false }
            return Double(needed) > Double(gettingMsPerWeek) * behindRatio
        }
    }

    public struct Front: Identifiable, Sendable, Equatable {
        public let id: String
        public let taskID: Int64?
        public let themeID: Int64?
        public let name: String
        /// The task's theme under the task unit; nil under the theme unit.
        public let themeName: String?
        /// Ms per rolling week, index 0 = this week, `weeks` long.
        public let weekly: [Int64]
        public let firstSeenAt: Int64
        public let lastActiveAt: Int64
        public let status: Status
        /// The soonest open deadline on this task, nil under the theme unit.
        public let pace: Pace?

        public var thisWeekMs: Int64 { weekly[0] }
        /// Mean of weeks 1–4.
        public var meanMs: Int64 {
            historyWeeks.reduce(0) { $0 + weekly[$1] } / Int64(historyWeeks.count)
        }
        /// Slipping, behind a deadline, or overdue with effort still owed.
        public var wantsTime: Bool {
            if status == .slipping { return true }
            guard let pace else { return false }
            return pace.isBehind || (pace.isOverdue && (pace.remainingMs ?? 0) > 0)
        }
        /// Untouched for a fortnight with nothing promised against it.
        public var isDroppable: Bool { status == .quiet && pace == nil }
    }

    public enum Verdict: String, Sendable, Equatable {
        /// Fewer than three of the last four weeks have anything in them.
        case tooEarly
        case holding
        /// Deadline demand exceeds the hours the fronts have been getting.
        case overCommitted
        /// Many effective fronts, several of them slipping.
        case spreadThin
        /// Focused hours fell against the baseline while tracked hours held.
        case slack
        /// Both fell: a lighter week at the screen altogether.
        case away
    }

    public struct Reading: Sendable, Equatable {
        public let unit: Unit
        /// This week's time first, then the mean.
        public let fronts: [Front]
        /// Focused ms per rolling week: time on a work- or learning-dominant
        /// task whatever the block's own label, plus unplaced work and
        /// learning blocks. Index 0 is this week.
        public let capacity: [Int64]
        /// Every tracked ms per rolling week, same shape.
        public let tracked: [Int64]
        /// Median focused ms of weeks 1–4; nil until enough of them have data.
        public let baselineMs: Int64?
        public let trackedBaselineMs: Int64?
        /// exp(entropy) of this week's shares across fronts: how many fronts
        /// the week *behaved* like, so twelve at twenty minutes and three at
        /// two hours read differently.
        public let effectiveFronts: Double
        public let activeFronts: Int
        /// Σ needed pace across deadlines with effort still owed and days left.
        public let demandMsPerWeek: Int64
        /// Open deadlines with no task behind them — nothing to pace.
        public let unattached: [DeadlineHorizon.Standing]
        public internal(set) var verdict: Verdict

        public var giveTime: [Front] { fronts.filter(\.wantsTime).sorted(by: Self.urgency) }
        public var quiet: [Front] { fronts.filter(\.isDroppable) }
        public var slipping: [Front] { fronts.filter { $0.status == .slipping } }

        /// Behind a deadline first, nearest date first; then slipping, the
        /// larger habit first.
        private static func urgency(_ lhs: Front, _ rhs: Front) -> Bool {
            switch (lhs.pace, rhs.pace) {
            case let (left?, right?): return left.daysLeft < right.daysLeft
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return lhs.meanMs > rhs.meanMs
            }
        }
    }

    // MARK: - Reading

    public static func read(
        blocks: [Block], deadlines: [DeadlineHorizon.Standing] = [],
        unit: Unit = .task, now: Int64, calendar: Calendar = .current
    ) -> Reading {
        let keyed = Keyed(blocks: blocks, unit: unit, now: now)
        let open = deadlines.filter { !$0.deadline.isDone }
        var fronts: [Front] = []
        for (key, group) in keyed.groups {
            let pace = unit == .task
                ? paceFor(taskID: key.taskID, group: group, deadlines: open, now: now, calendar: calendar)
                : nil
            guard let front = front(key: key, group: group, pace: pace, now: now) else { continue }
            fronts.append(front)
        }
        fronts.sort { ($0.thisWeekMs, $0.meanMs, $0.name) > ($1.thisWeekMs, $1.meanMs, $1.name) }

        let baseline = median(keyed.capacity, requiring: keyed.tracked)
        let trackedBaseline = median(keyed.tracked, requiring: keyed.tracked)
        let demand = fronts.reduce(Int64(0)) { $0 + ($1.pace?.neededMsPerWeek ?? 0) }
        let effective = effectiveCount(fronts.map(\.thisWeekMs))
        let active = fronts.filter { $0.thisWeekMs >= activeFloorMs }.count
        let attached = Set(fronts.compactMap(\.taskID))
        let unattached = open.filter { $0.deadline.taskID.map { !attached.contains($0) } ?? true }
        var reading = Reading(
            unit: unit, fronts: fronts, capacity: keyed.capacity, tracked: keyed.tracked,
            baselineMs: baseline, trackedBaselineMs: trackedBaseline,
            effectiveFronts: effective, activeFronts: active,
            demandMsPerWeek: demand, unattached: unattached, verdict: .tooEarly)
        reading.verdict = verdict(reading)
        return reading
    }

    // MARK: - Fronts

    private static func front(key: Key, group: Group, pace: Pace?, now: Int64) -> Front? {
        guard group.isFocused else { return nil }
        let recent = (0..<4).reduce(Int64(0)) { $0 + group.weekly[$1] }
        guard recent >= frontFloorMs || pace != nil else { return nil }
        let id = key.taskID.map { "task:\($0)" } ?? "theme:\(key.themeID ?? 0)"
        return Front(
            id: id, taskID: key.taskID, themeID: key.themeID,
            name: group.name, themeName: group.themeName, weekly: group.weekly,
            firstSeenAt: group.firstSeenAt, lastActiveAt: group.lastActiveAt,
            status: status(group, now: now), pace: pace)
    }

    static func status(_ group: Group, now: Int64) -> Status {
        if group.lastActiveAt < now - quietMs { return .quiet }
        if group.firstSeenAt >= now - quietMs { return .new }
        let worked = (1...3).filter { group.weekly[$0] > 0 }.count
        let mean = historyWeeks.reduce(Int64(0)) { $0 + group.weekly[$1] } / Int64(historyWeeks.count)
        let thisWeek = Double(group.weekly[0])
        if worked >= establishedWeeks, mean >= slippingMeanFloorMs,
           thisWeek < Double(mean) * slippingShare {
            return .slipping
        }
        if mean > 0, thisWeek >= Double(mean) * risingShare { return .rising }
        return .steady
    }

    // MARK: - Deadlines as pace

    private static func paceFor(
        taskID: Int64?, group: Group, deadlines: [DeadlineHorizon.Standing],
        now: Int64, calendar: Calendar
    ) -> Pace? {
        guard let taskID else { return nil }
        let own = deadlines
            .filter { $0.deadline.taskID == taskID }
            .sorted { $0.deadline.dueAt < $1.deadline.dueAt }
        guard let standing = own.first, let deadlineID = standing.deadline.id else { return nil }
        return pace(standing, id: deadlineID, group: group, now: now, calendar: calendar)
    }

    static func pace(
        _ standing: DeadlineHorizon.Standing, id: Int64, group: Group,
        now: Int64, calendar: Calendar
    ) -> Pace {
        let deadline = standing.deadline
        let daysLeft = DeadlineHorizon.daysUntil(dueAt: deadline.dueAt, now: now, calendar: calendar)
        let remaining = deadline.targetMs.map { max(0, $0 - standing.loggedMs) }
        var needed: Int64?
        if let remaining, remaining > 0, daysLeft >= 0 {
            needed = remaining * 7 / Int64(max(1, daysLeft))
        }
        // Getting: the last seven days, or the deadline's own lifetime scaled
        // to a week when it is younger than that.
        let age = now - deadline.createdAt
        let getting: Int64
        if age < weekMs, age > 0 {
            let since = group.blocks.reduce(Int64(0)) { sum, block in
                sum + max(0, min(block.endedAt, now) - max(block.startedAt, deadline.createdAt))
            }
            getting = since * weekMs / age
        } else {
            getting = group.weekly[0]
        }
        return Pace(
            deadlineID: id, title: deadline.title, daysLeft: daysLeft,
            remainingMs: remaining, neededMsPerWeek: needed, gettingMsPerWeek: getting)
    }

    // MARK: - The week

    /// Median of weeks 1–4, or nil unless `baselineWeeksNeeded` of them have
    /// any time in `requiring` — a baseline fitted over two weeks is a guess.
    static func median(_ series: [Int64], requiring tracked: [Int64]) -> Int64? {
        let weeksWithData = historyWeeks.filter { tracked[$0] > 0 }.count
        guard weeksWithData >= baselineWeeksNeeded else { return nil }
        let sorted = historyWeeks.map { series[$0] }.sorted()
        let mid = sorted.count / 2
        return (sorted[mid - 1] + sorted[mid]) / 2
    }

    /// exp(H) over the shares: 1 when one front held the whole week, N when N
    /// fronts held it evenly. Zero when nothing was worked.
    static func effectiveCount(_ values: [Int64]) -> Double {
        let total = values.reduce(0, +)
        guard total > 0 else { return 0 }
        var entropy = 0.0
        for value in values where value > 0 {
            let share = Double(value) / Double(total)
            entropy -= share * log(share)
        }
        return exp(entropy)
    }

    static func verdict(_ reading: Reading) -> Verdict {
        guard let baseline = reading.baselineMs, let trackedBaseline = reading.trackedBaselineMs
        else { return .tooEarly }
        if reading.demandMsPerWeek > max(reading.capacity[0], baseline) { return .overCommitted }
        if reading.effectiveFronts >= spreadFronts, reading.slipping.count >= spreadSlipping {
            return .spreadThin
        }
        if Double(reading.capacity[0]) < Double(baseline) * slackShare {
            let held = Double(reading.tracked[0]) >= Double(trackedBaseline) * awayShare
            return held ? .slack : .away
        }
        return .holding
    }
}
