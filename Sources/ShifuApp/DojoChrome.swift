import SwiftUI

// The reusable furniture of the Dojo look: cards, page headers, stat tiles,
// chips, and the empty states. Tokens live in Dojo.swift.

// MARK: - Cards

/// One card above the paper: surface fill, continuous corners, hairline ring,
/// and a shadow soft enough to be depth rather than decoration.
private struct DojoCard: ViewModifier {
    var padding: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Dojo.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Dojo.hairline, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
    }
}

/// The scroll a place's page is unfurled on: frosted rice paper over the
/// mountain. The material is what keeps the world's colour and the hour's light
/// in the room without ever letting the landscape behind it compete with a
/// column of numbers.
private struct DojoPanel: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    Rectangle().fill(.ultraThinMaterial)
                    Dojo.paper.opacity(0.76)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Dojo.hairline, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.24), radius: 24, y: 8)
    }
}

extension View {
    func dojoCard(padding: CGFloat = 16) -> some View {
        modifier(DojoCard(padding: padding))
    }

    func dojoPanel() -> some View {
        modifier(DojoPanel())
    }
}

// MARK: - Type helpers

/// The terminal register: uppercase, tracked out, monospaced. Section
/// eyebrows and units only — never a sentence.
struct Eyebrow: View {
    let text: String
    var color: Color?

    init(_ text: String, color: Color? = nil) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text.uppercased())
            .font(Dojo.label())
            .tracking(1.5)
            .foregroundStyle(color ?? Color.secondary)
    }
}

/// The banner at the top of every page that isn't Today: eyebrow, title, one
/// line of what the page is for, and room for the page's own controls.
struct PageHeader<Trailing: View>: View {
    let eyebrow: String
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    init(
        _ eyebrow: String, title: String, subtitle: String? = nil,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) {
        self.eyebrow = eyebrow
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Eyebrow(eyebrow, color: Dojo.accentText)
                Text(title)
                    .font(Dojo.display(24))
                if let subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            trailing
        }
    }
}

/// Every place except Today: its header at the top of the place's scroll, with
/// the page's own controls in the header's trailing slot. No ground of its own —
/// the scroll supplies that. Nothing goes in the window toolbar either: one bar
/// of chrome per page, and it's this one.
struct PageScaffold<Controls: View, Content: View>: View {
    let destination: Destination
    @ViewBuilder var controls: Controls
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(
                destination.region, title: destination.title,
                subtitle: destination.blurb
            ) {
                controls
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 14)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

/// A heading inside a page. Quieter than `PageHeader` — mono, tracked, with a
/// hairline running off to the right so sections read as strata.
struct SectionHeading: View {
    let text: String
    var trailing: String?

    init(_ text: String, trailing: String? = nil) {
        self.text = text
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 10) {
            Eyebrow(text)
            Rectangle()
                .fill(Dojo.hairline)
                .frame(height: 1)
            if let trailing {
                Text(trailing)
                    .font(Dojo.label(10))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Numbers

/// Hero-number tile: big display value over a tracked mono label, with an
/// accent edge when the number is one you're meant to act on.
struct StatTile: View {
    let value: Int
    let label: String
    var accented = false

    private var isLive: Bool { accented && value > 0 }

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(isLive ? Dojo.accent : Color.clear)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(value)")
                    .font(Dojo.display(23))
                    .monospacedDigit()
                    .foregroundStyle(isLive ? Dojo.accentText : .primary)
                Eyebrow(label)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
        }
        .frame(minWidth: 104, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
        .dojoCard(padding: 0)
    }
}

/// A small labelled pellet — durations, categories, counts.
struct DojoChip: View {
    let text: String
    var dot: Color?

    var body: some View {
        HStack(spacing: 5) {
            if let dot {
                Circle().fill(dot).frame(width: 7, height: 7)
            }
            Text(text)
                .font(.caption)
                .monospacedDigit()
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Dojo.well, in: Capsule())
    }
}

// MARK: - Empty states

/// A themed empty state: Shifu's own face, a title, and one line in his voice.
/// Replaces `ContentUnavailableView` on Shifu's own pages so an empty screen
/// still has someone in it.
///
/// No landscape here — the window already *is* one, and a second mountain in a
/// card on top of the first only puts two Shifus on the screen at once.
struct SenseiEmptyState<Actions: View>: View {
    let title: String
    let message: String
    var mood: SenseiFigure.Mood = .serene
    @ViewBuilder var actions: Actions

    init(
        _ title: String, message: String, mood: SenseiFigure.Mood = .serene,
        @ViewBuilder actions: () -> Actions = { EmptyView() }
    ) {
        self.title = title
        self.message = message
        self.mood = mood
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 14) {
            SenseiFigure(size: 40, mood: mood)
            VStack(spacing: 6) {
                Text(title)
                    .font(Dojo.display(16))
                Text(message)
                    .font(Dojo.voice())
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
            actions
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
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
        "Every scroll was once a blank page.",
        "The summit is a rumour until the first step.",
        "Fog hides the path, never the direction."
    ]

    static func daily(on date: Date = Date()) -> String {
        let day = Calendar.current.ordinality(of: .day, in: .era, for: date) ?? 0
        return lines[day % lines.count]
    }
}
