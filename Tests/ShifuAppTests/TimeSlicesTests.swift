import Foundation
import ShifuCore
import Testing
@testable import ShifuApp

/// How the Time page groups, ranks and colors a window (design.md §7).
/// Everything here is arithmetic over `LabeledActivity`, which is why it lives
/// in a test rather than in a screenshot.
@Suite struct TimeBreakdownTests {
    /// 2026-03-02 09:00 local, a Monday well clear of any DST boundary.
    static let day = Calendar.current.date(
        from: DateComponents(year: 2026, month: 3, day: 2, hour: 0))!

    static func at(_ hour: Int, _ minute: Int = 0) -> Date {
        day.addingTimeInterval(TimeInterval(hour * 3_600 + minute * 60))
    }

    static func block(
        _ category: String, from: Date, to: Date, source: String = "com.example.app",
        theme: String? = nil, task: String? = nil
    ) -> LedgerBuilder.LabeledActivity {
        LedgerBuilder.LabeledActivity(
            id: Int64.random(in: 1...1_000_000),
            startedAt: Int64(from.timeIntervalSince1970 * 1_000),
            endedAt: Int64(to.timeIntervalSince1970 * 1_000),
            category: category, source: source, taskName: task, themeName: theme)
    }

    @Test func slicesRankGroupsBiggestFirstAndShareSumsToOne() {
        let slices = TimeBreakdown.slices(
            [Self.block("work", from: Self.at(9), to: Self.at(11)),
             Self.block("learning", from: Self.at(11), to: Self.at(12))],
            lens: .category, from: Self.at(0), to: Self.at(24), limit: nil)

        #expect(slices.map(\.name) == ["work", "learning"])
        #expect(slices[0].ms == 2 * 3_600_000)
        #expect(abs(slices.reduce(0) { $0 + $1.share } - 1) < 0.0001)
    }

    @Test func blocksAreClippedToTheWindowBeforeTheyAreCounted() {
        // A session that started yesterday evening and runs into the morning.
        let slices = TimeBreakdown.slices(
            [Self.block("work", from: Self.at(-2), to: Self.at(1))],
            lens: .category, from: Self.at(0), to: Self.at(24), limit: nil)

        // Only the hour inside the window counts, not the three it spans.
        #expect(slices.count == 1)
        #expect(slices[0].ms == 3_600_000)
    }

    @Test func aBlockEntirelyOutsideTheWindowIsDropped() {
        let slices = TimeBreakdown.slices(
            [Self.block("work", from: Self.at(-5), to: Self.at(-4))],
            lens: .category, from: Self.at(0), to: Self.at(24), limit: nil)
        #expect(slices.isEmpty)
    }

    @Test func limitFoldsTheTailIntoOtherAndOtherSortsLast() {
        let blocks = (0..<6).map { index in
            Self.block("work", from: Self.at(index), to: Self.at(index, 6 * (6 - index)),
                       theme: "theme-\(index)")
        }
        let slices = TimeBreakdown.slices(
            blocks, lens: .theme, from: Self.at(0), to: Self.at(24), limit: 3)

        #expect(slices.count == 4)
        #expect(slices.last?.name == TimeBreakdown.otherLabel)
        // "Other" is a leftover bucket, not a group: it sorts last however big.
        let ranked = slices.dropLast()
        #expect(ranked.map(\.ms) == ranked.map(\.ms).sorted(by: >))
    }

    @Test func totalMatchesTheSumOfEverySliceItProduced() {
        let blocks = [
            Self.block("work", from: Self.at(9), to: Self.at(10)),
            Self.block("social", from: Self.at(10), to: Self.at(10, 30)),
            Self.block("work", from: Self.at(23), to: Self.at(25))    // runs past midnight
        ]
        let slices = TimeBreakdown.slices(
            blocks, lens: .category, from: Self.at(0), to: Self.at(24), limit: nil)
        let total = TimeBreakdown.total(blocks, from: Self.at(0), to: Self.at(24))

        #expect(total == slices.reduce(0) { $0 + $1.ms })
    }

    @Test func sourcesAreRankedAndCapped() {
        let blocks = (0..<5).map { index in
            Self.block("work", from: Self.at(index), to: Self.at(index, 10 * (5 - index)),
                       source: "app-\(index)")
        }
        let slices = TimeBreakdown.slices(
            blocks, lens: .category, from: Self.at(0), to: Self.at(24), limit: nil)

        #expect(slices[0].sources.count == TimeBreakdown.maxSources)
        #expect(slices[0].sources.map(\.name) == ["app-0", "app-1", "app-2"])
    }

    @Test func peakHourIsTheHourTheGroupSpentMostIn() {
        let slices = TimeBreakdown.slices(
            [Self.block("work", from: Self.at(9), to: Self.at(9, 15)),
             Self.block("work", from: Self.at(14), to: Self.at(16))],
            lens: .category, from: Self.at(0), to: Self.at(24), limit: nil)
        #expect(slices[0].peakHour == 14)
    }

    @Test func anEmptyWindowProducesNoSlicesAndNoDivisionByZero() {
        let slices = TimeBreakdown.slices(
            [], lens: .category, from: Self.at(0), to: Self.at(24), limit: nil)
        #expect(slices.isEmpty)
        #expect(TimeBreakdown.total([], from: Self.at(0), to: Self.at(24)) == 0)
    }

    @Test func unlabeledBlocksFallIntoAStableNamedBucket() {
        let slices = TimeBreakdown.slices(
            [Self.block("work", from: Self.at(9), to: Self.at(10), theme: nil)],
            lens: .theme, from: Self.at(0), to: Self.at(24), limit: nil)
        #expect(slices.map(\.name) == ["No theme"])
    }

    @Test func durationReadsAsHoursAndMinutes() {
        #expect(TimeBreakdown.duration(3_540_000) == "59m")
        #expect(TimeBreakdown.duration(3_600_000) == "1h 0m")
        #expect(TimeBreakdown.duration(15_120_000) == "4h 12m")
    }

    /// A real block list is full of forty-second visits, and rounding them all
    /// to "0m" turns the Timeline's whole duration column into zeroes.
    @Test func subMinuteSpansReadInSeconds() {
        #expect(TimeBreakdown.duration(0) == "0s")
        #expect(TimeBreakdown.duration(45_000) == "45s")
        #expect(TimeBreakdown.duration(59_000) == "59s")
        #expect(TimeBreakdown.duration(60_000) == "1m")
        // A negative span is a clock going backwards, not four billion hours.
        #expect(TimeBreakdown.duration(-5_000) == "0s")
    }
}

@Suite struct TimeLensTests {
    @Test func categoriesAreCapitalizedAndUserTextIsNot() {
        #expect(TimeLens.category.display("work") == "Work")
        #expect(TimeLens.theme.display("yc startup school") == "yc startup school")
    }

    @Test func countedPluralizesEachLensCorrectly() {
        #expect(TimeLens.category.counted(1) == "1 category")
        #expect(TimeLens.category.counted(8) == "8 categories")
        #expect(TimeLens.theme.counted(1) == "1 theme")
        #expect(TimeLens.theme.counted(3) == "3 themes")
        #expect(TimeLens.task.counted(2) == "2 tasks")
    }
}

@Suite struct TimePaletteTests {
    @Test func categoryColorsAreFixedAndUnknownCategoriesStayRecessive() {
        let known = TimePalette.colors(for: ["work", "learning"], lens: .category)
        // Same call twice, same answer — the category lens has no hashing in it.
        #expect(known == TimePalette.colors(for: ["work", "learning"], lens: .category))

        let grown = TimePalette.colors(for: ["a-category-the-ledger-grew"], lens: .category)
        #expect(grown.values.first == TimePalette.otherColor)
    }

    /// Color follows the group, not its rank — otherwise flipping Day↔Week
    /// repaints every theme that changed places.
    @Test func themeColorSurvivesReorderingAndDroppedNeighbors() {
        let ranked = TimePalette.colors(for: ["alpha", "beta", "gamma"], lens: .theme)
        let reordered = TimePalette.colors(for: ["gamma", "alpha", "beta"], lens: .theme)
        #expect(ranked["alpha"] == reordered["alpha"])
        #expect(ranked["gamma"] == reordered["gamma"])
    }

    @Test func twoGroupsOnScreenTogetherNeverShareAHue() {
        let names = (0..<TimePalette.groupHues.count).map { "theme-\($0)" }
        let colors = TimePalette.colors(for: names, lens: .theme)
        #expect(Set(names.compactMap { colors[$0] }).count == names.count)
    }

    @Test func theOtherBucketAlwaysGetsTheLeftoverColor() {
        let colors = TimePalette.colors(
            for: ["alpha", TimeBreakdown.otherLabel], lens: .theme)
        #expect(colors[TimeBreakdown.otherLabel] == TimePalette.otherColor)
    }
}
