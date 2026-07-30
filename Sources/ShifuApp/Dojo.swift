import AppKit
import SwiftUI

/// The Dojo design system (design.md §7): Shifu's visual identity as a desktop
/// app. The window is a place on a mountain — a warm paper ground, ink text,
/// one terracotta accent (the headband), and the sky of whatever hour it is.
/// Every chart hue is validated for CVD separation and contrast on both
/// surfaces.
enum Dojo {
    // MARK: - Surfaces

    /// The window's ground — rice paper in light, a cool slate in dark. Dark
    /// leans blue rather than brown so it sits under the same skies the
    /// landscape paints.
    static let paper = Color(light: 0xF6F2E9, dark: 0x16171C)
    /// One card above the paper.
    static let surface = Color(light: 0xFFFDF8, dark: 0x212329)
    /// A recessed fill *on* a surface — pickers, bar tracks, chips.
    static let well = Color(light: 0xEBE5D7, dark: 0x2C2F37)
    /// Hairline strokes around cards and between regions.
    static let hairline = Color(
        light: 0x2A2A28, dark: 0xFFFFFF, lightAlpha: 0.09, darkAlpha: 0.11)
    /// The sidebar's ground: a shade off the paper so the split reads without
    /// a hard line.
    static let sidebar = Color(light: 0xEFE9DA, dark: 0x101116)

    // MARK: - The accent

    /// The headband: Claude-orange terracotta, stepped darker in light mode so
    /// it holds ≥3:1 on paper.
    static let accent = Color(light: 0xBF5A36, dark: 0xD97757)
    /// Accent-tinted text at caption sizes, one step darker again.
    static let accentText = Color(light: 0xA34A28, dark: 0xE08862)
    /// A wash of the accent for selected/soft fills.
    static let accentSoft = Color(
        light: 0xBF5A36, dark: 0xD97757, lightAlpha: 0.12, darkAlpha: 0.17)

    // MARK: - Chart hues (validated — see design.md §7)

    /// The eight categorical slots, in CVD-safe order. Charts assign them by
    /// entity (stable name hash), never by rank; a ninth group folds into
    /// "Other" rather than minting a hue.
    static let chartSlots: [Color] = [
        Color(light: 0xC15F3C, dark: 0xD5714A),   // terracotta
        Color(light: 0x3E7BC9, dark: 0x5B95E0),   // blue
        Color(light: 0xB98300, dark: 0xC08618),   // gold
        Color(light: 0x2F8F5B, dark: 0x3FA06A),   // jade
        Color(light: 0x7B5CC9, dark: 0x9678E0),   // violet
        Color(light: 0x0A93A3, dark: 0x2AA5B5),   // teal
        Color(light: 0xBF5586, dark: 0xD06795),   // magenta
        Color(light: 0x5560C9, dark: 0x7580E0)    // indigo
    ]

    static let terracotta = chartSlots[0]
    static let blue = chartSlots[1]
    static let gold = chartSlots[2]
    static let jade = chartSlots[3]
    static let violet = chartSlots[4]
    static let teal = chartSlots[5]
    static let magenta = chartSlots[6]
    static let indigo = chartSlots[7]

    /// Status steps for card urgency — always paired with a label or symbol,
    /// never color alone (CardsHomeView legend / chips).
    static let statusRed = Color(light: 0xC03434, dark: 0xE05B5B)
    static let statusAmber = Color(light: 0xB97C10, dark: 0xD99A2B)
    static let statusGreen = Color(light: 0x2E7D43, dark: 0x4CAF6E)

    // MARK: - Type

    /// Three registers, and no more than three:
    ///
    /// - `display` — SF, for titles and hero numbers, set heavier than the
    ///   body around it so weight alone carries the hierarchy.
    /// - `label` — SF Mono, uppercase, tracked out. Section eyebrows, units,
    ///   axis ticks: the terminal register, the one that says "this is a log".
    /// - system body — everything you actually read. Never restyled.
    static func display(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    static func label(_ size: CGFloat = 10.5, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// The mentor's aside — the same size as the body text around it, set in
    /// italic so his lines read as spoken rather than reported.
    static func voice(size: CGFloat = 14) -> Font {
        .system(size: size, design: .default).italic()
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
