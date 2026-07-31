import AppKit
import SwiftUI

/// The Instrument design system (design.md §7): Shifu as a measuring
/// instrument rather than a place. A near-white ground, a permanent source
/// list, hairline rules instead of cards, tabular mono for every figure, and
/// exactly one accent — a slate blue, stepped three ways when a chart has to
/// separate groups.
///
/// Nothing here is decorative. A color either separates two series, marks the
/// one selected thing, or says a number needs acting on.
enum Instrument {
    // MARK: - Surfaces

    /// The detail pane's ground — the sheet the numbers are printed on.
    static let ground = Color(light: 0xFBFBFA, dark: 0x1F1F1E)
    /// The source list and title bar: one shade back from the ground, so the
    /// split reads without a heavy divider.
    static let rail = Color(light: 0xF0EFEC, dark: 0x161615)

    /// Between regions — sidebar/detail, title bar/body.
    static let edge = Color(
        light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.09, darkAlpha: 0.08)
    /// Under a section header or above a footer.
    static let rule = Color(
        light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.08, darkAlpha: 0.07)
    /// Between rows of a table. Lighter again: a dense table's rules should
    /// separate without drawing a grid.
    static let hairline = Color(
        light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.055, darkAlpha: 0.05)
    /// The unfilled part of a meter, and any recessed track.
    static let well = Color(
        light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.07, darkAlpha: 0.07)

    // MARK: - Ink

    /// Titles, figures, the row you are reading.
    static let ink = Color(light: 0x1C1C1A, dark: 0xECECEA)
    /// Body prose — the story, the narrative lines.
    static let body = Color(light: 0x35342F, dark: 0xC9C8C1)
    /// Descriptions under a title.
    static let secondary = Color(light: 0x56554F, dark: 0xB3B2AB)
    /// Unselected source-list rows.
    static let railInk = Color(light: 0x45443F, dark: 0xC9C8C1)
    /// Sub-headings, secondary figures, "4 tasks".
    static let muted = Color(light: 0x6F6E67, dark: 0x97968F)
    /// Counts on unselected rows, timestamps.
    static let faint = Color(light: 0x8D8C84, dark: 0x85847D)
    /// Eyebrows, axis ticks, dashes standing in for no data.
    static let ghost = Color(light: 0x9A998F, dark: 0x75746E)

    // MARK: - The accent (exactly one)

    /// Fills: the selected bar, the meter, the progress line.
    static let accent = Color(light: 0x3A5F8A, dark: 0xA8C6E6)
    /// The same accent as *text* — links, counts on the selected row.
    static let accentText = Color(light: 0x46648B, dark: 0xA8C6E6)
    /// A pressed or emphasised accent label.
    static let accentDeep = Color(light: 0x2F4F75, dark: 0xD3E3F4)
    /// The selected source-list row's fill.
    static let selection = Color(
        light: 0x3A5F8A, dark: 0x8CB4E1, lightAlpha: 0.13, darkAlpha: 0.16)
    /// The focused row of a table — a wash, not a highlight.
    static let rowTint = Color(
        light: 0x3A5F8A, dark: 0x8CB4E1, lightAlpha: 0.05, darkAlpha: 0.07)

    /// The inverse button — "New theme", "Keep", "Copy brief". Ink-filled in
    /// light, paper-filled in dark; the one control loud enough to be the
    /// answer to the screen it sits on.
    static let solidFill = Color(light: 0x1C1C1A, dark: 0xECECEA)
    static let solidInk = Color(light: 0xFFFFFF, dark: 0x1F1F1E)

    // MARK: - Status

    /// The capture indicator: watching.
    static let live = Color(light: 0x3F7D4F, dark: 0x6AA87C)
    /// A count that wants attention — cards due, a theme gone quiet.
    static let alert = Color(light: 0xA8551F, dark: 0xE0A06A)
    /// Past due. One step hotter than `alert`, and always beside a word.
    static let overdue = Color(light: 0x9C3D1E, dark: 0xE07A5F)
    /// The rhythm mark: `alert` lifted a step, and its own token rather than a
    /// lighter `alert` because the two are read against different bars. A mark
    /// is a shape on a band and clears at 3:1 (this is 4.1); `alert` is also a
    /// count and a caption, and lifting it this far would put every figure
    /// drawn in it under AA's 4.5. The lift buys separation too — from
    /// `overdue`, the palette's closest pair (ΔE 12 → 17), and in dark from
    /// the warm chart slot the mark has to sit on without joining it (6 → 9).
    static let beacon = Color(light: 0xB8632A, dark: 0xE8AC78)

    // MARK: - Data hues

    /// The five slots a chart may use, in assignment order: the accent stepped
    /// three ways, then a neutral, then the one warm hue. Deliberately short
    /// and deliberately reused — this is a one-accent instrument, so a sixth
    /// group takes slot one again rather than minting a colour.
    ///
    /// Hue is never the only cue: every series here is named in the table row
    /// or the legend beside it.
    static let slots: [Color] = [
        Color(light: 0x3A5F8A, dark: 0x3D6DA5),   // strong
        Color(light: 0x7F9EC0, dark: 0x6F9DD0),   // mid
        Color(light: 0xB9CADB, dark: 0xA8C6E6),   // soft
        Color(light: 0x9C9A92, dark: 0x5E5D58),   // neutral
        Color(light: 0xC98A3F, dark: 0xD09A5C)    // warm
    ]

    static let strong = slots[0]
    static let mid = slots[1]
    static let soft = slots[2]
    static let neutral = slots[3]
    static let warm = slots[4]
    /// A fourth step below `strong`, held back for the fixed category scale —
    /// the ledger has eight categories and the ramp only has to separate them
    /// beside their own labels, never on its own.
    static let deep = Color(light: 0x27405F, dark: 0x2E5C8C)

    /// A series that has stopped — a quiet theme's sparkline, an untracked
    /// stretch of the ribbon. The most recessive tone here, and near enough to
    /// a receded band (`StackedBars.fill`) that nothing which has to stay
    /// *findable* may wear it: it is for marks that mean "nothing here", and
    /// for `private`, which is hatched and so reads by texture either way.
    static let quiet = Color(light: 0xD6D4CD, dark: 0x3A3A37)
    /// The leftover bucket, and time with no group at all.
    ///
    /// Its own grey rather than `neutral`'s. These two were the same hex, and
    /// since `neutral` is a slot the group scale hands out, a chart could draw
    /// a real group and the "Other" pile in one colour — which it did: the
    /// week's fourth task and its leftovers came out as two identical swatches
    /// in the legend. Measured with the `dataviz` validator, this clears every
    /// slot and the receded tone by ΔE ≥ 13.8 in both modes; `neutral` cleared
    /// it by 0.
    static let other = Color(light: 0xC6C4BB, dark: 0x97958C)

    // MARK: - Metrics

    /// The source list. Fixed, not resizable: the design's whole claim is that
    /// you always know where you are, and a list you can drag to 40pt isn't
    /// that.
    static let railWidth: CGFloat = 226
    /// The fake title bar's height — matches AppKit's own so the real traffic
    /// lights land centred in it.
    static let titleBarHeight: CGFloat = 40
    /// Detail-pane horizontal padding. Every table, header, and rule shares it.
    static let gutter: CGFloat = 22

    // MARK: - Type

    /// The instrument's two faces: IBM Plex Sans for words, IBM Plex Mono for
    /// every figure. Both fall back to the system faces when Plex isn't
    /// installed — SF Pro and SF Mono share Plex's metrics closely enough that
    /// the layout doesn't move, and shipping 1.5 MB of TTFs to avoid a
    /// near-identical fallback isn't a trade this app should make.
    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        guard let family = sansFamily else { return .system(size: size, weight: weight) }
        return .custom(family, fixedSize: size).weight(weight)
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        guard let family = monoFamily else {
            return .system(size: size, weight: weight, design: .monospaced)
        }
        return .custom(family, fixedSize: size).weight(weight)
    }

    /// The terminal register: mono, uppercase, tracked out. Section eyebrows,
    /// column heads, axis ticks — never a sentence.
    static func eyebrow(_ size: CGFloat = 10) -> Font { mono(size, .regular) }

    /// The face `sans` resolves to, as an `NSFont` — for the one thing that
    /// has to measure a string before SwiftUI lays it out: a drop-down sizes
    /// its own window (`DropdownMetrics`).
    static func sansFont(_ size: CGFloat) -> NSFont {
        guard let family = sansFamily, let font = NSFont(name: family, size: size) else {
            return .systemFont(ofSize: size)
        }
        return font
    }

    /// And `mono`, for the other: `RibbonAxis` places its labels itself, so it
    /// has to know how wide one is before SwiftUI draws it.
    static func monoFont(_ size: CGFloat) -> NSFont {
        guard let family = monoFamily, let font = NSFont(name: family, size: size) else {
            return .monospacedSystemFont(ofSize: size, weight: .regular)
        }
        return font
    }

    private static let sansFamily = installedFamily(
        ["IBM Plex Sans", "IBMPlexSans", "IBMPlexSans-Regular"])
    private static let monoFamily = installedFamily(
        ["IBM Plex Mono", "IBMPlexMono", "IBMPlexMono-Regular"])

    /// The first of `names` AppKit can actually resolve, or nil for none.
    /// Resolved once per process — `NSFont(name:)` walks the font tables.
    private static func installedFamily(_ names: [String]) -> String? {
        names.first { NSFont(name: $0, size: 12) != nil }
    }
}

extension Color {
    /// Appearance-adaptive color from two hex values, resolved per render —
    /// the same mechanism AppKit semantic colors use.
    init(
        light: UInt32, dark: UInt32,
        lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1
    ) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light, alpha: isDark ? darkAlpha : lightAlpha)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
    }
}
