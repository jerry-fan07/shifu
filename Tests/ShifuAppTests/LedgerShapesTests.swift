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
        // The limit counts the evenly spaced ticks; the closing hour is extra.
        #expect(ticks.count <= 9)
    }

    /// The bug the axis carried for its whole life: eight ticks over a day stop
    /// at 21:00, and laying them out by count rather than by place slid every
    /// label right of the band it names — an hour by mid-morning, nearly three
    /// by the end. A tick's place is the fraction of the rail its hour is at,
    /// full stop.
    @Test func aTicksPlaceIsWhereItsHourFallsNotWhereItsIndexDoes() {
        let ticks = LedgerShapes.ticks(LedgerShapes.Clock.day, limit: 8)
        #expect(ticks.dropLast().map(\.hour) == [0, 3, 6, 9, 12, 15, 18, 21])
        for tick in ticks.dropLast() { #expect(tick.place == Double(tick.hour) / 24) }
    }

    /// The stride stops three hours short of a day's end, so the rail used to
    /// close under an unnamed edge: an evening of bands with no hour on it, and
    /// an axis that looked like it ran out at 21:00.
    @Test func theHourTheRailClosesOnIsTicked() {
        let ticks = LedgerShapes.ticks(LedgerShapes.Clock.day, limit: 8)
        #expect(ticks.last?.place == 1)
        // 24, not 00: the end of the day rather than the start of it. Both ends
        // of a midnight-to-midnight rail name midnight, and reading "00" under
        // the right-hand edge is reading the wrong midnight.
        #expect(ticks.last?.hour == 24)
        #expect(ticks.last?.label == "24")
        #expect(ticks.first?.label == "00")
    }

    /// A fitted rail — the week band's — closes wherever its last block did,
    /// which the even stride can miss by anything up to a step.
    @Test func aFittedRailIsTickedToItsOwnLastHour() throws {
        let ticks = LedgerShapes.ticks(
            LedgerShapes.Clock(startHour: 7, endHour: 22), limit: 8)
        #expect(ticks.map(\.hour) == [7, 9, 11, 13, 15, 17, 19, 21, 22])
        #expect(ticks.last?.place == 1)
        // Still placed by hour, not by index: 21:00 is 14 hours into a 15-hour
        // rail, and eight-ninths of the way along would be an hour early.
        let penultimate = try #require(ticks.dropLast().last)
        #expect(penultimate.place == 14.0 / 15)
    }

    /// A rail that doesn't start at midnight is placed from its own first hour,
    /// and a tick that wraps past midnight keeps its true place — including the
    /// closing one, which is a small hour of the next morning rather than a 24.
    @Test func placesAreMeasuredFromTheRailsOwnStart() {
        let ticks = LedgerShapes.ticks(
            LedgerShapes.Clock(startHour: 20, endHour: 28), limit: 4)
        #expect(ticks.map(\.hour) == [20, 22, 0, 2, 4])
        #expect(ticks.map(\.place) == [0, 0.25, 0.5, 0.75, 1])
    }

    /// The axis draws its labels in a `ForEach` over these, so two ticks
    /// sharing an id would silently draw as one. Identity by hour did exactly
    /// that on the day rail, whose two ends both name midnight.
    @Test func everyTickOnARailIsDistinct() {
        for clock in [LedgerShapes.Clock.day,
                      LedgerShapes.Clock(startHour: 7, endHour: 22),
                      LedgerShapes.Clock(startHour: 20, endHour: 28)] {
            let ticks = LedgerShapes.ticks(clock)
            #expect(Set(ticks.map(\.id)).count == ticks.count)
        }
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

    /// The Breakdown draws one day on `Clock.day`, not on the hours that
    /// happened to have blocks in them. Fitted, a morning of work drew hard
    /// against the left edge and ran to the right one, so a two-hour day and a
    /// sixteen-hour day were the same picture and the axis ended wherever the
    /// last block did.
    @Test func theDayRailIsTheWholeDayNotJustTheHoursThatHadBlocks() {
        let block = Fixture.block(from: Fixture.at(9), to: Fixture.at(10))
        let rail = LedgerShapes.Clock.day.on(Fixture.day(), calendar: Fixture.calendar)
        #expect(rail.from == Fixture.day())
        #expect(rail.to == Fixture.day(1))

        let segments = LedgerShapes.ribbon(
            [block], lens: .category, colors: ["work": Instrument.strong],
            from: rail.from, to: rail.to)
        // The night before it, the band, and the whole rest of the day after.
        #expect(segments.map(\.fill) == [.gap, .series(Instrument.strong), .gap])
        // 9 AM is 9 hours into 24, so the band starts three eighths along.
        let start = Double(segments[0].weight) / Double(LedgerShapes.columns)
        #expect(start == 0.375)

        // What it looked like fitted: the same hour, against the left edge.
        let fitted = LedgerShapes.clock(
            [block], from: Fixture.day(), to: Fixture.at(23, 59),
            calendar: Fixture.calendar
        ).on(Fixture.day(), calendar: Fixture.calendar)
        #expect(LedgerShapes.ribbon(
            [block], lens: .category, colors: ["work": Instrument.strong],
            from: fitted.from, to: fitted.to).first?.fill == .series(Instrument.strong))
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
            lens: .theme, colors: [:], from: Fixture.at(9), to: Fixture.at(10))
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
            [Fixture.block(from: Fixture.at(9), to: Fixture.at(10))],
            lens: .theme, colors: ["Other": Instrument.other],
            order: ["Other"], slots: Self.hourSlots(9..<10))
        #expect(stacks.first?.segments.count == 1)
        #expect(stacks.first?.segments.first?.caption.hasPrefix("Other") == true)
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

@Suite struct FocusRibbonTests {
    typealias Fixture = LedgerClockTests

    private static func ms(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1_000)
    }

    private static func session(
        _ id: Int64, from: Date, to: Date, isLive: Bool = false
    ) -> FocusReport.Session {
        FocusReport.Session(
            id: id, startedAt: ms(from), endedAt: ms(to), isLive: isLive,
            onTaskMs: 0, offTaskMs: 0)
    }

    /// The band's three registers: session time gold, tracked time outside a
    /// session receded, untracked stretches still gaps.
    @Test func sessionIsGoldTrackedContextRecedesAndGapsStay() {
        let segments = LedgerShapes.focusRibbon(
            sessions: [Self.session(1, from: Fixture.at(9), to: Fixture.at(9, 30))],
            activities: [Fixture.block(from: Fixture.at(9), to: Fixture.at(10))],
            from: Fixture.at(9), to: Fixture.at(11))
        #expect(segments.map(\.fill) == [
            .series(Instrument.warm), .series(Instrument.quiet), .gap
        ])
        #expect(segments.first?.caption.hasPrefix("Focus — ") == true)
    }

    /// A session over an idle screen is still a session — Focus Mode was on,
    /// and the log says so even where the tracker has nothing.
    @Test func aSessionWithNothingTrackedUnderItStillDrawsGold() {
        let segments = LedgerShapes.focusRibbon(
            sessions: [Self.session(1, from: Fixture.at(9), to: Fixture.at(10))],
            activities: [],
            from: Fixture.at(9), to: Fixture.at(10))
        #expect(segments.count == 1)
        #expect(segments.first?.fill == .series(Instrument.warm))
    }

    /// Bands merge within one session only, so back-to-back sessions keep
    /// their own tooltips instead of fusing into one long claim.
    @Test func adjacentSessionsStaySeparateBands() {
        let segments = LedgerShapes.focusRibbon(
            sessions: [
                Self.session(1, from: Fixture.at(9), to: Fixture.at(10)),
                Self.session(2, from: Fixture.at(10), to: Fixture.at(11))
            ],
            activities: [],
            from: Fixture.at(9), to: Fixture.at(11))
        #expect(segments.count == 2)
        #expect(segments[0].caption != segments[1].caption)
    }

    /// An open session names its start and says it is still running, rather
    /// than pretending to know its end.
    @Test func aLiveSessionSaysSince() {
        let live = Self.session(
            1, from: Fixture.at(9), to: Fixture.at(10), isLive: true)
        #expect(LedgerShapes.span(live).hasPrefix("since "))
    }
}
