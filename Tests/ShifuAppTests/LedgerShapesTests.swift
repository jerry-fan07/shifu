import Foundation
import ShifuCore
import SwiftUI
import Testing
@testable import ShifuApp

/// The ribbon's and the bars' arithmetic. The clock and ribbon suites pin
/// regressions found by looking at the thing on a real ledger rather than by
/// reasoning about it: a rail that spanned three days, and a rail shredded
/// into two hundred hairlines.
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
        #expect(ticks.first?.hour == 7)
        #expect(ticks.count <= 8)
    }

    /// The bug the axis carried for its whole life: eight ticks over a day stop
    /// at 21:00, and laying them out by count rather than by place slid every
    /// label right of the band it names — an hour by mid-morning, nearly three
    /// by the end. A tick's place is the fraction of the rail its hour is at,
    /// full stop.
    @Test func aTicksPlaceIsWhereItsHourFallsNotWhereItsIndexDoes() {
        let ticks = LedgerShapes.ticks(
            LedgerShapes.Clock(startHour: 0, endHour: 24), limit: 8)
        #expect(ticks.map(\.hour) == [0, 3, 6, 9, 12, 15, 18, 21])
        for tick in ticks { #expect(tick.place == Double(tick.hour) / 24) }
        // And the last one stops short of the rail's end, because 21:00 does.
        #expect(ticks.last?.place == 0.875)
    }

    /// A rail that doesn't start at midnight is placed from its own first hour,
    /// and a tick that wraps past midnight keeps its true place.
    @Test func placesAreMeasuredFromTheRailsOwnStart() {
        let ticks = LedgerShapes.ticks(
            LedgerShapes.Clock(startHour: 20, endHour: 28), limit: 4)
        #expect(ticks.map(\.hour) == [20, 22, 0, 2])
        #expect(ticks.map(\.place) == [0, 0.25, 0.5, 0.75])
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

    /// A rhythm mark claims a *place* on a rail — "this is where the night
    /// ended" — so it has to land on the same arithmetic that drew the bands
    /// under it, and a mark for a night off the end of the rail has to draw
    /// nowhere rather than clamped to the edge, where it would read as a night
    /// that ended at breakfast.
    @Test func aMarkLandsWhereTheRibbonPutItsBands() {
        let rail = LedgerShapes.Clock(startHour: 6, endHour: 18).on(
            Fixture.day(), calendar: Fixture.calendar)
        #expect(LedgerShapes.position(of: Fixture.at(6), on: rail) == 0)
        #expect(LedgerShapes.position(of: Fixture.at(12), on: rail) == 0.5)
        #expect(LedgerShapes.position(of: Fixture.at(18), on: rail) == 1)
        #expect(LedgerShapes.position(of: Fixture.at(5, 59), on: rail) == nil)
        #expect(LedgerShapes.position(of: Fixture.at(2, day: 1), on: rail) == nil)
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

/// The Timeline's chart. Stacked bars answer "how much at 10 AM", so what
/// each column claims has to be the clipped truth of its slot.
@Suite struct LedgerBarTests {
    typealias Fixture = LedgerClockTests

    static func hourSlots(_ hours: Range<Int>) -> [LedgerShapes.Slot] {
        hours.map {
            LedgerShapes.Slot(tick: "\($0)", from: Fixture.at($0), to: Fixture.at($0 + 1))
        }
    }

    @Test func aBlockIsSplitAcrossTheHoursItSpans() {
        let stacks = LedgerShapes.bars(
            [Fixture.block(from: Fixture.at(9, 30), to: Fixture.at(11, 30))],
            lens: .category, colors: ["work": Instrument.strong],
            order: ["work"], slots: Self.hourSlots(9..<13))
        #expect(stacks.map(\.totalMs) == [1_800_000, 3_600_000, 1_800_000, 0])
        #expect(stacks.last?.segments.isEmpty == true)
    }

    /// The stack keeps the Breakdown's ranking in every column, so a group
    /// sits at the same height of the pile all day.
    @Test func groupsStackInTheGivenOrder() {
        let stacks = LedgerShapes.bars(
            [Fixture.block(from: Fixture.at(9), to: Fixture.at(9, 20)),
             Fixture.block(
                from: Fixture.at(9, 20), to: Fixture.at(9, 50),
                category: "communication")],
            lens: .category,
            colors: ["work": Instrument.strong, "communication": Instrument.mid],
            order: ["communication", "work"], slots: Self.hourSlots(9..<10))
        #expect(stacks.first?.segments.map(\.ms) == [1_800_000, 1_200_000])
    }

    /// Private time is hatched whatever the lens is — same claim the ribbon
    /// makes — and rides on top of the stack.
    @Test func privateTimeRidesOnTopHatched() {
        let stacks = LedgerShapes.bars(
            [Fixture.block(from: Fixture.at(9), to: Fixture.at(9, 30)),
             Fixture.block(
                from: Fixture.at(9, 30), to: Fixture.at(10), category: "private")],
            lens: .category, colors: ["work": Instrument.strong],
            order: ["work"], slots: Self.hourSlots(9..<10))
        #expect(stacks.first?.segments.count == 2)
        #expect(stacks.first?.segments.last?.fill == .hidden)
        #expect(stacks.first?.totalMs == 3_600_000)
    }

    /// A label the palette doesn't carry folds into "Other" the way the
    /// table folds it, rather than minting a colour of its own.
    @Test func aGroupThePaletteDoesNotNameFoldsIntoOther() {
        let stacks = LedgerShapes.bars(
            [Fixture.block(from: Fixture.at(9), to: Fixture.at(10), task: "stray")],
            lens: .task, colors: ["Other": Instrument.other],
            order: ["Other"], slots: Self.hourSlots(9..<10))
        #expect(stacks.first?.segments.count == 1)
        #expect(stacks.first?.segments.first?.caption.hasPrefix("Other") == true)
    }

    /// Every band names the group it came from, spelled the way the legend
    /// spells it — that name is the only thing tying a legend row to its
    /// bands, so a segment that folded into "Other" has to say "Other" and
    /// not the label it arrived with.
    @Test func everySegmentNamesItsGroup() {
        let stacks = LedgerShapes.bars(
            [Fixture.block(from: Fixture.at(9), to: Fixture.at(9, 20), task: "writing"),
             Fixture.block(from: Fixture.at(9, 20), to: Fixture.at(9, 40), task: "stray")],
            lens: .task,
            colors: ["writing": Instrument.strong, "Other": Instrument.other],
            order: ["writing", "Other"], slots: Self.hourSlots(9..<10))
        #expect(stacks.first?.segments.map(\.name) == ["writing", "Other"])
    }

    /// Private time is named too, by the category it is — so under the
    /// Category lens its legend row can find its own hatched bands.
    @Test func privateTimeIsNamedByItsCategory() {
        let stacks = LedgerShapes.bars(
            [Fixture.block(from: Fixture.at(9), to: Fixture.at(9, 30)),
             Fixture.block(
                from: Fixture.at(9, 30), to: Fixture.at(10), category: "private")],
            lens: .category, colors: ["work": Instrument.strong],
            order: ["work"], slots: Self.hourSlots(9..<10))
        #expect(stacks.first?.segments.map(\.name) == ["work", "private"])
    }

    /// Time in a group the order forgot is still drawn — a chart that
    /// silently drops a group is lying about the hour.
    @Test func aGroupMissingFromTheOrderIsStillDrawn() {
        let stacks = LedgerShapes.bars(
            [Fixture.block(from: Fixture.at(9), to: Fixture.at(10))],
            lens: .category, colors: ["work": Instrument.strong],
            order: [], slots: Self.hourSlots(9..<10))
        #expect(stacks.first?.totalMs == 3_600_000)
        #expect(stacks.first?.segments.first?.caption == "Work — 1h 0m")
    }
}
