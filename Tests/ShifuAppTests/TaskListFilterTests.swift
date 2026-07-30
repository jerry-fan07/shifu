import Foundation
import ShifuCore
import Testing
@testable import ShifuApp

/// The Task log's filter bar (design.md §5.3) and the calendar conventions
/// under it. `TaskRange.since` is day- and week-*aligned* on purpose — "today"
/// has to mean since midnight, not the last 24 hours — which is exactly the
/// kind of claim that rots silently without a test.
@Suite struct TaskRangeTests {
    static let calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }()

    /// Thursday 2026-06-11, 14:30.
    static let thursday = calendar.date(from: DateComponents(
        timeZone: calendar.timeZone, year: 2026, month: 6, day: 11,
        hour: 14, minute: 30))!

    private static func date(_ since: Int64) -> Date {
        Date(timeIntervalSince1970: Double(since) / 1_000)
    }

    @Test func todayMeansSinceMidnightNotTheLastTwentyFourHours() {
        let since = Self.date(TaskRange.today.since(now: Self.thursday, calendar: Self.calendar))
        #expect(since == Self.calendar.startOfDay(for: Self.thursday))
        #expect(Self.thursday.timeIntervalSince(since) < 24 * 3_600)
    }

    @Test func weekMeansSinceMondayNotTheLastSevenDays() {
        let since = Self.date(TaskRange.week.since(now: Self.thursday, calendar: Self.calendar))
        let components = Self.calendar.dateComponents([.weekday, .hour], from: since)
        #expect(components.weekday == 2)   // Monday, whatever the locale prefers
        #expect(components.hour == 0)
        #expect(since < Self.thursday)
    }

    @Test func monthIsARollingThirtyDaysAndAllTimeIsUnbounded() {
        let since = Self.date(TaskRange.month.since(now: Self.thursday, calendar: Self.calendar))
        #expect(abs(Self.thursday.timeIntervalSince(since) - 30 * 86_400) < 3_600)
        #expect(TaskRange.all.since(now: Self.thursday, calendar: Self.calendar) == 0)
    }

    @Test func rangesWidenMonotonically() {
        let cutoffs = [TaskRange.today, .week, .month].map {
            $0.since(now: Self.thursday, calendar: Self.calendar)
        }
        #expect(cutoffs == cutoffs.sorted(by: >))
    }

    /// A Monday is its own week start — the off-by-one that would push the
    /// week back seven days.
    @Test func mondayIsTheStartOfItsOwnWeek() {
        let monday = Self.calendar.date(from: DateComponents(
            timeZone: Self.calendar.timeZone, year: 2026, month: 6, day: 8, hour: 9))!
        let since = Self.date(TaskRange.week.since(now: monday, calendar: Self.calendar))
        #expect(since == Self.calendar.startOfDay(for: monday))
    }

    @Test func sundayBelongsToTheWeekItEnds() {
        let sunday = Self.calendar.date(from: DateComponents(
            timeZone: Self.calendar.timeZone, year: 2026, month: 6, day: 14, hour: 21))!
        let since = Self.date(TaskRange.week.since(now: sunday, calendar: Self.calendar))
        let days = Self.calendar.dateComponents(
            [.day], from: since, to: Self.calendar.startOfDay(for: sunday)).day
        #expect(days == 6)
    }
}

@Suite struct TaskListFilterTests {
    @Test func theDefaultFilterAlreadyHidesStrayMinutes() {
        let filter = TaskListFilter()
        #expect(filter.minimum == .fiveMinutes)
        // …which means the default *narrows*, and the header must say so.
        #expect(filter.narrowsResults)
        // …but it is still the default, so there is nothing to clear.
        #expect(!filter.isNarrowed)
    }

    @Test func sortReordersRatherThanNarrows() {
        var filter = TaskListFilter(range: .all, minimum: .any, sort: .mostRecent, theme: .any)
        #expect(!filter.narrowsResults)
        filter.sort = .mostTime
        #expect(!filter.narrowsResults)
        // …but it is a departure from the default, so "clear" should undo it.
        #expect(filter.isNarrowed)
    }

    @Test func everyNarrowingDimensionCounts() {
        let unfiltered = TaskListFilter(range: .all, minimum: .any, theme: .any)
        #expect(!unfiltered.narrowsResults)

        var byRange = unfiltered; byRange.range = .today
        var byMinimum = unfiltered; byMinimum.minimum = .halfHour
        var byTheme = unfiltered; byTheme.theme = .unassigned
        #expect(byRange.narrowsResults)
        #expect(byMinimum.narrowsResults)
        #expect(byTheme.narrowsResults)
    }

    @Test func coreCarriesEveryDimensionThroughToTheStoreQuery() {
        let filter = TaskListFilter(
            range: .today, minimum: .halfHour, sort: .mostTime, theme: .unassigned)
        let core = filter.core(
            now: TaskRangeTests.thursday, calendar: TaskRangeTests.calendar, limit: 50)

        #expect(core.since == TaskRange.today.since(
            now: TaskRangeTests.thursday, calendar: TaskRangeTests.calendar))
        #expect(core.minimumMs == TaskMinimum.halfHour.ms)
        #expect(core.sort == .mostTime)
        #expect(core.themeScope == .unassigned)
        #expect(core.limit == 50)
    }

    @Test func minimumsAreOrderedAndStartAtZero() {
        let floors = TaskMinimum.allCases.map(\.ms)
        #expect(floors.first == 0)
        #expect(floors == floors.sorted())
    }
}

@Suite struct ReviewDeckLabelTests {
    @Test func eachDeckNamesItselfTheWayTheUserWouldRecognizeIt() {
        #expect(ReviewDeck.all.label == "All notes")
        #expect(ReviewDeck.theme(key: "thm:travel", name: "Travel").label == "Travel")
        #expect(ReviewDeck.task(key: "sem:flights", name: "Booking flights").label
            == "Booking flights")
    }

    @Test func decksAreDistinguishedByKeyNotOnlyByName() {
        #expect(ReviewDeck.theme(key: "thm:a", name: "Same") != .theme(key: "thm:b", name: "Same"))
        #expect(ReviewDeck.theme(key: "k", name: "Same") != .task(key: "k", name: "Same"))
    }
}
