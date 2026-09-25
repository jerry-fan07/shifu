import Foundation

/// One thing to say about a deadline, once (design.md §4.5).
///
/// Top-level rather than nested in `DeadlineHorizon` because `Kind` would then
/// be two levels deep, which SwiftLint's `nesting` rule refuses — and it reads
/// better this way: the announcement is the thing that travels, and the horizon
/// is only what decides to make one.
///
/// `lead` and `notch` are what the row must record for it not to be said again.
public struct DeadlineAnnouncement: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// `daysLeft` is the real distance, not the bucket — the copy says
        /// "in 5 days" while the bucket that licensed it is 7.
        case approaching(daysLeft: Int)
        case overdue(daysLate: Int)
        /// A quarter of the intended effort, newly crossed.
        case progress(percent: Int)
    }

    public var deadlineID: Int64
    public var kind: Kind
    /// The notification's first line — the promise, as the user worded it.
    public var title: String
    /// Its second line: when, and how far in.
    public var body: String
    /// `announcedLead` to write, when this announcement is a date notice.
    public var lead: Int?
    /// `progressNotch` to write, when it is a progress notice.
    public var notch: Int?

    public init(
        deadlineID: Int64, kind: Kind, title: String, body: String,
        lead: Int? = nil, notch: Int? = nil
    ) {
        self.deadlineID = deadlineID
        self.kind = kind
        self.title = title
        self.body = body
        self.lead = lead
        self.notch = notch
    }
}

/// What Shifu has to say about a deadline, and when (design.md §4.5).
///
/// Entirely pure: no clock of its own, no database, no notification centre.
/// Everything it needs arrives as an argument, which is what lets the whole
/// announcement policy — including "this must not be said twice" — be pinned by
/// tests instead of observed by waiting a week.
public enum DeadlineHorizon {
    /// The lead times, in whole days, at which an approaching deadline speaks
    /// up: a week out, a few days out, the day before, the day itself.
    ///
    /// Four announcements over a deadline's whole life, and a fifth if it slips.
    /// That bound is the point: design.md §1's fifth principle is "useful
    /// without babysitting… not a stream of notifications", and the honest way
    /// to keep it while still being reminded is a small fixed schedule per
    /// promise the user made, not a rate limiter over an open-ended feed.
    public static let leads = [7, 3, 1, 0]

    /// The bucket used for "past its date". Below every real lead, so the
    /// only-ever-falls rule on `Deadline.announcedLead` covers it too and the
    /// overdue notice can no more repeat than the others can.
    public static let overdueLead = -1

    /// Quarters of `targetMs` worth reporting. 100 is included — finishing the
    /// effort you set yourself is the one piece of good news in the feature.
    public static let notches = [25, 50, 75, 100]

    // MARK: - Calendar arithmetic

    /// Whole calendar days from `now` to `dueAt`, counted between the two
    /// *days* rather than by dividing a duration.
    ///
    /// This is the difference between "due tomorrow" and "due in 23 hours",
    /// and the user means the first. Both ends collapse to their local
    /// midnight first, so a deadline set for 09:00 tomorrow reads as 1 day away
    /// at 22:00 tonight — not 0 — and DST is the calendar's problem, not ours.
    /// Nothing here walks a span, so the spring-forward/fall-back trap in
    /// ARCHITECTURE.md's "Walk a span one calendar unit at a time" recipe
    /// does not apply.
    public static func daysUntil(
        dueAt: Int64, now: Int64, calendar: Calendar = .current
    ) -> Int {
        let dueDay = calendar.startOfDay(for: Date(timeIntervalSince1970: Double(dueAt) / 1_000))
        let today = calendar.startOfDay(for: Date(timeIntervalSince1970: Double(now) / 1_000))
        return calendar.dateComponents([.day], from: today, to: dueDay).day ?? 0
    }

    /// The lead bucket a deadline currently sits in, or nil when it is further
    /// out than the longest lead and there is nothing yet to say.
    ///
    /// The *smallest* lead still at or above `daysLeft`: five days out sits in
    /// the 7-day bucket (that notice is the one it has earned), three days out
    /// moves to the 3-day bucket, and two days out stays there until the
    /// day-before bucket opens. So a deadline announces once per bucket as it
    /// falls through them, and never twice for the same one.
    public static func bucket(daysLeft: Int) -> Int? {
        if daysLeft < 0 { return overdueLead }
        return leads.filter { $0 >= daysLeft }.min()
    }

    /// The reminder hour used when a caller has no setting to hand. Kept beside
    /// the policy so `SettingsCatalog.remindersHour` and the tests agree.
    public static let defaultHour = 9

    /// The moment a lead bucket's reminder should be delivered: `hour` local
    /// time on the day that many days before the due day.
    ///
    /// This is a **gate, not a schedule.** Nothing in Shifu hands a future
    /// moment to the system to fire later: `announcements` is asked on a poll
    /// and this is what it compares `now` against, so a bucket that opened at
    /// local midnight stays silent until the morning. A reminder that arrived
    /// at 00:01 because the calendar day turned is the failure this prevents,
    /// and it is the same reason `Deadline.allDay` exists.
    ///
    /// A timed deadline still announces its *earlier* leads in the morning —
    /// a 17:00 Friday deadline warning you at 17:00 on Tuesday is a reminder
    /// that arrives after the day it was meant to shape. The exception is the
    /// day-of notice for a timed deadline, which fires at the deadline's own
    /// hour when that is later than the reminder hour, because on the last day
    /// the time *is* the information.
    public static func fireMoment(
        for deadline: Deadline, lead: Int, hour: Int, calendar: Calendar = .current
    ) -> Date? {
        let due = Date(timeIntervalSince1970: Double(deadline.dueAt) / 1_000)
        let dueDay = calendar.startOfDay(for: due)
        let offset = lead == overdueLead ? 1 : -lead
        guard let day = calendar.date(byAdding: .day, value: offset, to: dueDay),
              let morning = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day)
        else { return nil }
        if lead == 0 && !deadline.allDay && due > morning { return due }
        return morning
    }

    // MARK: - Announcements

    /// A deadline with the time already logged against it — everything the
    /// policy below needs, gathered by `DeadlineStore.open`.
    public struct Standing: Sendable, Equatable {
        public var deadline: Deadline
        /// Ms logged against `deadline.taskID` since `createdAt`. Zero when the
        /// deadline has no task, which is also why progress needs both.
        public var loggedMs: Int64
        public var taskName: String?

        public init(deadline: Deadline, loggedMs: Int64 = 0, taskName: String? = nil) {
            self.deadline = deadline
            self.loggedMs = loggedMs
            self.taskName = taskName
        }

        /// Fraction of the intended effort done, or nil for a date-only
        /// deadline. Uncapped on purpose: 130% is a true and useful thing to
        /// know, and only `notch` clamps for the announcement ledger.
        public var progressPercent: Int? {
            guard let target = deadline.targetMs, target > 0 else { return nil }
            return Int((Double(loggedMs) / Double(target) * 100).rounded(.down))
        }
    }

    /// Everything that should be said about one deadline right now, given what
    /// has already been said. At most two: a date notice and a progress notice
    /// can both come due in the same tick, and collapsing them would silently
    /// drop one for a week.
    ///
    /// A finished deadline says nothing at all — marking one done is the user
    /// telling Shifu to stop, and that has to include the overdue notice.
    public static func announcements(
        for standing: Standing, now: Int64, hour: Int = defaultHour,
        calendar: Calendar = .current
    ) -> [DeadlineAnnouncement] {
        let deadline = standing.deadline
        guard let id = deadline.id, !deadline.isDone else { return [] }
        var out: [DeadlineAnnouncement] = []
        if let notice = dateNotice(
            for: standing, id: id, now: now, hour: hour, calendar: calendar) {
            out.append(notice)
        }
        // Progress is deliberately *not* hour-gated. A date notice is Shifu
        // choosing a moment to speak; a progress notice is a reaction to work
        // that just happened, and holding "you passed halfway" until tomorrow
        // morning would report it after the session it belongs to has ended.
        if let notice = progressNotice(for: standing, id: id, now: now, calendar: calendar) {
            out.append(notice)
        }
        return out
    }

    private static func dateNotice(
        for standing: Standing, id: Int64, now: Int64, hour: Int, calendar: Calendar
    ) -> DeadlineAnnouncement? {
        let deadline = standing.deadline
        let daysLeft = daysUntil(dueAt: deadline.dueAt, now: now, calendar: calendar)
        guard let bucket = bucket(daysLeft: daysLeft) else { return nil }
        // Only ever falls: a bucket already announced, or one further out than
        // the last announcement, has nothing new in it.
        if let said = deadline.announcedLead, bucket >= said { return nil }
        // The bucket has opened; the hour decides whether it may speak yet. A
        // bucket whose moment is already behind us fires at once, which is what
        // makes a deadline entered *inside* its own warning window say so
        // immediately instead of waiting for a morning that has passed.
        if let moment = fireMoment(for: deadline, lead: bucket, hour: hour, calendar: calendar),
           now < Int64(moment.timeIntervalSince1970 * 1_000) {
            return nil
        }
        let kind: DeadlineAnnouncement.Kind = daysLeft < 0
            ? .overdue(daysLate: -daysLeft)
            : .approaching(daysLeft: daysLeft)
        return DeadlineAnnouncement(
            deadlineID: id, kind: kind, title: deadline.title,
            body: DeadlineCopy.dateBody(standing, daysLeft: daysLeft, calendar: calendar),
            lead: bucket)
    }

    private static func progressNotice(
        for standing: Standing, id: Int64, now: Int64, calendar: Calendar
    ) -> DeadlineAnnouncement? {
        guard let percent = standing.progressPercent,
              let crossed = notches.filter({ $0 <= percent }).max(),
              crossed > standing.deadline.progressNotch
        else { return nil }
        let daysLeft = daysUntil(dueAt: standing.deadline.dueAt, now: now, calendar: calendar)
        return DeadlineAnnouncement(
            deadlineID: id, kind: .progress(percent: crossed),
            title: standing.deadline.title,
            body: DeadlineCopy.progressBody(standing, notch: crossed, daysLeft: daysLeft),
            notch: crossed)
    }
}
