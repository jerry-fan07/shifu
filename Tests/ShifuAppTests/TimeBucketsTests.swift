import Foundation
import ShifuCore
import SwiftUI
import Testing
@testable import ShifuApp

/// The timeline mode's stacked bars, and the DST arithmetic underneath them.
///
/// The regression these guard is a hang, not a wrong number: the previous
/// implementation walked the window with
/// `date(bySettingHour:minute:second:of:)`, which on the *repeated* hour of a
/// fall-back resolves to the earlier occurrence — behind the cursor — so the
/// loop ran forever. `CalendarSlices` is the fix; these pin it in place.
@Suite struct TimeBucketsTests {
    /// A zone with real DST, pinned so the test means the same thing in
    /// December as in June.
    static let newYork = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }()

    static func block(
        _ category: String, from: Date, to: Date, theme: String? = nil
    ) -> LedgerBuilder.LabeledActivity {
        LedgerBuilder.LabeledActivity(
            id: Int64(from.timeIntervalSince1970),
            startedAt: Int64(from.timeIntervalSince1970 * 1_000),
            endedAt: Int64(to.timeIntervalSince1970 * 1_000),
            category: category, source: "com.example.app", themeName: theme)
    }

    private static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int) -> Date {
        newYork.date(from: DateComponents(
            timeZone: newYork.timeZone, year: year, month: month, day: day, hour: hour))!
    }

    @Test func dayBucketsAreHoursLabeledZeroPadded() {
        let from = Self.date(2026, 6, 10, 0)
        let buckets = TimeBuckets.buckets(
            [Self.block("work", from: Self.date(2026, 6, 10, 9),
                        to: Self.date(2026, 6, 10, 11))],
            lens: .category, span: .day, groups: ["work"],
            window: .init(from: from, to: Self.date(2026, 6, 11, 0), calendar: Self.newYork))

        #expect(buckets.map(\.label) == ["09", "10"])
        #expect(buckets.allSatisfy { abs($0.hours - 1) < 0.001 })
    }

    /// The bug that motivated `CalendarSlices`. Before the fix this test hung.
    @Test func fallBackDayDoesNotSpinForeverAndKeepsItsTwentyFiveHours() throws {
        // 2026-11-01: America/New_York repeats 01:00–02:00.
        let dayStart = Self.date(2026, 11, 1, 0)
        let dayEnd = Self.date(2026, 11, 2, 0)
        #expect(dayEnd.timeIntervalSince(dayStart) == 25 * 3_600)

        let buckets = TimeBuckets.buckets(
            [Self.block("work", from: dayStart, to: dayEnd)],
            lens: .category, span: .day, groups: ["work"],
            window: .init(from: dayStart, to: dayEnd, calendar: Self.newYork))

        // Every hour of the wall clock is accounted for, and the repeated hour
        // carries both passes rather than one of them going missing.
        let total = buckets.reduce(0) { $0 + $1.hours }
        #expect(abs(total - 25) < 0.001)
        let repeated = try #require(buckets.first { $0.label == "01" })
        #expect(abs(repeated.hours - 2) < 0.001)
    }

    @Test func springForwardDayLosesItsSkippedHourRatherThanCrashing() {
        // 2026-03-08: America/New_York skips 02:00–03:00.
        let dayStart = Self.date(2026, 3, 8, 0)
        let dayEnd = Self.date(2026, 3, 9, 0)
        #expect(dayEnd.timeIntervalSince(dayStart) == 23 * 3_600)

        let buckets = TimeBuckets.buckets(
            [Self.block("work", from: dayStart, to: dayEnd)],
            lens: .category, span: .day, groups: ["work"],
            window: .init(from: dayStart, to: dayEnd, calendar: Self.newYork))

        #expect(abs(buckets.reduce(0) { $0 + $1.hours } - 23) < 0.001)
        // 02:00 never happened, so there is no bar for it.
        #expect(!buckets.contains { $0.label == "02" })
    }

    @Test func weekBucketsAreCalendarDaysOrderedFromTheWindowStart() {
        let monday = Self.date(2026, 6, 8, 0)
        let buckets = TimeBuckets.buckets(
            [Self.block("work", from: Self.date(2026, 6, 8, 10), to: Self.date(2026, 6, 8, 11)),
             Self.block("work", from: Self.date(2026, 6, 10, 10), to: Self.date(2026, 6, 10, 12))],
            lens: .category, span: .week, groups: ["work"],
            window: .init(from: monday, to: Self.date(2026, 6, 15, 0), calendar: Self.newYork))

        #expect(buckets.count == 2)
        #expect(buckets.map(\.order) == [0, 2])   // chronological, not alphabetical
        #expect(abs(buckets[1].hours - 2) < 0.001)
    }

    /// A week spanning the fall-back day must not attribute that day's extra
    /// hour to its neighbor — the old `startOfDay + 86_400` did exactly that.
    @Test func weekBucketsRespectTwentyFiveHourDays() {
        let weekStart = Self.date(2026, 10, 26, 0)
        let buckets = TimeBuckets.buckets(
            [Self.block("work", from: Self.date(2026, 11, 1, 0), to: Self.date(2026, 11, 2, 0))],
            lens: .category, span: .week, groups: ["work"],
            window: .init(from: weekStart, to: Self.date(2026, 11, 2, 0), calendar: Self.newYork))

        #expect(buckets.count == 1)
        #expect(abs(buckets[0].hours - 25) < 0.001)
    }

    @Test func groupsOutsideTheRankedSetFoldIntoOther() {
        let buckets = TimeBuckets.buckets(
            [Self.block("work", from: Self.date(2026, 6, 10, 9),
                        to: Self.date(2026, 6, 10, 10), theme: "ranked"),
             Self.block("work", from: Self.date(2026, 6, 10, 9),
                        to: Self.date(2026, 6, 10, 10), theme: "unranked")],
            lens: .theme, span: .day, groups: ["ranked"],
            window: .init(from: Self.date(2026, 6, 10, 0), to: Self.date(2026, 6, 11, 0),
                         calendar: Self.newYork))

        #expect(Set(buckets.map(\.group)) == ["ranked", TimeBreakdown.otherLabel])
    }

    @Test func blocksAreClippedToTheWindowAtBothEnds() {
        let buckets = TimeBuckets.buckets(
            [Self.block("work", from: Self.date(2026, 6, 9, 22), to: Self.date(2026, 6, 11, 2))],
            lens: .category, span: .day, groups: ["work"],
            window: .init(from: Self.date(2026, 6, 10, 0), to: Self.date(2026, 6, 11, 0),
                         calendar: Self.newYork))

        #expect(abs(buckets.reduce(0) { $0 + $1.hours } - 24) < 0.001)
    }

    @Test func noActivityYieldsNoBuckets() {
        #expect(TimeBuckets.buckets(
            [], lens: .category, span: .day, groups: [],
            window: .init(from: Self.date(2026, 6, 10, 0), to: Self.date(2026, 6, 11, 0),
                         calendar: Self.newYork)).isEmpty)
    }

    /// The ledger can hand back a zero-length or reversed block after a clock
    /// change; neither should produce a bar or an infinite walk.
    @Test func degenerateBlocksAreIgnored() {
        let noon = Self.date(2026, 6, 10, 12)
        let buckets = TimeBuckets.buckets(
            [Self.block("work", from: noon, to: noon),
             Self.block("work", from: noon, to: noon.addingTimeInterval(-3_600))],
            lens: .category, span: .day, groups: ["work"],
            window: .init(from: Self.date(2026, 6, 10, 0), to: Self.date(2026, 6, 11, 0),
                         calendar: Self.newYork))
        #expect(buckets.isEmpty)
    }
}

/// Today's stepping stones (design.md §7) — same hour arithmetic, different
/// shape.
@MainActor
@Suite struct DayTrailTests {
    private static func block(_ category: String, hour: Int, minutes: Int)
        -> LedgerBuilder.LabeledActivity {
        let dayStart = Calendar.current.startOfDay(for: Date())
        let start = dayStart.addingTimeInterval(TimeInterval(hour * 3_600))
        return LedgerBuilder.LabeledActivity(
            id: Int64(hour),
            startedAt: Int64(start.timeIntervalSince1970 * 1_000),
            endedAt: Int64(start.addingTimeInterval(TimeInterval(minutes * 60))
                .timeIntervalSince1970 * 1_000),
            category: category, source: "com.example.app")
    }

    private static func now(hour: Int) -> Date {
        Calendar.current.startOfDay(for: Date())
            .addingTimeInterval(TimeInterval(hour * 3_600 + 1_800))
    }

    @Test func stonesCoverEveryHourFromTheWindowStartToNow() {
        let stones = DayTrail.stones(from: [Self.block("work", hour: 10, minutes: 30)],
                                     now: Self.now(hour: 14))
        #expect(stones.first?.hour == 8)
        #expect(stones.last?.hour == 14)
        #expect(stones.map(\.hour) == Array(8...14))
    }

    @Test func anEarlyStartWidensTheRouteRatherThanFallingOffIt() {
        let stones = DayTrail.stones(from: [Self.block("work", hour: 5, minutes: 45)],
                                     now: Self.now(hour: 11))
        #expect(stones.first?.hour == 5)
        #expect(stones.contains { $0.hour == 5 && !$0.isEmpty })
    }

    @Test func aDayThatHasBarelyBegunStillShowsARoadAhead() {
        let stones = DayTrail.stones(from: [], now: Self.now(hour: 9))
        #expect(stones.count >= 6)
        #expect(stones.filter { !$0.isEmpty }.isEmpty)
    }

    @Test func aStoneIsColoredByWhateverMostOfTheHourWas() throws {
        let stones = DayTrail.stones(
            from: [Self.block("work", hour: 10, minutes: 45),
                   Self.block("social", hour: 10, minutes: 10)],
            now: Self.now(hour: 12))
        let ten = try #require(stones.first { $0.hour == 10 })
        #expect(ten.label == "work")
        #expect(ten.ms == 55 * 60_000)
    }

    @Test func aBlockSpanningHoursIsSplitBetweenThem() throws {
        let stones = DayTrail.stones(from: [Self.block("work", hour: 9, minutes: 90)],
                                     now: Self.now(hour: 12))
        let (ninth, tenth) = (try #require(stones.first { $0.hour == 9 }),
                              try #require(stones.first { $0.hour == 10 }))
        #expect(ninth.ms == 60 * 60_000)
        #expect(tenth.ms == 30 * 60_000)
    }

    @Test func underAMinuteIsRoundingNoiseNotAStone() throws {
        let stones = DayTrail.stones(from: [Self.block("work", hour: 10, minutes: 0)],
                                     now: Self.now(hour: 12))
        #expect(try #require(stones.first { $0.hour == 10 }).isEmpty)
    }

    @Test func fillSaturatesAtAFullHour() {
        let stone = DayTrail.Stone(hour: 9, ms: 7_200_000, label: "work", color: .clear)
        #expect(stone.fill == 1)
    }
}
