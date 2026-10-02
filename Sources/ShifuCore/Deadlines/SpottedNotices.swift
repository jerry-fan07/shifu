import Foundation

/// One banner about spotted dates: the day's roll-up, or one urgent date.
/// Top-level rather than nested, like `DeadlineAnnouncement`, for the
/// `nesting` rule and because it is the thing that travels.
public struct SpottedNotice: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case rollup
        case urgent
    }

    public var kind: Kind
    /// Stable per (day) or per (proposal), so a repeated post replaces
    /// rather than stacks.
    public var identifier: String
    public var title: String
    public var body: String
    public var proposalIDs: [Int64]
}

/// What Shifu says about a date it spotted, and when (design.md §4.7).
///
/// Bounded differently from `DeadlineHorizon`, because the thing being
/// announced is a guess rather than a promise. A typed deadline earns five
/// notices over its life; a spotted date earns **one line in one roll-up**,
/// at most one roll-up a day, and only if the scout ranked it high or
/// critical. The single exception is a critical date inside two days, which
/// is announced at once — a Saturday sighting of "sign up by Monday 11:59"
/// cannot wait for Monday's roll-up. Every proposal is named at most once,
/// ever (`notified_at`); accepting one is what buys it a schedule.
public enum SpottedNotices {
    public typealias Notice = SpottedNotice

    /// Lines in a roll-up. Three reads in a banner; the rest wait a day.
    public static let rollupLimit = 3
    /// A critical date this close is announced on sight.
    public static let urgentWithinDays = 2
    /// Settings key: the local day (yyyy-mm-dd) of the last roll-up.
    public static let lastRollupKey = "spotted.last_rollup_day"
    /// The least tier a notice is ever posted for.
    public static let noticeTier = DeadlineScout.Tier.high

    // MARK: - Policy

    /// Everything to post right now: urgent notices first, then today's
    /// roll-up if its hour has come and it has not gone out yet. Empty when
    /// either reminders or spotted dates are off.
    public static func due(
        database: ShifuDatabase, now: Int64 = Int64(Date().timeIntervalSince1970 * 1_000),
        calendar: Calendar = .current
    ) throws -> [Notice] {
        let preferences = DeadlineReminders.preferences(database: database)
        guard preferences.enabled, preferences.spotted else { return [] }
        let candidates = try DeadlineProposalStore.pending(database: database, minimumTier: noticeTier)
            .filter { $0.notifiedAt == nil && $0.daysLeft(now: now, calendar: calendar) >= 0 }
        var notices: [Notice] = []
        let (urgent, rest) = candidates.partitioned {
            $0.tier == .critical && $0.daysLeft(now: now, calendar: calendar) <= urgentWithinDays
        }
        // Urgent ones are *one* banner per tick however many there are: the
        // first pass after an install backfills two weeks of screen text, and
        // nine critical rows due today must not be nine banners.
        let moment = Moment(now: now, calendar: calendar)
        if !urgent.isEmpty {
            notices.append(fold(
                urgent, kind: .urgent, identifier: "shifu.spotted.\(dayStamp(now, calendar: calendar)).urgent",
                title: urgent.count == 1
                    ? "Spotted: \(urgent[0].title)"
                    : "\(urgent.count) spotted dates due within \(urgentWithinDays) days",
                at: moment))
        }
        if !rest.isEmpty, rollupIsDue(database: database, hour: preferences.hour, now: now, calendar: calendar) {
            notices.append(fold(
                rest, kind: .rollup, identifier: "shifu.spotted.\(dayStamp(now, calendar: calendar))",
                title: rest.count == 1 ? "Shifu spotted a date" : "Shifu spotted \(rest.count) dates",
                at: moment))
        }
        return notices
    }

    struct Moment {
        var now: Int64
        var calendar: Calendar
    }

    /// Several proposals as one banner: the soonest `rollupLimit` named,
    /// the rest counted. A lone urgent one is named in the title, so its body
    /// is when and where; a roll-up always lists, even one.
    private static func fold(
        _ proposals: [DeadlineProposal], kind: Notice.Kind, identifier: String, title: String, at moment: Moment
    ) -> Notice {
        let named = proposals.sorted { $0.dueAt < $1.dueAt }.prefix(rollupLimit)
        if kind == .urgent, proposals.count == 1, let only = named.first {
            return Notice(kind: kind, identifier: identifier, title: title,
                          body: line(only, now: moment.now, calendar: moment.calendar),
                          proposalIDs: named.compactMap(\.id))
        }
        var body = named.map { "\($0.title) — \(when($0, now: moment.now, calendar: moment.calendar))" }
            .joined(separator: " · ")
        let more = proposals.count - named.count
        if more > 0 { body += " · and \(more) more" }
        return Notice(kind: kind, identifier: identifier, title: title, body: body,
                      proposalIDs: named.compactMap(\.id))
    }

    /// Whether anything could be announced — the other half of the gate on
    /// asking for notification permission (`DeadlineReminders.hasSomethingToRemind`).
    public static func hasSomethingToAnnounce(database: ShifuDatabase) throws -> Bool {
        let preferences = DeadlineReminders.preferences(database: database)
        guard preferences.spotted else { return false }
        return try DeadlineProposalStore.pending(database: database, minimumTier: noticeTier)
            .contains { $0.notifiedAt == nil }
    }

    /// Marks a notice delivered: the named proposals are stamped, and a
    /// roll-up closes the day. Called after the post, like every ledger here.
    public static func record(
        _ notice: Notice, database: ShifuDatabase,
        now: Int64 = Int64(Date().timeIntervalSince1970 * 1_000), calendar: Calendar = .current
    ) throws {
        try DeadlineProposalStore.stampNotified(notice.proposalIDs, now: now, database: database)
        if notice.kind == .rollup {
            try Settings.set(lastRollupKey, to: dayStamp(now, calendar: calendar), database: database)
        }
    }

    // MARK: - Pieces

    /// The roll-up goes out once a day, at the reminder hour, and a day whose
    /// hour has already passed goes out on the next poll.
    static func rollupIsDue(database: ShifuDatabase, hour: Int, now: Int64, calendar: Calendar) -> Bool {
        let today = dayStamp(now, calendar: calendar)
        if ((try? Settings.get(lastRollupKey, database: database)) ?? nil) == today { return false }
        let date = Date(timeIntervalSince1970: Double(now) / 1_000)
        guard let moment = calendar.date(bySettingHour: hour, minute: 0, second: 0,
                                         of: calendar.startOfDay(for: date))
        else { return false }
        return date >= moment
    }

    /// "due tomorrow", "due Oct 14", "due Mon 5:00 PM" — close dates as a
    /// person says them, further ones as the calendar does.
    public static func when(_ proposal: DeadlineProposal, now: Int64, calendar: Calendar = .current) -> String {
        let days = proposal.daysLeft(now: now, calendar: calendar)
        let date = Date(timeIntervalSince1970: Double(proposal.dueAt) / 1_000)
        var text: String
        if days <= 7 && days >= -1 {
            text = DeadlineCopy.whenPhrase(daysLeft: days)
        } else {
            text = date.formatted(.dateTime.month(.abbreviated).day().locale(calendar.locale ?? .current))
        }
        if !proposal.allDay && days <= 7 {
            text += " " + DeadlineCopy.clock(proposal.dueAt, calendar: calendar)
        }
        return text
    }

    /// One notice's second line: when, and where it was seen.
    static func line(_ proposal: DeadlineProposal, now: Int64, calendar: Calendar) -> String {
        var parts = [when(proposal, now: now, calendar: calendar)]
        if let context = proposal.context {
            parts.append("seen in \(context)")
        } else {
            parts.append("seen in \(SemanticTaskGrouper.shortBundle(proposal.sourceApp))")
        }
        return parts.joined(separator: " · ")
    }

    static func dayStamp(_ ms: Int64, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day],
                                            from: Date(timeIntervalSince1970: Double(ms) / 1_000))
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

private extension Array {
    /// The elements that satisfy `belongs`, and the ones that do not, in order.
    func partitioned(by belongs: (Element) -> Bool) -> ([Element], [Element]) {
        var yes: [Element] = []
        var no: [Element] = []
        for element in self {
            if belongs(element) { yes.append(element) } else { no.append(element) }
        }
        return (yes, no)
    }
}
