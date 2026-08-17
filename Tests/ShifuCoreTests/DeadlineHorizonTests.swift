import Foundation
import ShifuCore
import Testing

/// The announcement policy (design.md §4.5).
///
/// This suite is the whole reason `DeadlineHorizon` takes its clock and its
/// calendar as arguments: every claim here is about what Shifu says on a
/// particular day, and the alternative to injecting the day is waiting for it.
///
/// What the tests are guarding is mostly *silence* — a reminder that repeats is
/// the failure mode that makes a notification feature something people switch
/// off, so "said once" is asserted more often than "said at all".
@Suite struct DeadlineHorizonTests {
    /// A fixed calendar so a run in Auckland and a run in Los Angeles agree.
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        cal.locale = Locale(identifier: "en_US")
        return cal
    }

    /// Local midnight of a day, in ms — how an all-day deadline is stored.
    private func day(_ text: String, hour: Int = 0, minute: Int = 0) -> Int64 {
        let parts = text.split(separator: "-").map { Int($0)! }
        let components = DateComponents(
            year: parts[0], month: parts[1], day: parts[2], hour: hour, minute: minute)
        return Int64(calendar.date(from: components)!.timeIntervalSince1970 * 1_000)
    }

    private func deadline(
        due: Int64, allDay: Bool = true, taskID: Int64? = 7, targetMs: Int64? = nil,
        created: Int64? = nil, doneAt: Int64? = nil,
        announcedLead: Int? = nil, progressNotch: Int = 0
    ) -> Deadline {
        Deadline(
            id: 1, title: "Thesis draft", dueAt: due, allDay: allDay, taskID: taskID,
            targetMs: targetMs, createdAt: created ?? day("2026-08-01"), doneAt: doneAt,
            announcedLead: announcedLead, progressNotch: progressNotch)
    }

    // MARK: - Calendar distance

    /// The distinction the whole feature rests on: "tomorrow" is the next
    /// calendar day, not 24 hours away. At 22:00 a 09:00 deadline the next
    /// morning is 11 hours off and still *tomorrow*, and a duration division
    /// would call it today.
    @Test func daysUntilCountsCalendarDaysNotElapsedHours() {
        let due = day("2026-08-20", hour: 9)
        #expect(DeadlineHorizon.daysUntil(
            dueAt: due, now: day("2026-08-19", hour: 22), calendar: calendar) == 1)
        #expect(DeadlineHorizon.daysUntil(
            dueAt: due, now: day("2026-08-20", hour: 1), calendar: calendar) == 0)
        // Late on the due day is still the due day, never overdue.
        #expect(DeadlineHorizon.daysUntil(
            dueAt: due, now: day("2026-08-20", hour: 23), calendar: calendar) == 0)
        #expect(DeadlineHorizon.daysUntil(
            dueAt: due, now: day("2026-08-23", hour: 8), calendar: calendar) == -3)
    }

    /// Spring forward: 2026-03-08 is 23 hours long in Los Angeles. A day count
    /// that divides by 86,400,000 reports 6 days across this week; the calendar
    /// reports 7.
    @Test func daysUntilSurvivesASpringForward() {
        #expect(DeadlineHorizon.daysUntil(
            dueAt: day("2026-03-13"), now: day("2026-03-06"), calendar: calendar) == 7)
    }

    // MARK: - Buckets

    @Test func aDeadlineFallsThroughEachLeadBucketOnce() {
        #expect(DeadlineHorizon.bucket(daysLeft: 30) == nil)     // nothing to say yet
        #expect(DeadlineHorizon.bucket(daysLeft: 7) == 7)
        #expect(DeadlineHorizon.bucket(daysLeft: 5) == 7)        // still the week's notice
        #expect(DeadlineHorizon.bucket(daysLeft: 3) == 3)
        #expect(DeadlineHorizon.bucket(daysLeft: 2) == 3)
        #expect(DeadlineHorizon.bucket(daysLeft: 1) == 1)
        #expect(DeadlineHorizon.bucket(daysLeft: 0) == 0)
        #expect(DeadlineHorizon.bucket(daysLeft: -4) == DeadlineHorizon.overdueLead)
    }

    // MARK: - Saying it once

    @Test func aDeadlineTwoWeeksOutSaysNothing() {
        let standing = DeadlineHorizon.Standing(deadline: deadline(due: day("2026-08-30")))
        #expect(DeadlineHorizon.announcements(
            for: standing, now: day("2026-08-10", hour: 10), calendar: calendar).isEmpty)
    }

    @Test func theWeekNoticeIsAnnouncedOnceAndThenStaysQuiet() {
        let due = day("2026-08-30")
        let fresh = DeadlineHorizon.Standing(deadline: deadline(due: due))
        let first = DeadlineHorizon.announcements(
            for: fresh, now: day("2026-08-25", hour: 10), calendar: calendar)
        #expect(first.count == 1)
        #expect(first.first?.kind == .approaching(daysLeft: 5))
        #expect(first.first?.lead == 7)

        // Stamped, the same day says nothing — and so does the next one, which
        // is still inside the 7-day bucket.
        let stamped = DeadlineHorizon.Standing(deadline: deadline(due: due, announcedLead: 7))
        #expect(DeadlineHorizon.announcements(
            for: stamped, now: day("2026-08-25", hour: 10), calendar: calendar).isEmpty)
        #expect(DeadlineHorizon.announcements(
            for: stamped, now: day("2026-08-26", hour: 10), calendar: calendar).isEmpty)
        // The 3-day bucket is new, so it speaks again.
        let atThree = DeadlineHorizon.announcements(
            for: stamped, now: day("2026-08-27", hour: 10), calendar: calendar)
        #expect(atThree.first?.lead == 3)
    }

    /// The overdue notice sits below every lead, so the only-ever-falls rule
    /// covers it: it fires once after the date passes and never again, however
    /// many days go by.
    @Test func theOverdueNoticeFiresOnceAndNotEveryDayAfter() {
        let due = day("2026-08-30")
        let onTheDay = DeadlineHorizon.Standing(deadline: deadline(due: due, announcedLead: 0))
        let late = DeadlineHorizon.announcements(
            for: onTheDay, now: day("2026-08-31", hour: 10), calendar: calendar)
        #expect(late.count == 1)
        #expect(late.first?.kind == .overdue(daysLate: 1))
        #expect(late.first?.lead == DeadlineHorizon.overdueLead)

        let announced = DeadlineHorizon.Standing(
            deadline: deadline(due: due, announcedLead: DeadlineHorizon.overdueLead))
        #expect(DeadlineHorizon.announcements(
            for: announced, now: day("2026-09-15", hour: 10), calendar: calendar).isEmpty)
    }

    /// Marking a promise kept is the user telling Shifu to stop — which has to
    /// include the overdue notice, the one it would otherwise be most eager to
    /// deliver.
    @Test func aDoneDeadlineSaysNothingEvenWhenItsDateHasPassed() {
        let standing = DeadlineHorizon.Standing(
            deadline: deadline(
                due: day("2026-08-30"), targetMs: 3_600_000, doneAt: day("2026-08-29")),
            loggedMs: 36_000_000)
        #expect(DeadlineHorizon.announcements(
            for: standing, now: day("2026-09-05", hour: 10), calendar: calendar).isEmpty)
    }

    // MARK: - Progress

    @Test func progressIsReportedByQuarterAndOnlyOnceEach() {
        let due = day("2026-08-30")
        let target: Int64 = 20 * 3_600_000
        let halfway = DeadlineHorizon.Standing(
            deadline: deadline(due: due, targetMs: target, announcedLead: 7),
            loggedMs: 11 * 3_600_000)
        let notices = DeadlineHorizon.announcements(
            for: halfway, now: day("2026-08-25", hour: 10), calendar: calendar)
        #expect(notices.count == 1)
        #expect(notices.first?.kind == .progress(percent: 50))
        #expect(notices.first?.notch == 50)

        // 55% has nothing new to report once 50 has been said.
        let stamped = DeadlineHorizon.Standing(
            deadline: deadline(
                due: due, targetMs: target, announcedLead: 7, progressNotch: 50),
            loggedMs: 11 * 3_600_000)
        #expect(DeadlineHorizon.announcements(
            for: stamped, now: day("2026-08-25", hour: 10), calendar: calendar).isEmpty)
    }

    /// Overshooting jumps straight to the highest quarter crossed rather than
    /// dribbling out three notices on three consecutive ticks.
    @Test func aBigJumpReportsTheHighestQuarterNotEveryOneBelowIt() {
        let standing = DeadlineHorizon.Standing(
            deadline: deadline(
                due: day("2026-08-30"), targetMs: 10 * 3_600_000, announcedLead: 7),
            loggedMs: 13 * 3_600_000)
        let notices = DeadlineHorizon.announcements(
            for: standing, now: day("2026-08-25", hour: 10), calendar: calendar)
        #expect(notices.count == 1)
        #expect(notices.first?.kind == .progress(percent: 100))
    }

    @Test func aDateOnlyDeadlineNeverReportsProgress() {
        let standing = DeadlineHorizon.Standing(
            deadline: deadline(due: day("2026-08-30"), targetMs: nil, announcedLead: 7),
            loggedMs: 40 * 3_600_000)
        #expect(DeadlineHorizon.announcements(
            for: standing, now: day("2026-08-25", hour: 10), calendar: calendar).isEmpty)
    }

    /// A date notice and a progress notice can come due in the same tick.
    /// Collapsing them to one would drop whichever lost for a whole bucket —
    /// up to a week of silence about the thing that just moved.
    @Test func aDateNoticeAndAProgressNoticeCanBothArriveAtOnce() {
        let standing = DeadlineHorizon.Standing(
            deadline: deadline(due: day("2026-08-30"), targetMs: 20 * 3_600_000),
            loggedMs: 15 * 3_600_000)
        let notices = DeadlineHorizon.announcements(
            for: standing, now: day("2026-08-27", hour: 10), calendar: calendar)
        #expect(notices.count == 2)
        #expect(notices.contains { $0.lead == 3 })
        #expect(notices.contains { $0.notch == 75 })
    }

    // MARK: - The hour gate

    /// `daysUntil` changes at local midnight, so without an hour gate a poll
    /// running through the night announces every new bucket at 00:01 — which is
    /// the one moment a reminder must never use, and the whole reason
    /// `Deadline.allDay` is a column.
    @Test func aBucketThatOpensAtMidnightWaitsForTheReminderHour() {
        let due = day("2026-08-30")
        let standing = DeadlineHorizon.Standing(deadline: deadline(due: due, announcedLead: 7))
        // 2026-08-27 is the 3-day bucket's first day.
        #expect(DeadlineHorizon.announcements(
            for: standing, now: day("2026-08-27", hour: 0, minute: 5),
            hour: 9, calendar: calendar).isEmpty)
        #expect(DeadlineHorizon.announcements(
            for: standing, now: day("2026-08-27", hour: 8, minute: 59),
            hour: 9, calendar: calendar).isEmpty)
        let atNine = DeadlineHorizon.announcements(
            for: standing, now: day("2026-08-27", hour: 9), hour: 9, calendar: calendar)
        #expect(atNine.first?.lead == 3)
        // And the setting is honoured, not just the default.
        #expect(DeadlineHorizon.announcements(
            for: standing, now: day("2026-08-27", hour: 9), hour: 18,
            calendar: calendar).isEmpty)
    }

    /// A deadline entered *inside* its own warning window says so at once. Its
    /// bucket's moment is already behind us, and waiting for a morning that has
    /// passed would mean silence until the next bucket opened.
    @Test func aBucketWhoseMomentHasPassedFiresImmediately() {
        let standing = DeadlineHorizon.Standing(deadline: deadline(due: day("2026-08-30")))
        let notices = DeadlineHorizon.announcements(
            for: standing, now: day("2026-08-26", hour: 2), hour: 9, calendar: calendar)
        #expect(notices.first?.lead == 7)         // the week's notice, at 02:00
        #expect(notices.first?.kind == .approaching(daysLeft: 4))
    }

    /// Progress is a reaction to work, not a moment Shifu picked — holding it
    /// until tomorrow morning would report it after the session it belongs to.
    @Test func progressIsNotHeldBackByTheReminderHour() {
        let standing = DeadlineHorizon.Standing(
            deadline: deadline(
                due: day("2026-08-30"), targetMs: 20 * 3_600_000, announcedLead: 7),
            loggedMs: 11 * 3_600_000)
        let notices = DeadlineHorizon.announcements(
            for: standing, now: day("2026-08-25", hour: 23, minute: 40),
            hour: 9, calendar: calendar)
        #expect(notices.count == 1)
        #expect(notices.first?.notch == 50)
    }

    // MARK: - Fire moments

    /// Earlier leads announce in the morning; the day-of notice for a timed
    /// deadline moves to the deadline's own hour, because on the last day the
    /// time is the information.
    @Test func fireMomentsSitInTheMorningExceptTheDayOfATimedDeadline() throws {
        let timed = deadline(due: day("2026-08-30", hour: 17), allDay: false)
        let week = try #require(
            DeadlineHorizon.fireMoment(for: timed, lead: 7, hour: 9, calendar: calendar))
        #expect(Int64(week.timeIntervalSince1970 * 1_000) == day("2026-08-23", hour: 9))

        let dayOf = try #require(
            DeadlineHorizon.fireMoment(for: timed, lead: 0, hour: 9, calendar: calendar))
        #expect(Int64(dayOf.timeIntervalSince1970 * 1_000) == day("2026-08-30", hour: 17))

        // An all-day deadline keeps the morning slot — it has no hour of its own,
        // and midnight is the one moment a reminder must never use.
        let allDay = deadline(due: day("2026-08-30"))
        let plainDayOf = try #require(
            DeadlineHorizon.fireMoment(for: allDay, lead: 0, hour: 9, calendar: calendar))
        #expect(Int64(plainDayOf.timeIntervalSince1970 * 1_000) == day("2026-08-30", hour: 9))

        // Overdue speaks the morning *after*.
        let late = try #require(DeadlineHorizon.fireMoment(
            for: allDay, lead: DeadlineHorizon.overdueLead, hour: 9, calendar: calendar))
        #expect(Int64(late.timeIntervalSince1970 * 1_000) == day("2026-08-31", hour: 9))
    }
}
