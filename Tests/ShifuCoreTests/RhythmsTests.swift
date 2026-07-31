import Foundation
import Testing
@testable import ShifuCore

/// What the week's shape is allowed to claim. The thresholds are the feature:
/// a rhythm signal is drawn on the user's own rails, so a reading they cannot
/// verify by looking costs more than no reading at all. Most of what follows
/// is really one assertion — *say nothing rather than something shaky*.
@Suite struct RhythmNightTests {
    static let calendar = Calendar(identifier: .gregorian)

    /// Monday 27 July 2026 — the week the dogfood ledger was read on.
    static func day(_ offset: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2_026, month: 7, day: 27 + offset))!
    }

    /// Hours past that day's midnight, so 26:30 is half past two the next
    /// morning — the night clock the detector itself fits against.
    static func at(_ hour: Int, _ minute: Int = 0, day dayOffset: Int = 0) -> Date {
        calendar.date(byAdding: DateComponents(hour: hour, minute: minute),
                      to: day(dayOffset))!
    }

    static func block(from: Date, to: Date) -> LedgerBuilder.LabeledActivity {
        LedgerBuilder.LabeledActivity(
            id: Int64(from.timeIntervalSince1970),
            startedAt: Int64(from.timeIntervalSince1970 * 1_000),
            endedAt: Int64(to.timeIntervalSince1970 * 1_000),
            category: "work", source: "app")
    }

    static func nights(
        _ blocks: [LedgerBuilder.LabeledActivity], to end: Date
    ) -> [Rhythms.Night] {
        Rhythms.nights(blocks, from: day(), to: end, calendar: calendar)
    }

    /// The rule the whole feature rests on: a night is the quiet that covers
    /// 4 AM. One test for the two shapes it has to serve — the person who
    /// turns in before midnight and the person who turns in after it — because
    /// any per-day bucketing would only ever get one of them right.
    @Test func theQuietThatCoversFourAMIsTheNight() {
        let nights = Self.nights(
            [Self.block(from: Self.at(9), to: Self.at(23, 30)),
             Self.block(from: Self.at(7, day: 1), to: Self.at(26, 30, day: 1)),
             Self.block(from: Self.at(9, day: 2), to: Self.at(18, day: 2))],
            to: Self.at(18, day: 2))

        // Monday's own morning is a night too: the window bounds it instead of
        // a block, so it carries a rise and no settle.
        #expect(nights.count == 3)
        #expect(nights[0].settled == nil)
        #expect(nights[0].stirred?.at == Self.at(9))
        // Turned in before midnight — the mark belongs to Monday's rail.
        #expect(nights[1].settled?.at == Self.at(23, 30))
        #expect(nights[1].settled?.day == Self.day())
        #expect(nights[1].stirred?.at == Self.at(7, day: 1))
        // …and after it — on Wednesday's, which is the rail it is drawn over.
        #expect(nights[2].settled?.at == Self.at(2, 30, day: 2))
        #expect(nights[2].settled?.day == Self.day(2))
    }

    /// A long weekend away is one 60-hour gap. Without a ceiling it reads as a
    /// single enormous night charged to whichever day it started on, and drags
    /// a bedtime mark onto a rail nobody was at the screen for.
    @Test func anAbsenceIsNotANight() {
        let nights = Self.nights(
            [Self.block(from: Self.at(9), to: Self.at(18)),
             Self.block(from: Self.at(9, day: 3), to: Self.at(18, day: 3))],
            to: Self.at(18, day: 3))
        #expect(nights.allSatisfy { $0.settled == nil })
    }

    /// An afternoon out can be long enough to reach past 4 AM (14:00 → 05:00
    /// is fifteen hours), and 2 PM is not a bedtime whatever the gap does.
    @Test func anAfternoonAwayIsNotABedtime() {
        let nights = Self.nights(
            [Self.block(from: Self.at(9), to: Self.at(14)),
             Self.block(from: Self.at(5, day: 1), to: Self.at(12, day: 1))],
            to: Self.at(12, day: 1))
        #expect(nights.contains { $0.stirred?.at == Self.at(5, day: 1) })
        #expect(nights.allSatisfy { $0.settled == nil })
    }

    /// A real day is two hundred blocks of forty seconds. Folded at anything
    /// tighter than the sessionizer's own threshold, every breath between them
    /// would open a night.
    @Test func heartbeatSizedBlocksDoNotOpenANight() {
        let blocks = (0..<200).map { step in
            Self.block(
                from: Self.at(9, step), to: Self.at(9, step).addingTimeInterval(55))
        }
        let nights = Self.nights(blocks, to: Self.at(13))
        #expect(nights.count == 1)
        #expect(nights[0].stirred?.at == Self.at(9))
        #expect(nights[0].settled == nil)
    }

    /// The dogfood ledger holds rows spanning forty hours — a rebuild artefact
    /// the schema cannot rule out. A block that swallows the window leaves no
    /// quiet, and no quiet has to mean no claim rather than a wrong one.
    @Test func aBlockThatSwallowsTheWindowLeavesNothingToRead() {
        let nights = Self.nights(
            [Self.block(from: Self.at(0), to: Self.at(0, day: 3))], to: Self.at(0, day: 3))
        #expect(nights.isEmpty)
    }
}

@Suite struct RhythmSignalTests {
    typealias Fixture = RhythmNightTests

    /// A week of days that begin at `rise` and run until `settle`, both on
    /// their own day's night clock — so a settle of (26, 30) is half past two
    /// the following morning and (23, 50) is ten to midnight tonight.
    static func week(
        rise: [(Int, Int)], settle: [(Int, Int)]
    ) -> [LedgerBuilder.LabeledActivity] {
        zip(rise, settle).enumerated().map { index, hours in
            let (up, down) = hours
            return Fixture.block(
                from: Fixture.at(up.0, up.1, day: index),
                to: Fixture.at(down.0, down.1, day: index))
        }
    }

    static func signals(
        _ blocks: [LedgerBuilder.LabeledActivity], to end: Date
    ) -> [Rhythms.Signal] {
        Rhythms.signals(blocks, from: Fixture.day(), to: end, calendar: Fixture.calendar)
    }

    /// The reading the whole feature exists for: four nights sliding forty
    /// minutes earlier each time.
    @Test func aRunOfEarlierNightsDrifts() throws {
        let signals = Self.signals(
            Self.week(
                rise: [(9, 0), (9, 0), (9, 0), (9, 0)],
                settle: [(26, 30), (25, 50), (25, 10), (24, 30)]),
            to: Fixture.at(12, day: 4))

        let nightfall = try #require(signals.first { $0.edge == .nightfall })
        #expect(nightfall.shape == .drifting(minutesPerDay: -40))
        #expect(nightfall.marks.count == 4)
        #expect(nightfall.headline == "settling 40m earlier each night")
        // Every mark sits on the rail it was read from, so the claim can be
        // checked against the drawing.
        #expect(nightfall.marks.first?.day == Fixture.day(1))
        #expect(nightfall.marks.last?.day == Fixture.day(4))
    }

    /// Mornings that never move are worth saying too — and they are the case
    /// a straight-line fit cannot describe at all, since a flat run has no
    /// spread to correlate against.
    @Test func aRunThatNeverMovesReadsAsSteady() throws {
        let signals = Self.signals(
            Self.week(
                rise: [(7, 0), (7, 0), (7, 5), (6, 55)],
                settle: [(26, 30), (25, 50), (25, 10), (24, 30)]),
            to: Fixture.at(12, day: 4))

        let daybreak = try #require(signals.first { $0.edge == .daybreak })
        #expect(daybreak.shape == .steady(centre: 420, spread: 5))
        #expect(daybreak.headline.hasPrefix("starting around ") == true)
        #expect(daybreak.headline.hasSuffix(", ± 5m") == true)
    }

    /// Bedtimes that scatter are the common case, and the one a lax threshold
    /// turns into a fabricated trend: this run *does* fit a line sloping
    /// eighteen minutes a night, and agrees with it far too weakly to say so.
    @Test func aScatteredRunSaysNothing() {
        let signals = Self.signals(
            Self.week(
                rise: [(9, 0), (7, 30), (10, 0), (8, 15)],
                settle: [(26, 30), (24, 40), (26, 10), (25, 0)]),
            to: Fixture.at(12, day: 4))
        #expect(signals.isEmpty)
    }

    /// Two points are a straight line through anything.
    @Test func twoNightsAreNotARun() {
        let signals = Self.signals(
            Self.week(rise: [(9, 0), (9, 0)], settle: [(26, 30), (25, 10)]),
            to: Fixture.at(12, day: 2))
        #expect(signals.isEmpty)
    }

    /// A run that straddles midnight — 23:50, then 00:20, then 00:50 — is half
    /// an hour *later* each night, not twenty-four hours earlier. Without the
    /// shifted night clock this is the reading the feature gets wrong on the
    /// most ordinary schedule there is.
    @Test func aRunStraddlingMidnightIsMinutesApartNotADay() throws {
        let signals = Self.signals(
            Self.week(
                rise: [(7, 0), (7, 0), (7, 0)],
                settle: [(23, 50), (24, 20), (24, 50)]),
            to: Fixture.at(12, day: 3))

        let nightfall = try #require(signals.first { $0.edge == .nightfall })
        #expect(nightfall.shape == .drifting(minutesPerDay: 30))
        #expect(nightfall.headline == "settling 30m later each night")
        // Monday evening, then past midnight on Wednesday and Thursday: three
        // consecutive *nights*, so the fit must not see a day of daylight
        // between the first two.
        #expect(nightfall.marks.map(\.day) == [Fixture.day(0), Fixture.day(2), Fixture.day(3)])
    }

    /// Nothing to read is not an error, and an empty week must not produce a
    /// zero-slope "trend".
    @Test func anEmptyWeekSaysNothing() {
        #expect(Self.signals([], to: Fixture.at(12, day: 4)).isEmpty)
    }
}
