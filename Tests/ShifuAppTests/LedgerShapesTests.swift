import Foundation
import ShifuCore
import SwiftUI
import Testing
@testable import ShifuApp

/// The ribbon's arithmetic. Both suites here pin regressions found by looking
/// at the thing on a real ledger rather than by reasoning about it: a rail that
/// spanned three days, and a rail shredded into two hundred hairlines.
@Suite struct LedgerClockTests {
    static let calendar = Calendar(identifier: .gregorian)

    static func day(_ dayOffset: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2_026, month: 7, day: 27 + dayOffset))!
    }

    static func at(_ hour: Int, _ minute: Int = 0, day dayOffset: Int = 0) -> Date {
        calendar.date(byAdding: DateComponents(hour: hour, minute: minute),
                      to: day(dayOffset))!
    }

    static func block(
        from: Date, to: Date, category: String = "work", task: String? = nil
    ) -> LedgerBuilder.LabeledActivity {
        LedgerBuilder.LabeledActivity(
            id: Int64(from.timeIntervalSince1970),
            startedAt: Int64(from.timeIntervalSince1970 * 1_000),
            endedAt: Int64(to.timeIntervalSince1970 * 1_000),
            category: category, source: "app", taskName: task)
    }

    @Test func theRailCoversTheHoursThatWereWorked() {
        let clock = LedgerShapes.clock(
            [Self.block(from: Self.at(9, 10), to: Self.at(11, 20))],
            from: Self.day(), to: Self.at(23, 59), calendar: Self.calendar)
        #expect(clock.startHour == 9)
        // Rounded up, so the block that ends at 11:20 isn't clipped mid-band.
        #expect(clock.endHour == 12)
    }

    /// The block list includes anything *overlapping* the day, so a session
    /// that began at 23:00 last night arrives with yesterday's start time. Left
    /// unclipped it dragged the whole rail back to 23:00 and left the day
    /// squashed into the last inch of it.
    @Test func aBlockStartedYesterdayDoesNotDragTheRailBackwards() {
        let overnight = Self.block(from: Self.at(23, 0, day: -1), to: Self.at(0, 30))
        let morning = Self.block(from: Self.at(9), to: Self.at(10))
        let clock = LedgerShapes.clock(
            [overnight, morning], from: Self.day(), to: Self.at(23, 59),
            calendar: Self.calendar)
        #expect(clock.startHour == 0)
        #expect(clock.span <= 24)
    }

    /// The week draws one rail per day on a shared clock. An *absolute* window
    /// made that clock span the whole week, so every day's rail showed every
    /// day's work.
    @Test func aWeeksClockStaysInsideOneDay() {
        let monday = Self.block(from: Self.at(8), to: Self.at(9))
        let thursday = Self.block(from: Self.at(20, day: 3), to: Self.at(21, day: 3))
        let clock = LedgerShapes.clock(
            [monday, thursday], from: Self.day(), to: Self.at(23, 59, day: 6),
            calendar: Self.calendar)
        #expect(clock.startHour == 8)
        #expect(clock.endHour == 21)
        #expect(clock.span == 13)
    }

    @Test func anEmptyWindowFallsBackToAWorkingDay() {
        let clock = LedgerShapes.clock(
            [], from: Self.day(), to: Self.at(23, 59), calendar: Self.calendar)
        #expect(clock == LedgerShapes.Clock(startHour: 7, endHour: 22))
    }

    @Test func ticksStartAtTheRailsFirstHourAndNeverExceedTheLimit() {
        let ticks = LedgerShapes.ticks(
            LedgerShapes.Clock(startHour: 7, endHour: 22), limit: 8)
        #expect(ticks.first == 7)
        #expect(ticks.count <= 8)
    }
}

@Suite struct LedgerRibbonTests {
    typealias Fixture = LedgerClockTests

    /// A real day is hundreds of heartbeat-sized blocks. Drawn one segment per
    /// block the rail came out as a barcode; resampling folds a solid stretch
    /// of one category back into a single band.
    @Test func aStretchOfManyTinyBlocksBecomesOneBand() {
        let blocks = (0..<120).map { step in
            Fixture.block(
                from: Fixture.at(9, step), to: Fixture.at(9, step).addingTimeInterval(55))
        }
        let segments = LedgerShapes.ribbon(
            blocks, lens: .category, colors: ["work": Instrument.strong],
            from: Fixture.at(9), to: Fixture.at(11))
        let bands = segments.filter { $0.fill != .gap }
        #expect(bands.count == 1)
        #expect(bands.first?.caption == "work")
    }

    @Test func aGapBetweenTwoSpellsIsKept() {
        let segments = LedgerShapes.ribbon(
            [Fixture.block(from: Fixture.at(9), to: Fixture.at(10)),
             Fixture.block(from: Fixture.at(12), to: Fixture.at(13))],
            lens: .category, colors: ["work": Instrument.strong],
            from: Fixture.at(9), to: Fixture.at(13))
        #expect(segments.filter { $0.fill == .gap }.count == 1)
        #expect(segments.filter { $0.fill != .gap }.count == 2)
    }

    /// Private time is hatched whatever the lens is: it was measured, never
    /// read, and a ribbon that drew it as a gap would be claiming the machine
    /// was idle.
    @Test func privateTimeIsHatchedRatherThanColouredOrEmpty() {
        let segments = LedgerShapes.ribbon(
            [Fixture.block(from: Fixture.at(9), to: Fixture.at(10), category: "private")],
            lens: .task, colors: [:], from: Fixture.at(9), to: Fixture.at(10))
        #expect(segments.allSatisfy { $0.fill == .hidden })
    }

    @Test func aWindowWithNothingInItIsAllGap() {
        let segments = LedgerShapes.ribbon(
            [], lens: .category, colors: [:], from: Fixture.at(9), to: Fixture.at(17))
        #expect(segments.count == 1)
        #expect(segments.first?.fill == .gap)
    }

    /// Sparklines line up across a table only if every run is the same length,
    /// zeros included.
    @Test func everyWeeklyRunCoversTheFullSpan() {
        let now = Fixture.at(12)
        let runs = LedgerShapes.weeklyTotals(
            [Fixture.block(from: Fixture.at(9), to: Fixture.at(10), task: "drafting")],
            weeks: 8, now: now, calendar: Fixture.calendar) { $0.taskName }
        #expect(runs["drafting"]?.count == 8)
        // This week is the last bucket, and the ones before it stay empty.
        #expect(runs["drafting"]?.last == 3_600_000)
        #expect(runs["drafting"]?.dropLast().allSatisfy { $0 == 0 } == true)
    }
}
