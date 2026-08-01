import Foundation
import Testing
@testable import ShifuCore

/// The two clocks under the Focus Mode switch (design.md §4.4). All arithmetic
/// and formatting, no clock of its own — which is the point of `FocusClock`
/// being a pure enum rather than a timer somebody has to keep running.
@Suite struct FocusClockTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - The reading

    @Test func focusOffAndNeverRunLeavesBothClocksBlank() {
        let reading = FocusClock.reading(now: Self.now, startedAt: nil, previousEnd: nil)
        #expect(reading.elapsed == nil)
        #expect(reading.away == nil)
        #expect(!reading.isRunning)
    }

    @Test func aRunningSessionMeasuresFromWhenTheSwitchWasFlipped() {
        let reading = FocusClock.reading(
            now: Self.now, startedAt: Self.now.addingTimeInterval(-900), previousEnd: nil)
        #expect(reading.elapsed == 900)
        #expect(reading.isRunning)
    }

    /// The half that makes "since the previous session" mean something while
    /// one is running: the gap is what came *before* this session, so it stops
    /// moving the moment focus starts. A gap that grew while you focused would
    /// read as punishment for focusing.
    @Test func whileRunningTheGapIsFrozenAtTheSessionStart() {
        let startedAt = Self.now.addingTimeInterval(-900)
        let reading = FocusClock.reading(
            now: Self.now, startedAt: startedAt,
            previousEnd: startedAt.addingTimeInterval(-2_820))
        #expect(reading.elapsed == 900)
        #expect(reading.away == 2_820)

        // Ten minutes further into the same session: the stopwatch moves, the
        // gap does not.
        let later = FocusClock.reading(
            now: Self.now.addingTimeInterval(600), startedAt: startedAt,
            previousEnd: startedAt.addingTimeInterval(-2_820))
        #expect(later.elapsed == 1_500)
        #expect(later.away == 2_820)
    }

    @Test func withFocusOffTheGapRunsFromTheLastSessionsEnd() {
        let reading = FocusClock.reading(
            now: Self.now, startedAt: nil,
            previousEnd: Self.now.addingTimeInterval(-4_500))
        #expect(reading.elapsed == nil)
        #expect(reading.away == 4_500)
    }

    /// A clock that stepped back, or a restored `~/Shifu` whose control file
    /// is younger than the machine thinks: a session that hasn't started yet
    /// reads as one that just did, never as a negative stopwatch.
    @Test func aStartInTheFutureReadsAsZeroRatherThanNegative() {
        let reading = FocusClock.reading(
            now: Self.now, startedAt: Self.now.addingTimeInterval(120),
            previousEnd: Self.now.addingTimeInterval(-60))
        #expect(reading.elapsed == 0)
        #expect(reading.away == 180)   // measured to the start, still positive
    }

    @Test func anEndAfterNowReadsAsNoGapRatherThanNegative() {
        let reading = FocusClock.reading(
            now: Self.now, startedAt: nil,
            previousEnd: Self.now.addingTimeInterval(30))
        #expect(reading.away == 0)
    }

    // MARK: - The stopwatch

    @Test func theStopwatchWearsSecondsUntilTheFirstHour() {
        #expect(FocusClock.stopwatch(0) == "0:00")
        #expect(FocusClock.stopwatch(7) == "0:07")
        #expect(FocusClock.stopwatch(59) == "0:59")
        #expect(FocusClock.stopwatch(60) == "1:00")
        #expect(FocusClock.stopwatch(12 * 60 + 4) == "12:04")
        #expect(FocusClock.stopwatch(3_599) == "59:59")
    }

    @Test func pastAnHourItGrowsAnHoursFieldAndPadsTheMinutes() {
        #expect(FocusClock.stopwatch(3_600) == "1:00:00")
        #expect(FocusClock.stopwatch(3_661) == "1:01:01")
        #expect(FocusClock.stopwatch(3_600 * 10 + 120 + 5) == "10:02:05")
    }

    @Test func theStopwatchNeverGoesBackwardsPastZero() {
        #expect(FocusClock.stopwatch(-5) == "0:00")
    }

    // MARK: - The gap

    @Test func theGapNamesTheCoarsestUnitThatStillSaysSomething() {
        #expect(FocusClock.since(0) == "0s")
        #expect(FocusClock.since(48) == "48s")
        #expect(FocusClock.since(59) == "59s")
        #expect(FocusClock.since(60) == "1m")
        #expect(FocusClock.since(34 * 60 + 59) == "34m")
        #expect(FocusClock.since(3_600) == "1h")
        #expect(FocusClock.since(3 * 3_600 + 20 * 60) == "3h 20m")
    }

    /// Days at the top end rather than the ledger's hours: this figure is
    /// routinely a day or more old, and "74h 12m ago" is not a phrase anyone
    /// reads as "the day before yesterday".
    @Test func pastADayTheGapDropsToWholeDays() {
        #expect(FocusClock.since(24 * 3_600 - 1) == "23h 59m")
        #expect(FocusClock.since(24 * 3_600) == "1d")
        #expect(FocusClock.since(74 * 3_600 + 12 * 60) == "3d")
    }
}
