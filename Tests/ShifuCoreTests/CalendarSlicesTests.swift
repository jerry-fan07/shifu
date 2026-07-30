import Foundation
import Testing
@testable import ShifuCore

/// Splitting a span across calendar buckets. The reason this is one function
/// rather than a loop at each call site is that the obvious loop hangs: see
/// `CalendarSlices` for which DST transition does it and why.
@Suite struct CalendarSlicesTests {
    static let newYork: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }()

    private static func date(_ year: Int, _ month: Int, _ day: Int,
                             _ hour: Int, _ minute: Int = 0) -> Date {
        newYork.date(from: DateComponents(
            timeZone: newYork.timeZone, year: year, month: month, day: day,
            hour: hour, minute: minute))!
    }

    private func collect(from: Date, to: Date, unit: Calendar.Component) -> [(Date, Int64)] {
        var slices: [(Date, Int64)] = []
        CalendarSlices.walk(from: from, to: to, unit: unit, calendar: Self.newYork) {
            slices.append(($0, $1))
        }
        return slices
    }

    @Test func slicesTileTheSpanAndSumToItsLength() throws {
        let from = Self.date(2026, 6, 10, 9, 20)
        let to = Self.date(2026, 6, 10, 12, 45)
        let slices = collect(from: from, to: to, unit: .hour)

        #expect(slices.count == 4)
        #expect(slices.reduce(0) { $0 + $1.1 } == Int64(to.timeIntervalSince(from) * 1_000))
        #expect(slices[0].0 == from)                      // clipped at the start
        #expect(slices[0].1 == 40 * 60_000)               // 09:20 → 10:00
        let last = try #require(slices.last)
        #expect(last.1 == 45 * 60_000)                    // 12:00 → 12:45
    }

    @Test func aSpanInsideOneUnitIsASingleSlice() {
        let from = Self.date(2026, 6, 10, 9, 10)
        let slices = collect(from: from, to: Self.date(2026, 6, 10, 9, 50), unit: .hour)
        #expect(slices.count == 1)
        #expect(slices[0].1 == 40 * 60_000)
    }

    @Test func anEmptyOrReversedSpanYieldsNothing() {
        let noon = Self.date(2026, 6, 10, 12)
        #expect(collect(from: noon, to: noon, unit: .hour).isEmpty)
        #expect(collect(from: noon, to: noon.addingTimeInterval(-3_600), unit: .hour).isEmpty)
    }

    /// The hang. On 2026-11-01 America/New_York repeats 01:00–02:00, and the
    /// old `date(bySettingHour:)` walk resolved the repeated hour to its
    /// *first* occurrence — behind the cursor — so the loop never advanced.
    @Test func theRepeatedHourOfAFallBackTerminatesAndIsCountedTwice() {
        let dayStart = Self.date(2026, 11, 1, 0)
        let dayEnd = Self.date(2026, 11, 2, 0)
        let slices = collect(from: dayStart, to: dayEnd, unit: .hour)

        #expect(slices.count == 25)
        #expect(slices.reduce(0) { $0 + $1.1 } == 25 * 3_600_000)
        let ones = slices.filter { Self.newYork.component(.hour, from: $0.0) == 1 }
        #expect(ones.count == 2)
    }

    /// The crash. On 2026-03-08 02:00 never happens, and
    /// `date(bySettingHour: 2, …)` is nil there — force-unwrapped.
    @Test func theSkippedHourOfASpringForwardIsSimplyAbsent() {
        let dayStart = Self.date(2026, 3, 8, 0)
        let dayEnd = Self.date(2026, 3, 9, 0)
        let slices = collect(from: dayStart, to: dayEnd, unit: .hour)

        #expect(slices.count == 23)
        #expect(slices.reduce(0) { $0 + $1.1 } == 23 * 3_600_000)
        #expect(!slices.contains { Self.newYork.component(.hour, from: $0.0) == 2 })
    }

    @Test func dayUnitsFollowTheCalendarNotEightySixFourHundredSeconds() {
        // A week containing the 25-hour fall-back day.
        let slices = collect(from: Self.date(2026, 10, 30, 0),
                             to: Self.date(2026, 11, 3, 0), unit: .day)
        #expect(slices.count == 4)
        #expect(slices.map(\.1) == [86_400_000, 86_400_000, 90_000_000, 86_400_000])
    }

    @Test func everySliceStartsWhereTheLastOneEnded() {
        let from = Self.date(2026, 6, 10, 9, 20)
        let slices = collect(from: from, to: Self.date(2026, 6, 11, 3), unit: .hour)
        var cursor = from
        for (start, ms) in slices {
            #expect(start == cursor)
            cursor = start.addingTimeInterval(Double(ms) / 1_000)
        }
    }

    @Test func aNonFiniteBoundIsRefusedRatherThanLoopingForever() {
        #expect(collect(from: Date(timeIntervalSince1970: .infinity),
                        to: Self.date(2026, 6, 10, 12), unit: .hour).isEmpty)
        #expect(collect(from: Self.date(2026, 6, 10, 12),
                        to: Date(timeIntervalSince1970: .nan), unit: .hour).isEmpty)
    }

    /// A multi-day span sliced by hour is where an off-by-one would show up as
    /// a missing or duplicated hour rather than as a wrong total.
    @Test func aWeekLongSpanSlicedByHourHasNoGaps() {
        let from = Self.date(2026, 6, 8, 0)
        let to = Self.date(2026, 6, 15, 0)
        let slices = collect(from: from, to: to, unit: .hour)
        #expect(slices.count == 7 * 24)
        #expect(Set(slices.map(\.0)).count == slices.count)
        #expect(slices.allSatisfy { $0.1 == 3_600_000 })
    }
}
