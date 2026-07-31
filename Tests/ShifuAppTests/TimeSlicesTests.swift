import AppKit
import Foundation
import ShifuCore
import SwiftUI
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

    /// The claim above is only worth anything up to the number of groups a
    /// lens actually ranks. The palette was five hues against a limit of six,
    /// so a real week always drew two tasks in one colour while this suite —
    /// which only ever asked for `groupHues.count` names — stayed green.
    @Test func thePaletteHasAHueForEveryGroupALensWillRank() {
        #expect(TimePalette.groupHues.count >= TimeBreakdown.maxGroups)

        let names = (0..<TimeBreakdown.maxGroups).map { "task-\($0)" }
        let colors = TimePalette.colors(
            for: names + [TimeBreakdown.otherLabel], lens: .task)
        #expect(Set(names.compactMap { colors[$0] }).count == names.count)
    }

    @Test func theOtherBucketAlwaysGetsTheLeftoverColor() {
        let colors = TimePalette.colors(
            for: ["alpha", TimeBreakdown.otherLabel], lens: .theme)
        #expect(colors[TimeBreakdown.otherLabel] == TimePalette.otherColor)
    }
}

/// What the palette looks like *as drawn*, which is not what comparing `Color`
/// values says.
///
/// `twoGroupsOnScreenTogetherNeverShareAHue` above passes on `Set<Color>`, and
/// it passed all the way through a release where the leftover bucket and the
/// fourth group slot were both `0x9C9A92`: they were two separately built
/// `Color`s, so they hashed apart while rendering to the same pixel, and the
/// legend drew two identical swatches. Every check here resolves through
/// AppKit first, in both appearances, because that is the only comparison the
/// eye is doing.
@Suite struct PaletteSeparationTests {
    /// The floor, on the 0…255 channel scale `gap` measures in. Calibrated
    /// against the palette rather than picked: the two collisions this suite
    /// was written for measure 0 and 18, and the tightest pair that is
    /// genuinely fine measures 33. Anything in between is the grey zone this
    /// number sits in deliberately — it is a collision alarm, not a
    /// perceptual model. Real ΔE was settled once with the `dataviz`
    /// validator (≥ 13.8 in both modes).
    static let floor = 24

    /// Everything a single chart can put on screen at once. `quiet` is absent
    /// on purpose — it is `private`'s fill, which is hatched over the top, so
    /// it carries texture rather than hue (see `Instrument.quiet`).
    @MainActor static var coexisting: [(String, Color)] {
        TimePalette.groupHues.enumerated().map { ("slot \($0.offset)", $0.element) }
            + [("other", TimePalette.otherColor)]
    }

    /// The categories, which are their own closed scale rather than the hashed
    /// one — and the scale that reaches furthest into the greys.
    @MainActor static var categories: [(String, Color)] {
        ["work", "communication", "learning", "social",
         "entertainment", "admin", "unclassified"]
            .map { ($0, TimePalette.colors(for: [$0], lens: .category)[$0]!) }
    }

    @MainActor @Test func noTwoSeriesOnOneChartRenderToTheSamePixel() {
        for dark in [false, true] {
            let mode = dark ? "dark" : "light"
            for set in [Self.coexisting, Self.categories] {
                for (left, right) in Self.pairs(of: set) {
                    let apart = Int(Self.gap(left.1, right.1, dark: dark))
                    #expect(apart >= Self.floor, "\(left.0) ↔ \(right.0) in \(mode): \(apart) apart")
                }
            }
        }
    }

    /// The floor a lit band has to clear to be *found*: the tone its receded
    /// neighbours take while the legend holds one group up
    /// (`StackedBars.fill`). `unclassified` used to wear `quiet` and missed
    /// this by 3 in dark — every band in the column rendered #3D3D3C, so the
    /// one group the pointer was on looked exactly like the six it wasn't.
    @MainActor @Test func everySeriesStandsOutFromARecededBand() {
        for dark in [false, true] {
            let mode = dark ? "dark" : "light"
            for (name, color) in Self.coexisting + Self.categories {
                let apart = Int(Self.gap(color, Self.receded(dark: dark), dark: dark))
                #expect(apart >= Self.floor, "\(name) lit is \(apart) from a receded band in \(mode)")
            }
        }
    }

    /// What a receded band actually paints: `Instrument.well` is translucent,
    /// so it is the composite over the ground that the eye compares against.
    @MainActor static func receded(dark: Bool) -> Color {
        let well = resolve(Instrument.well, dark: dark)
        let ground = resolve(Instrument.ground, dark: dark)
        let over = { (top: CGFloat, bottom: CGFloat) in
            bottom * (1 - well.alphaComponent) + top * well.alphaComponent
        }
        return Color(nsColor: NSColor(
            srgbRed: over(well.redComponent, ground.redComponent),
            green: over(well.greenComponent, ground.greenComponent),
            blue: over(well.blueComponent, ground.blueComponent),
            alpha: 1))
    }

    /// Distance between two colours as drawn, on a 0…255 channel scale.
    /// Deliberately plain sRGB rather than a ΔE implementation nobody here can
    /// check: the real perceptual work was done once with the `dataviz`
    /// validator (this palette clears ΔE 13.8 in both modes), and what this
    /// guards is that nobody re-introduces a *collision* — the failures it
    /// exists to catch measured 0 and 3.
    @MainActor static func gap(_ lhs: Color, _ rhs: Color, dark: Bool) -> Double {
        let left = resolve(lhs, dark: dark), right = resolve(rhs, dark: dark)
        let channels = [
            (left.redComponent, right.redComponent),
            (left.greenComponent, right.greenComponent),
            (left.blueComponent, right.blueComponent)
        ]
        return (channels.reduce(0.0) { $0 + pow(Double($1.0 - $1.1) * 255, 2) }).squareRoot()
    }

    @MainActor static func resolve(_ color: Color, dark: Bool) -> NSColor {
        var resolved = NSColor.black
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            resolved = NSColor(color).usingColorSpace(.sRGB) ?? .black
        }
        return resolved
    }

    static func pairs(of set: [(String, Color)]) -> [((String, Color), (String, Color))] {
        set.indices.flatMap { first in
            set.indices.dropFirst(first + 1).map { (set[first], set[$0]) }
        }
    }
}
