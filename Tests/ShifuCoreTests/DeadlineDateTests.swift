import Foundation
import ShifuCore
import Testing

/// Reading a due date the way a person types one (design.md §4.5).
///
/// The property that matters most is the *refusal*: a misread deadline reminds
/// you on a day that means nothing, and you find out it was misread when it is
/// already late. So the suite spends as much effort on what must return nil as
/// on what must parse.
@Suite struct DeadlineDateTests {
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        cal.locale = Locale(identifier: "en_US")
        return cal
    }

    private func moment(_ text: String, hour: Int = 0, minute: Int = 0) -> Int64 {
        let parts = text.split(separator: "-").map { Int($0)! }
        let components = DateComponents(
            year: parts[0], month: parts[1], day: parts[2], hour: hour, minute: minute)
        return Int64(calendar.date(from: components)!.timeIntervalSince1970 * 1_000)
    }

    /// 2026-08-17 is a Monday — every relative form below is read from here.
    private var now: Int64 { moment("2026-08-17", hour: 14, minute: 30) }

    private func parse(_ text: String) -> DeadlineDate.Parsed? {
        DeadlineDate.parse(text, now: now, calendar: calendar)
    }

    @Test func anISODateIsAllDayAtLocalMidnight() throws {
        let parsed = try #require(parse("2026-08-30"))
        #expect(parsed.dueAt == moment("2026-08-30"))
        #expect(parsed.allDay)
    }

    @Test func anISODateWithAClockIsTimed() throws {
        for text in ["2026-08-30 17:00", "2026-08-30T17:00", "2026-08-30 17:00:00"] {
            let parsed = try #require(parse(text), "\(text) should parse")
            #expect(parsed.dueAt == moment("2026-08-30", hour: 17))
            #expect(parsed.allDay == false)
        }
    }

    @Test func todayAndTomorrowAreAllDay() throws {
        #expect(try #require(parse("today")).dueAt == moment("2026-08-17"))
        #expect(try #require(parse("tomorrow")).dueAt == moment("2026-08-18"))
        #expect(try #require(parse("TOMORROW")).allDay)     // case-insensitive
    }

    /// A weekday name means the next one. Saying "monday" on a Monday means the
    /// Monday coming — a deadline you meant for today you would call "today".
    @Test func aWeekdayNameMeansTheNextOne() throws {
        #expect(try #require(parse("friday")).dueAt == moment("2026-08-21"))
        #expect(try #require(parse("fri")).dueAt == moment("2026-08-21"))
        #expect(try #require(parse("sunday")).dueAt == moment("2026-08-23"))
        #expect(try #require(parse("monday")).dueAt == moment("2026-08-24"))
    }

    @Test func offsetsCountDaysWeeksAndMonths() throws {
        #expect(try #require(parse("+10d")).dueAt == moment("2026-08-27"))
        #expect(try #require(parse("+2w")).dueAt == moment("2026-08-31"))
        #expect(try #require(parse("+1m")).dueAt == moment("2026-09-17"))
    }

    /// A bare clock is today — and tests the one case where the parser must not
    /// help: it does *not* roll forward, because a deadline at a moment already
    /// gone is a thing the caller should see and question.
    @Test func aBareClockIsTodayAtThatHour() throws {
        let parsed = try #require(parse("17:00"))
        #expect(parsed.dueAt == moment("2026-08-17", hour: 17))
        #expect(parsed.allDay == false)
    }

    @Test func nonsenseIsRefusedRatherThanGuessed() {
        for text in ["", "   ", "next week", "sometime", "2026-13-01", "2026-08-32",
                     "30/08/2026", "10d", "+0d", "+5y", "aug 30", "25:00"] {
            #expect(parse(text) == nil, "\(text) should not parse")
        }
    }

    @Test func effortReadsHoursByDefaultAndMinutesWhenAsked() {
        // Bare literals, not `20 * 3_600_000`: swift-testing's expansion of an
        // optional compared against a *computed* literal fails while printing
        // two identical values ("(→ 72000000) == (→ 72000000)"). Unwrap with
        // #require or write the number out; do not spend an hour on it twice.
        #expect(DeadlineDate.parseEffort("20") == 72_000_000)
        #expect(DeadlineDate.parseEffort("20h") == 72_000_000)
        #expect(DeadlineDate.parseEffort("1.5") == 5_400_000)
        #expect(DeadlineDate.parseEffort("90m") == 5_400_000)
        #expect(DeadlineDate.parseEffort("0") == nil)
        #expect(DeadlineDate.parseEffort("-3") == nil)
        #expect(DeadlineDate.parseEffort("soon") == nil)
    }

    // MARK: - Copy

    @Test func theWhenPhraseReadsLikeSpeech() {
        #expect(DeadlineCopy.whenPhrase(daysLeft: 0) == "today")
        #expect(DeadlineCopy.whenPhrase(daysLeft: 1) == "tomorrow")
        #expect(DeadlineCopy.whenPhrase(daysLeft: 5) == "in 5 days")
        #expect(DeadlineCopy.whenPhrase(daysLeft: -1) == "yesterday")
        #expect(DeadlineCopy.whenPhrase(daysLeft: -4) == "4 days ago")
    }

    /// A deadline with no task claims nothing about effort. "0m logged" would
    /// read as "you did nothing", when the truth is that nothing was measured.
    @Test func theEffortClauseIsOmittedWhenThereIsNoTaskToMeasure() {
        let bare = DeadlineHorizon.Standing(
            deadline: Deadline(id: 1, title: "Visa", dueAt: 0, taskID: nil, createdAt: 0))
        #expect(DeadlineCopy.dateBody(bare, daysLeft: 2, calendar: calendar) == "due in 2 days")

        let measured = DeadlineHorizon.Standing(
            deadline: Deadline(
                id: 1, title: "Thesis", dueAt: 0, taskID: 4,
                targetMs: 20 * 3_600_000, createdAt: 0),
            loggedMs: 4 * 3_600_000 + 600_000)
        #expect(DeadlineCopy.dateBody(measured, daysLeft: 2, calendar: calendar)
            == "due in 2 days · 4h 10m of 20h logged")
    }

    /// A whole number of hours drops the minutes: targets are typed round, and
    /// "20h 0m" reads as a formatting slip rather than a figure.
    @Test func durationsDropAZeroMinuteTail() {
        #expect(DeadlineCopy.duration(72_000_000) == "20h")
        #expect(DeadlineCopy.duration(75_000_000) == "20h 50m")
        #expect(DeadlineCopy.duration(2_700_000) == "45m")
        #expect(DeadlineCopy.duration(0) == "0m")
        #expect(DeadlineCopy.duration(-5) == "0m")
    }

    /// The hour is information on the last day and noise a week out.
    @Test func theClockShowsOnlyNearTheDeadline() {
        let timed = DeadlineHorizon.Standing(
            deadline: Deadline(
                id: 1, title: "Submit", dueAt: moment("2026-08-30", hour: 17),
                allDay: false, taskID: nil, createdAt: 0))
        #expect(DeadlineCopy.dateBody(timed, daysLeft: 5, calendar: calendar) == "due in 5 days")
        #expect(DeadlineCopy.dateBody(timed, daysLeft: 0, calendar: calendar)
            .hasPrefix("due today at "))
    }

    @Test func overdueCopyLeadsWithBeingOverdue() {
        let late = DeadlineHorizon.Standing(
            deadline: Deadline(id: 1, title: "Visa", dueAt: 0, taskID: nil, createdAt: 0))
        #expect(DeadlineCopy.dateBody(late, daysLeft: -3, calendar: calendar)
            == "was due 3 days ago")
    }
}
