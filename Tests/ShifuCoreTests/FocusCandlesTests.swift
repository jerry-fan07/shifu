import Foundation
import Testing
@testable import ShifuCore

/// The focus index behind the ink slab's chart: on-task minutes climb,
/// off-task minutes fall, everything else holds. Pure arithmetic over rows,
/// so every claim the chart makes is checkable here.
@Suite struct FocusCandlesTests {
    private static let minute: Int64 = 60_000
    private static let start: Int64 = 1_800_000_000_000

    private static func block(
        _ category: String, from: Int64, to: Int64
    ) -> LedgerBuilder.LabeledActivity {
        LedgerBuilder.LabeledActivity(
            id: from, startedAt: from, endedAt: to, category: category, source: "test")
    }

    // MARK: - The leaning

    @Test func leaningMatchesTheReportsSplit() {
        #expect(FocusReport.leaning("work") == 1)
        #expect(FocusReport.leaning("learning") == 1)
        #expect(FocusReport.leaning("private") == 0)
        #expect(FocusReport.leaning("unclassified") == 0)
        #expect(FocusReport.leaning("no such category") == 0)
        #expect(FocusReport.leaning("entertainment") == -1)
    }

    // MARK: - The index

    @Test func onTaskMinutesClimbOnePointEach() {
        let candles = FocusCandles.series(
            from: Self.start, to: Self.start + 4 * Self.minute,
            activities: [Self.block("work", from: Self.start, to: Self.start + 4 * Self.minute)],
            candles: 10)
        #expect(candles.count == 4)
        #expect(candles.allSatisfy { $0.direction == .up })
        #expect(candles.last?.close == 4)
    }

    @Test func offTaskMinutesFallAndUntrackedOnesHold() {
        // Two minutes off-task, then two untracked.
        let candles = FocusCandles.series(
            from: Self.start, to: Self.start + 4 * Self.minute,
            activities: [Self.block(
                "entertainment", from: Self.start, to: Self.start + 2 * Self.minute)],
            candles: 10)
        #expect(candles.count == 4)
        #expect(candles[0].direction == .down)
        #expect(candles[1].direction == .down)
        #expect(candles[2].direction == .flat)
        #expect(candles[3].direction == .flat)
        #expect(candles.last?.close == -2)
    }

    @Test func neutralTimeDrawsDojisNotVerdicts() {
        let candles = FocusCandles.series(
            from: Self.start, to: Self.start + 2 * Self.minute,
            activities: [Self.block(
                "private", from: Self.start, to: Self.start + 2 * Self.minute)],
            candles: 10)
        #expect(candles.allSatisfy { $0.direction == .flat })
        #expect(candles.allSatisfy { $0.open == $0.close })
    }

    @Test func aHalfTrackedMinuteMovesHalfAPoint() {
        let candles = FocusCandles.series(
            from: Self.start, to: Self.start + Self.minute,
            activities: [Self.block(
                "work", from: Self.start, to: Self.start + Self.minute / 2)],
            candles: 10)
        #expect(candles.count == 1)
        #expect(candles[0].close == 0.5)
    }

    /// The trailing partial minute divides by its own length, not sixty
    /// seconds — a session thirty seconds into its last minute, all of it
    /// on-task, has earned the whole point of the time that exists.
    @Test func thePartialFinalMinuteScoresAgainstItsOwnLength() {
        let candles = FocusCandles.series(
            from: Self.start, to: Self.start + Self.minute / 2,
            activities: [Self.block(
                "work", from: Self.start, to: Self.start + Self.minute / 2)],
            candles: 10)
        #expect(candles.count == 1)
        #expect(candles[0].close == 1)
    }

    /// The raw path the Focus page draws as a line: one reading per minute
    /// boundary, opening at zero, and the same arithmetic the candles fold.
    @Test func thePathOpensAtZeroAndReadsEveryMinuteBoundary() {
        let readings = FocusCandles.path(
            from: Self.start, to: Self.start + 3 * Self.minute,
            activities: [
                Self.block("work", from: Self.start, to: Self.start + Self.minute),
                Self.block(
                    "entertainment", from: Self.start + Self.minute,
                    to: Self.start + 2 * Self.minute)
            ])
        #expect(readings == [0, 1, 0, 0])
        #expect(FocusCandles.path(from: Self.start, to: Self.start, activities: []).isEmpty)
    }

    // MARK: - The buckets

    @Test func aYoungSessionGetsOneCandlePerMinute() {
        let candles = FocusCandles.series(
            from: Self.start, to: Self.start + 3 * Self.minute,
            activities: [], candles: 24)
        #expect(candles.count == 3)
    }

    @Test func anOldSessionFoldsIntoTheAskedForCount() {
        let candles = FocusCandles.series(
            from: Self.start, to: Self.start + 100 * Self.minute,
            activities: [], candles: 24)
        #expect(candles.count == 24)
    }

    /// A bucket's high and low reach the extremes of the path *inside* it,
    /// not just its endpoints: a minute up then a minute down closes flat,
    /// but the wick remembers the climb.
    @Test func wicksKeepTheSwingTheCloseForgets() {
        let candles = FocusCandles.series(
            from: Self.start, to: Self.start + 2 * Self.minute,
            activities: [
                Self.block("work", from: Self.start, to: Self.start + Self.minute),
                Self.block(
                    "entertainment", from: Self.start + Self.minute,
                    to: Self.start + 2 * Self.minute)
            ],
            candles: 1)
        #expect(candles.count == 1)
        #expect(candles[0].open == 0)
        #expect(candles[0].close == 0)
        #expect(candles[0].high == 1)
        #expect(candles[0].low == 0)
        #expect(candles[0].direction == .flat)
    }

    @Test func candlesChainOpenToClose() {
        let candles = FocusCandles.series(
            from: Self.start, to: Self.start + 10 * Self.minute,
            activities: [Self.block(
                "work", from: Self.start, to: Self.start + 10 * Self.minute)],
            candles: 5)
        #expect(candles.count == 5)
        for pair in zip(candles, candles.dropFirst()) {
            #expect(pair.0.close == pair.1.open)
        }
    }

    @Test func anEmptyOrBackwardsWindowDrawsNothing() {
        #expect(FocusCandles.series(
            from: Self.start, to: Self.start, activities: [], candles: 10).isEmpty)
        #expect(FocusCandles.series(
            from: Self.start, to: Self.start - Self.minute, activities: [],
            candles: 10).isEmpty)
    }
}
