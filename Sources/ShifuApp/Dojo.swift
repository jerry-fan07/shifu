import AppKit
import SwiftUI

/// The Dojo design system (design.md §7): Shifu's visual identity as a desktop
/// app. Warm paper surfaces, ink text, and one terracotta accent — the master's
/// robe — with every chart hue validated for CVD separation and contrast on
/// both surfaces (light `#FAF9F5`, dark `#262624`).
enum Dojo {
    // MARK: - Surfaces

    /// The window's ground — warm paper in light, warm ink in dark.
    static let paper = Color(light: 0xFAF9F5, dark: 0x1F1E1D)
    /// One card above the paper.
    static let surface = Color(light: 0xFFFFFF, dark: 0x2B2A28)
    /// A recessed fill *on* a surface — pickers, bar tracks, chips.
    static let well = Color(light: 0xF0EDE6, dark: 0x383632)
    /// Hairline strokes around cards and between regions.
    static let hairline = Color(
        light: 0x1F1E1D, dark: 0xFFFFFF, lightAlpha: 0.08, darkAlpha: 0.10)

    // MARK: - The accent

    /// The robe: Claude-orange terracotta, stepped darker in light mode so it
    /// holds ≥3:1 on paper.
    static let accent = Color(light: 0xBF5A36, dark: 0xD97757)
    /// Accent-tinted text at caption sizes, one step darker again.
    static let accentText = Color(light: 0xA34A28, dark: 0xE08862)
    /// A wash of the accent for selected/soft fills.
    static let accentSoft = Color(
        light: 0xBF5A36, dark: 0xD97757, lightAlpha: 0.11, darkAlpha: 0.16)

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

    // MARK: - The mentor's voice

    /// Serif italic — the sensei speaks in a different register than the data.
    static func voice(size: CGFloat = 14) -> Font {
        .system(size: size, design: .serif).italic()
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

// MARK: - Chrome

/// One card above the paper: surface fill, continuous corners, hairline ring.
private struct DojoCard: ViewModifier {
    var padding: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Dojo.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Dojo.hairline, lineWidth: 1)
            }
    }
}

extension View {
    func dojoCard(padding: CGFloat = 16) -> some View {
        modifier(DojoCard(padding: padding))
    }
}

/// Hero-number tile: big value, muted label underneath. Shared by the Today
/// and Practice pages.
struct StatTile: View {
    let value: Int
    let label: String
    var accented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(value)")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(accented && value > 0 ? Dojo.accentText : .primary)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minWidth: 92, alignment: .leading)
        .dojoCard(padding: 0)
    }
}

// MARK: - Wisdom

/// The sensei's aphorisms. Original lines, not attributed quotes — the mentor
/// is the app, not a citation. `daily` is stable for a calendar day so the
/// greeting doesn't churn on every refresh.
enum Wisdom {
    static let lines = [
        "The day is carved one hour at a time.",
        "Attention is the chisel; time is the stone.",
        "A path appears only under moving feet.",
        "Tend the minutes and the hours bow.",
        "Still water reflects. Hurried water distorts.",
        "What is measured gently is mastered gently.",
        "The strong tree grew while no one watched.",
        "Begin where you stand; there is no other floor.",
        "One stroke, then another. That is the whole art.",
        "Rest is also practice.",
        "The archer studies the arrows already flown.",
        "Small habits carry heavy days.",
        "Do not chase two rabbits.",
        "The record does not judge; it remembers.",
        "Slow is smooth, and smooth is fast.",
        "Every scroll was once a blank page."
    ]

    static func daily(on date: Date = Date()) -> String {
        let day = Calendar.current.ordinality(of: .day, in: .era, for: date) ?? 0
        return lines[day % lines.count]
    }
}
