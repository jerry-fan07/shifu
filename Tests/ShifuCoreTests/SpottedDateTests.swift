import Foundation
import ShifuCore
import Testing

/// Reading dates out of screen text (design.md §4.7).
///
/// Every shape here is one that appeared in the real dogfood corpus on
/// 2026-10-02 — a Gradescope dashboard, a syllabus, an email, an OCR'd one
/// with its punctuation chewed — and every resolution is pinned against the
/// day the text was *seen*, which is the whole difference between this and
/// `DeadlineDate`.
@Suite struct SpottedDateTests {
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

    /// Friday 2 October 2026, mid-morning — the day of the calibration run.
    private var seenFriday: Int64 { moment("2026-10-02", hour: 10) }

    private func first(_ line: String, seen: Int64) -> SpottedDate.Match? {
        SpottedDate.first(in: line, seenAt: seen, calendar: calendar)
    }

    // MARK: - Calendar dates

    @Test func aGradescopeLateDueDateReadsWithItsClock() throws {
        let match = try #require(first("Late Due Date: Sep 25 at 12:00PM", seen: moment("2026-09-20")))
        #expect(match.dueAt == moment("2026-09-25", hour: 12))
        #expect(match.allDay == false)
        #expect(match.hasClock)
        #expect(!match.hasWeekday)
    }

    /// The same line a week after the date: it is a record, not a deadline.
    /// A year-less date already past is not bumped to next year — that would
    /// put it outside the horizon anyway, and nothing is reminded about it.
    @Test func aPastYearlessDateIsNothing() {
        #expect(first("Late Due Date: Sep 25 at 12:00PM", seen: seenFriday) == nil)
        #expect(first("CS 300 Post-Lecture Quiz (9/17: LEC 3)", seen: seenFriday) == nil)
    }

    @Test func ordinalsAndChewedPunctuationStillRead() throws {
        let closing = try #require(first("TIP applications close September 20th., $50 course fee",
                                         seen: moment("2026-09-10")))
        #expect(closing.dueAt == moment("2026-09-20"))
        #expect(closing.allDay)
        let offer = try #require(first("accept the offer by Sunday. Sep 20. Best. Steven",
                                       seen: moment("2026-09-15")))
        #expect(offer.dueAt == moment("2026-09-20"))
        #expect(offer.hasWeekday)
    }

    @Test func aWeekdayWithItsDateIsTheDateNotTheWeekday() throws {
        let match = try #require(first("RSVP here by Monday, September 28", seen: moment("2026-09-22")))
        #expect(match.dueAt == moment("2026-09-28"))
        #expect(match.hasWeekday)
        #expect(match.calendarDate)
    }

    @Test func aRangeIsItsFirstDay() throws {
        let match = try #require(first("The Finalist Competition will take place on November 12–13.",
                                       seen: seenFriday))
        #expect(match.dueAt == moment("2026-11-12"))
    }

    @Test func aYearIsHonouredAndSoIsTheHorizon() throws {
        let video = try #require(first("minute video by February 5, 2027, edit videos", seen: seenFriday))
        #expect(video.dueAt == moment("2027-02-05"))
        #expect(video.hasYear)
        // Past with a year: gone, however the text reads.
        #expect(first("Last opened by me May 30, 2026", seen: seenFriday) == nil)
        // Six months out is as far as "coming up" reaches.
        #expect(first("Programme begins 2027-06-01", seen: seenFriday) == nil)
        #expect(first("Programme begins 2027-03-01", seen: seenFriday) != nil)
    }

    @Test func isoAndNumericForms() throws {
        let iso = try #require(first("Submit by 2026-10-14 17:00", seen: seenFriday))
        #expect(iso.dueAt == moment("2026-10-14", hour: 17))
        #expect(!iso.allDay)
        let numeric = try #require(first("Midterm on 10/14", seen: seenFriday))
        #expect(numeric.dueAt == moment("2026-10-14"))
        #expect(numeric.numeric)
        #expect(numeric.calendarDate)
    }

    @Test func impossibleDaysAreRefused() {
        #expect(first("due Feb 30", seen: seenFriday) == nil)
        #expect(first("due 13/45", seen: seenFriday) == nil)
    }

    // MARK: - Weekdays and relative words

    /// Saturday, "sign up by Monday 11:59": the Monday after, and 11:59 of a
    /// deadline is 23:59.
    @Test func aBareWeekdayIsTheNextOneAndFiftyNineIsNight() throws {
        let match = try #require(first("Interview invitation offered, sign up by Monday 11:59",
                                       seen: moment("2026-09-26", hour: 14)))
        #expect(match.dueAt == moment("2026-09-28", hour: 23, minute: 59))
        #expect(match.hasWeekday)
        #expect(!match.calendarDate)
    }

    /// The weekday you are standing in means today only while its hour is
    /// still ahead.
    @Test func todaysWeekdayDependsOnTheClock() throws {
        let later = try #require(first("due Friday 5pm", seen: seenFriday))
        #expect(later.dueAt == moment("2026-10-02", hour: 17))
        let earlier = try #require(first("due Friday 9am", seen: seenFriday))
        #expect(earlier.dueAt == moment("2026-10-09", hour: 9))
        let bare = try #require(first("due Friday", seen: seenFriday))
        #expect(bare.dueAt == moment("2026-10-09"))
    }

    /// "sun", "sat", "mon" are words; "Mon–Thu" is opening hours. Only full
    /// weekday names stand on their own.
    @Test func abbreviatedWeekdaysAloneAreNotDates() {
        #expect(first("lit by the actual sun position over Providence", seen: seenFriday) == nil)
        #expect(first("Nelson Fitness Center closes at 11:30 PM Mon–Thu.", seen: seenFriday) == nil)
        #expect(first("I sat there for an hour", seen: seenFriday) == nil)
    }

    @Test func relativeWordsResolveFromTheDaySeen() throws {
        let tomorrow = try #require(first("HW3 is due tomorrow", seen: seenFriday))
        #expect(tomorrow.dueAt == moment("2026-10-03"))
        #expect(tomorrow.relative)
        let tonight = try #require(first("FREP Apps Due TONIGHT!", seen: seenFriday))
        #expect(tonight.dueAt == moment("2026-10-02"))
        let endOfMonth = try #require(first("submit by end of month", seen: seenFriday))
        #expect(endOfMonth.dueAt == moment("2026-10-31"))
    }

    // MARK: - Several in a line

    /// "Midterm 1: October 14. Midterm 2: Nov 11" — both, in order, and the
    /// weekday glued to a month-name date is not read a second time alone.
    @Test func everyDateInALineInOrderWithoutOverlap() {
        let matches = SpottedDate.matches(
            in: "Midterm dates: Midterm 1: October 14. Midterm 2: Nov 11, by Monday.",
            seenAt: seenFriday, calendar: calendar)
        #expect(matches.map(\.dueAt) == [moment("2026-10-14"), moment("2026-11-11"), moment("2026-10-05")])
        let glued = SpottedDate.matches(
            in: "Invitation: Meeting @ Sun Oct 4, 2026 3:30pm", seenAt: seenFriday, calendar: calendar)
        #expect(glued.count == 1)
        #expect(glued.first?.dueAt == moment("2026-10-04", hour: 15, minute: 30))
    }

    @Test func noonAndMidnightReadAsAPersonMeansThem() throws {
        let noon = try #require(first("due Oct 6 at 12:00PM", seen: seenFriday))
        #expect(noon.dueAt == moment("2026-10-06", hour: 12))
        let midnight = try #require(first("due Oct 6 at 12:00AM", seen: seenFriday))
        #expect(midnight.dueAt == moment("2026-10-06", hour: 0))
        #expect(!midnight.allDay)
    }
}
