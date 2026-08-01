import AppKit
import SwiftUI

/// The Instrument design system (design.md §7): Shifu as a measuring
/// instrument rather than a place. A near-white ground, a permanent source
/// list, hairline rules instead of cards, tabular mono for every figure, and
/// exactly one accent — a slate blue, stepped three ways.
///
/// The accent is the *interface's*: every control, link, selection and meter
/// is that blue and nothing else. Only the chart scale (`slots`) reaches past
/// it, and only as far as separating one group from another demands.
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

    /// The only ground the app fills rather than rules: the theme page's title
    /// banner and the story panel under it, both printed white on rust.
    ///
    /// Its own token rather than `overdue`, which these two used to borrow.
    /// `overdue` is a *mark* colour, and its dark step is a salmon lifted to
    /// carry as a figure on a near-black ground — the opposite of what a
    /// filled panel needs. At banner scale that step is a glare, and white on
    /// it clears 3:1: enough for a 46 pt name, nowhere near it for the mono
    /// figures underneath. Deepening in dark instead keeps the panel a panel
    /// and puts every line on it past 7:1.
    static let banner = Color(light: 0x9C3D1E, dark: 0x7A2F15)

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
    /// The running Focus session's own row — a gold wash across the whole
    /// line, standing in for the `StatusDot` a wide table row is too easy to
    /// glance past.
    static let liveTint = Color(
        light: 0xC9A227, dark: 0xD9BB5E, lightAlpha: 0.16, darkAlpha: 0.2)
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

    /// A 0…1 reading on the verdict ramp: the accent at full marks, stepping
    /// down through its own range and out into a light red at the floor. For
    /// a figure that *is* a verdict — the focus score — where the colour says
    /// how the number reads, and the number is always printed beside it, so
    /// the ramp is never the only cue.
    ///
    /// Two things here are deliberate and easy to get wrong:
    ///
    /// - The ends are anchored *per appearance*, not per token. The accent's
    ///   salient step swaps sides in dark — light mode's strong blue is the
    ///   dark slate, dark mode's is the pale one — so a ramp built from the
    ///   slot names would make a *falling* score glow brighter in dark.
    /// - The stops carry their own positions rather than being spaced evenly.
    ///   Real focus scores crowd the top third of the scale, and an even ramp
    ///   parks an 81 and a 98 on the same step; the blue range is spread over
    ///   0.45…1 where the readings actually live, which leaves the red end to
    ///   the genuinely bad sessions. The meter's *length* still carries the
    ///   true value linearly — the colour is emphasis, so it may spend its
    ///   range unevenly.
    static func verdict(_ reading: Double) -> Color {
        // A tint of `overdue` rather than a new hue: the palette has no light
        // red because nothing else needs one — a mark that must be read at a
        // glance uses the full-strength token.
        let stops = [
            Stop(at: 0.00, light: 0xD08E79, dark: 0xE07A5F),   // light red — the floor
            // Held, so a poor score reads as red rather than as the crossfade
            // out of it: red and blue are a hue apart, and every mix on the
            // way between them is a mauve that says nothing.
            Stop(at: 0.22, light: 0xD08E79, dark: 0xE07A5F),
            Stop(at: 0.45, light: 0xB9CADB, dark: 0x2E5C8C),   // the accent's faded step
            Stop(at: 0.70, light: 0x7F9EC0, dark: 0x6F9DD0),   // its middle
            Stop(at: 1.00, light: 0x27405F, dark: 0xD3E3F4)    // the deepest — full marks
        ]
        let place = min(1, max(0, reading))
        let upper = stops.firstIndex { place <= $0.at } ?? stops.count - 1
        guard upper > 0 else { return Color(light: stops[0].light, dark: stops[0].dark) }
        let lower = stops[upper - 1]
        let fraction = (place - lower.at) / (stops[upper].at - lower.at)
        return Color(
            light: blend(lower.light, stops[upper].light, fraction),
            dark: blend(lower.dark, stops[upper].dark, fraction))
    }

    /// One stop of the `verdict` ramp: where on the 0…1 reading it sits, and
    /// the hex it takes in each appearance.
    private struct Stop {
        let at: Double
        let light: UInt32
        let dark: UInt32
    }

    /// Channel-wise sRGB mix of two hex colors, `fraction` of the way along.
    private static func blend(_ from: UInt32, _ to: UInt32, _ fraction: Double) -> UInt32 {
        func channel(_ shift: UInt32) -> UInt32 {
            let base = Double((from >> shift) & 0xFF)
            let target = Double((to >> shift) & 0xFF)
            return UInt32((base + (target - base) * fraction).rounded()) << shift
        }
        return channel(16) | channel(8) | channel(0)
    }

    // MARK: - Data hues

    /// The slots a chart may hand to a *group*: the accent stepped three ways,
    /// the one warm hue, then two steps of green. **Every one of them is
    /// a hue.** Grey is not a series colour — it belongs to the three things
    /// that are not groups (`other`, `unclassified`, `admin`), and a theme or
    /// task landing in one was the scale saying "this is filler" about real
    /// work. `neutral` therefore sits outside this list, reachable only by the
    /// fixed category scale.
    ///
    /// The greens are capacity, not decoration. Taking the grey out costs a
    /// slot, and the scale had none to spare: five hues against a six-group
    /// limit already meant the hash had nowhere to put the sixth, so two series
    /// on one chart always came out identical — a dogfood week drew "iCal" and
    /// "applying for openai api credits" both at #8AADD5. Six hues is what lets
    /// every group of a full lens have its own and none of them be grey.
    ///
    /// Green is a real departure from the one-accent rule, so it is held to the
    /// muted register the rest of the scale keeps — moss and pine, not emerald
    /// — and it was measured rather than eyeballed. Against every other colour
    /// a single chart can draw, plus the tone a band recedes to on hover, the
    /// whole set clears ΔE 14.7 in light and 17.2 in dark, and neither green is
    /// the pair that binds.
    ///
    /// `pine` lifts slightly in dark (#496237 → #536F3E) rather than darkening
    /// further, which is the same move `strong` makes. Below about this step a
    /// dark hue stops being a dark hue on a near-black ground and starts being
    /// a hole: the tone a receded band takes is #3D3D3C, and a series has to
    /// stay clear of *that* to be findable when the legend holds it up.
    ///
    /// Deliberately still short: a seventh group takes a slot again rather than
    /// minting another hue, and hue is never the only cue — every series here
    /// is named in the table row or the legend beside it.
    static let slots: [Color] = [
        Color(light: 0x3A5F8A, dark: 0x3D6DA5),   // strong
        Color(light: 0x7F9EC0, dark: 0x6F9DD0),   // mid
        Color(light: 0xB9CADB, dark: 0xA8C6E6),   // soft
        Color(light: 0xC98A3F, dark: 0xD09A5C),   // warm
        Color(light: 0x7C9669, dark: 0xA5BD93),   // moss
        Color(light: 0x496237, dark: 0x536F3E)    // pine
    ]

    static let strong = slots[0]
    static let mid = slots[1]
    static let soft = slots[2]
    static let warm = slots[3]
    /// The deeper green. Sits ΔE 10.8 from `live` under protanopia, which is
    /// inside the band that needs a second cue — and has one by construction:
    /// `live` is only ever a `StatusDot` with "Watching" or "Paused" written
    /// beside it, and never shares a surface with a chart series.
    static let moss = slots[4]
    /// The dark green — the deepest step of the scale, `strong`'s opposite
    /// number on the other hue.
    static let pine = slots[5]
    /// `admin`'s grey, and no group's. Outside `slots` on purpose: see there.
    static let neutral = Color(light: 0x9C9A92, dark: 0x5E5D58)
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
