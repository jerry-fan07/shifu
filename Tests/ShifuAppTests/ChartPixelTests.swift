import AppKit
import Foundation
import ShifuCore
import SwiftUI
import Testing
@testable import ShifuApp

/// The chart, checked on the pixels it actually paints.
///
/// `PaletteSeparationTests` next door checks the *tokens*, and that is a
/// weaker claim than it looks. A colour travels from `Instrument` through a
/// slice, a segment, a SwiftUI fill, a layer tree and a colour-space
/// conversion before it reaches an eye, and every bug this suite exists for
/// lived somewhere along that path rather than in the constant:
///
/// - a group hashed into the grey the "Other" pile wears, so the biggest thing
///   on a real week was painted as filler;
/// - a series whose fill sat a hair from the tone its neighbours take while
///   the legend holds another group up, so hovering it lit nothing — every
///   band in the column, lit and receded, rendered #3D3D3C;
/// - a pale green that cleared "not grey" by the numbers and still read as
///   off-white once drawn on the dark ground.
///
/// So these render the real `StackedBars` offscreen — the same
/// `NSHostingView` + `cacheDisplay` route `WindowShots` uses, because
/// `screencapture` is black without a Screen Recording grant and
/// `ImageRenderer` is deferred — and read the bands back out of the bitmap.
///
/// Interaction is *not* covered, and can't be: `onHover` fires from wherever
/// the real mouse is, which offscreen is nowhere. The highlight is exercised
/// by passing `StackedBars.highlight` directly, which is the state a legend
/// row — or a band under the pointer — sets. What *is* covered is the shape a
/// band offers that pointer, because widening it is a change to the layout the
/// bands are drawn in: `theHitAreaDoesNotMoveTheMark`.
@Suite struct ChartPixelTests {
    // MARK: - The claims

    /// Every group on one chart paints a different colour. Not "holds a
    /// different `Color`" — `twoGroupsOnScreenTogetherNeverShareAHue` claimed
    /// that all the way through a release where two separately built `Color`s
    /// rendered to one pixel.
    @MainActor @Test func everyGroupOnOneChartPaintsADifferentColour() throws {
        for dark in [false, true] {
            let mode = dark ? "dark" : "light"
            for (lens, groups) in Self.scales {
                let bands = try Self.bands(groups, lens: lens, dark: dark)
                let drawn = Self.hexes(bands)
                let scale = "\(mode) \(lens.rawValue)"
                #expect(
                    bands.count == groups.count,
                    "\(scale): \(groups.count) groups drew \(bands.count) bands — \(drawn)")
            }
        }
    }

    /// Grey is for the things that are not groups. Under the hashed scale,
    /// asked for every group a lens will rank and with nothing folded away,
    /// no band may be one.
    @MainActor @Test func noGroupIsEverPaintedGrey() throws {
        for dark in [false, true] {
            let mode = dark ? "dark" : "light"
            for band in try Self.bands(Self.themes(TimeBreakdown.maxGroups), dark: dark) {
                let chroma = Int(Self.chroma(band))
                let drawn = Self.hex(band)
                #expect(chroma >= Self.hued, "\(mode) painted a group #\(drawn), chroma \(chroma)")
            }
        }
    }

    /// And the converse, which is the rule stated whole. Overflow the hashed
    /// scale by one so the leftover bucket appears and exactly one band comes
    /// out grey; on the fixed scale the greys are `admin` and `unclassified`,
    /// and there are exactly two.
    @MainActor @Test func onlyTheThingsThatAreNotGroupsArePaintedGrey() throws {
        for dark in [false, true] {
            let mode = dark ? "dark" : "light"
            let overflowed = Self.themes(TimeBreakdown.maxGroups + 1)
            for (lens, groups, expected) in [
                (TimeLens.theme, overflowed, 1),         // "Other"
                (TimeLens.category, Self.categories, 2)  // admin, unclassified
            ] {
                let bands = try Self.bands(groups, lens: lens, dark: dark)
                let greys = bands.filter { Self.chroma($0) < Double(Self.hued) }
                let drawn = Self.hexes(greys)
                let scale = "\(mode) \(lens.rawValue)"
                #expect(
                    greys.count == expected,
                    "\(scale) painted \(greys.count) greys (\(drawn)), expected \(expected)")
            }
        }
    }

    /// Hovering a legend row has to *show* something. With one group held up,
    /// the column paints exactly two colours — the lit group and the tone the
    /// rest recede to — and they have to be far enough apart to find.
    ///
    /// This is the check that would have caught `unclassified`: it wore a grey
    /// a hair from the receded tone, so the column went uniform and the one
    /// group the pointer was on looked exactly like the six it wasn't.
    @MainActor @Test func aHighlightedGroupSeparatesFromTheBandsThatRecede() throws {
        for dark in [false, true] {
            let mode = dark ? "dark" : "light"
            for (lens, groups) in Self.scales {
                for name in Self.slices(groups, lens: lens).map(\.name) {
                    let bands = try Self.bands(
                        groups, lens: lens, highlight: name, dark: dark)
                    let drawn = Self.hexes(bands)
                    try #require(
                        bands.count == 2,
                        "\(mode) lit \(name): expected lit + one receded tone, drew \(drawn)")
                    let apart = Int(Self.gap(bands[0], bands[1]))
                    #expect(apart >= Self.floor, "\(mode) lit \(name): \(apart) apart")
                }
            }
        }
    }

    /// A band's hit area is not the band. `StackedBars` widens each band into
    /// half the ground on either side of it, so a pointer running down a
    /// column can't fall through a 2pt hole and drop the highlight — and it
    /// does that by padding the band and then taking the padding back. If the
    /// take-back ever stops being exact, nothing throws and nothing looks
    /// wrong at a glance: the bands just quietly grow, and every column stops
    /// standing at its own total. That is a chart that lies, so it is measured
    /// rather than trusted.
    ///
    /// Seven hourly blocks in one slot: a 7h column, ruled in 2h steps (the
    /// smallest step of `StackedBars.steps` that rules 7h in four marks or
    /// fewer), so the scale tops out at 8h and the column stands at 7/8 of the
    /// 107pt plot — 93.6pt. A leak would put each of the seven bands 2pt taller
    /// and stand the column 14pt past that, which is most of a grid step.
    @MainActor @Test func theHitAreaDoesNotMoveTheMark() throws {
        let bitmap = try #require(
            Self.render(StackedBars(stacks: Self.oneColumn(Self.categories)), dark: false))
        let painted = Set(Self.scan(bitmap).map(Self.hex))
        try #require(
            painted.count == Self.categories.count,
            "expected \(Self.categories.count) bands, scanned \(painted.count)")

        // The same several x `scan` reads, unioned for the same reason: one
        // column of a 200pt chart is 34pt of it, and where exactly it lands
        // is arithmetic this test has no business repeating.
        let rows = (0..<bitmap.pixelsHigh).filter { row in
            Self.probes(bitmap).contains { column in
                painted.contains(Self.hex(bitmap.colorAt(x: column, y: row) ?? .black))
            }
        }
        let top = try #require(rows.first)
        let bottom = try #require(rows.last)
        let scale = Double(bitmap.pixelsHigh) / Double(Self.size.height)
        let drawn = Double(bottom - top + 1) / scale
        #expect(
            abs(drawn - 93.6) <= 2,
            "a 7-of-8-hours column stood \(drawn)pt tall in a 107pt plot, not 93.6pt")
    }

    /// Both scales a chart can draw with: the hashed one theme groups take
    /// hues from, and the fixed one the categories wear.
    @MainActor static var scales: [(TimeLens, [String])] {
        [(.theme, themes(TimeBreakdown.maxGroups)), (.category, categories)]
    }

    // MARK: - Thresholds

    /// Channel spread below which a colour reads as grey. The palette splits
    /// cleanly on it — its greys sit at 6–11 and its faintest real hue at 34 —
    /// so the line is not a fine judgement. See `PaletteSeparationTests.hued`.
    static let hued = 20
    /// How far apart two colours must draw to be told apart, on the same 0…255
    /// channel scale. See `PaletteSeparationTests.floor`.
    static let floor = 24

    // MARK: - The chart under test

    /// The hashed scale, asked for as many groups as the lens will rank.
    static func themes(_ count: Int) -> [String] { (0..<count).map { "theme-\($0)" } }

    /// The fixed scale. `private` is left out: it draws hatched, so a scan
    /// down it reads the stripes rather than a band, and texture — not hue —
    /// is what tells it apart. Everything else here is a flat fill and has to
    /// stand on its colour.
    static let categories = [
        "work", "communication", "learning", "social",
        "entertainment", "admin", "unclassified"
    ]

    /// Synthetic, not the dogfood ledger: this runs in `make check`, where
    /// there is no ~/Shifu. One block per group, an hour each, all inside a
    /// single slot — so one column carries every hue the scale can hand out
    /// and one scan down it sees the whole palette drawn at once.
    static func blocks(_ groups: [String], lens: TimeLens) -> [LedgerBuilder.LabeledActivity] {
        groups.enumerated().map { index, name in
            let from = Self.origin + Int64(index) * Self.hour
            return LedgerBuilder.LabeledActivity(
                id: Int64(index + 1), startedAt: from, endedAt: from + Self.hour,
                category: lens == .category ? name : "work", source: "app",
                themeName: lens == .category ? nil : name)
        }
    }

    private static let hour: Int64 = 3_600_000
    /// 2027-01-01 00:00 UTC — any fixed instant; the slot is built from it, so
    /// nothing here reads a clock.
    private static let origin: Int64 = 1_798_761_600_000

    static func window(_ groups: [String]) -> (from: Date, to: Date) {
        (Date(timeIntervalSince1970: Double(origin) / 1_000),
         Date(timeIntervalSince1970: Double(origin + Int64(groups.count) * hour) / 1_000))
    }

    /// The groups as the chart ranks them — which is not the order they were
    /// asked for, and includes "Other" once the limit bites.
    @MainActor static func slices(_ groups: [String], lens: TimeLens) -> [TimeSlice] {
        let span = window(groups)
        return TimeBreakdown.slices(
            blocks(groups, lens: lens), lens: lens, from: span.from, to: span.to,
            limit: lens == .category ? nil : TimeBreakdown.maxGroups)
    }

    /// Every group stacked into a single slot — one column carrying the whole
    /// scale, which is what a scan down it can read in one pass.
    @MainActor static func oneColumn(_ groups: [String], lens: TimeLens = .category) -> [BarStack] {
        let span = window(groups)
        let ranked = slices(groups, lens: lens)
        let colors = Dictionary(uniqueKeysWithValues: ranked.map { ($0.name, $0.color) })
        return LedgerShapes.bars(
            blocks(groups, lens: lens), lens: lens, colors: colors,
            order: ranked.map(\.name),
            slots: [LedgerShapes.Slot(tick: "", from: span.from, to: span.to)])
    }

    /// The distinct colours the chart paints down its one column, ground and
    /// the hairlines between bands dropped.
    @MainActor static func bands(
        _ groups: [String], lens: TimeLens = .theme, highlight: String? = nil, dark: Bool
    ) throws -> [NSColor] {
        let bitmap = try #require(
            render(
                StackedBars(stacks: oneColumn(groups, lens: lens), highlight: highlight),
                dark: dark))
        return scan(bitmap)
    }

    // MARK: - Drawing and reading back

    static let size = CGSize(width: 200, height: 150)

    @MainActor static func render(_ view: some View, dark: Bool) -> NSBitmapImageRep? {
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        // Both dimensions, so every pixel of the bitmap is painted — an
        // unpainted margin caches as black and reads back as a band.
        let host = NSHostingView(
            rootView: view
                .frame(width: size.width, height: size.height, alignment: .top)
                .background(Instrument.ground))
        host.frame = CGRect(origin: .zero, size: size)
        window.contentView = host
        window.orderBack(nil)
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            return nil
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        window.orderOut(nil)
        return bitmap
    }

    /// Runs of one colour down the column, long enough to be a band, read at
    /// each of `probes` and unioned.
    ///
    /// Two things get dropped: the ground — which is also what shows through
    /// the 2pt gaps the stack leaves between bands — and any run too short to
    /// be a band, which is how the grid's hairlines are excluded where they
    /// cross a *receded* band, whose fill is translucent enough to let one
    /// through.
    ///
    /// The ground is taken as whatever the scan sees most of, not as
    /// `Instrument.ground` resolved. The two are not the same colour: a token
    /// goes through a colour-space conversion on its way to the screen, and
    /// the dark ground that reads back here is #292928 against a token of
    /// #1F1F1E. Reading it off the bitmap is the same reason this suite exists
    /// at all — compare what was drawn, never what was asked for.
    static func scan(_ bitmap: NSBitmapImageRep) -> [NSColor] {
        let minimumRun = max(4, bitmap.pixelsHigh / 40)
        var tally: [String: Int] = [:]
        for column in probes(bitmap) {
            for row in 0..<bitmap.pixelsHigh {
                tally[hex(bitmap.colorAt(x: column, y: row) ?? .black), default: 0] += 1
            }
        }
        let ground = tally.max { $0.value < $1.value }?.key

        var found: [String: NSColor] = [:]
        for column in probes(bitmap) {
            var runStart = 0
            var previous = ""
            for row in 0...bitmap.pixelsHigh {
                let key = row < bitmap.pixelsHigh
                    ? hex(bitmap.colorAt(x: column, y: row) ?? .black) : ""
                guard key != previous else { continue }
                if row - runStart >= minimumRun, previous != ground, !previous.isEmpty,
                   let color = bitmap.colorAt(x: column, y: runStart) {
                    found[previous] = color
                }
                previous = key
                runStart = row
            }
        }
        return found.keys.sorted().compactMap { found[$0] }
    }

    /// The x to read the column at. Several, unioned: the column is centred in
    /// the plot, which starts after the axis gutter, so the middle fifths of
    /// the width are inside it wherever the gutter lands — and a single x
    /// isn't, as the exact centre of a 200pt chart proves by falling a point
    /// short of a 34pt column.
    static func probes(_ bitmap: NSBitmapImageRep) -> [Int] {
        Array(stride(from: bitmap.pixelsWide / 2, to: bitmap.pixelsWide * 7 / 10, by: 4))
    }

    // MARK: - Colour arithmetic (shared shape with PaletteSeparationTests)

    static func chroma(_ color: NSColor) -> Double {
        guard let srgb = color.usingColorSpace(.sRGB) else { return 0 }
        let channels = [srgb.redComponent, srgb.greenComponent, srgb.blueComponent]
        return Double((channels.max() ?? 0) - (channels.min() ?? 0)) * 255
    }

    static func gap(_ lhs: NSColor, _ rhs: NSColor) -> Double {
        guard let left = lhs.usingColorSpace(.sRGB), let right = rhs.usingColorSpace(.sRGB)
        else { return 0 }
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

    static func hex(_ color: NSColor) -> String {
        guard let srgb = color.usingColorSpace(.sRGB) else { return "??????" }
        return String(
            format: "%02X%02X%02X", Int(srgb.redComponent * 255),
            Int(srgb.greenComponent * 255), Int(srgb.blueComponent * 255))
    }

    static func hexes(_ colors: [NSColor]) -> String {
        colors.map { "#\(hex($0))" }.joined(separator: " ")
    }
}
