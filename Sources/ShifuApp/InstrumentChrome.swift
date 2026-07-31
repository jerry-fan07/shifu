import SwiftUI

// The page furniture of the Instrument look: rules, eyebrows, figures, heads,
// column heads, and the scrolling body under them. Tokens live in
// Instrument.swift; the marks and the controls have files of their own.
//
// There are no cards here. Structure comes from hairlines and column
// alignment, which is what lets a screen carry thirty rows without feeling
// like thirty things.

// MARK: - Rules

/// A hairline. `weight` picks which of the three rule strengths it is: region
/// edges, section rules, row rules.
struct Rule: View {
    enum Weight { case edge, section, row }

    var weight: Weight = .row

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(height: 1)
    }

    private var color: Color {
        switch weight {
        case .edge: return Instrument.edge
        case .section: return Instrument.rule
        case .row: return Instrument.hairline
        }
    }
}

// MARK: - Type

/// The terminal register: uppercase, tracked out, monospaced. Section
/// eyebrows, column heads, units — never a sentence.
struct Eyebrow: View {
    let text: String
    var color: Color
    var size: CGFloat
    var tracking: CGFloat

    init(
        _ text: String, color: Color = Instrument.ghost,
        size: CGFloat = 10, tracking: CGFloat? = nil
    ) {
        self.text = text
        self.color = color
        self.size = size
        self.tracking = tracking ?? size * 0.1
    }

    var body: some View {
        Text(text.uppercased())
            .font(Instrument.eyebrow(size))
            .tracking(tracking)
            .foregroundStyle(color)
    }
}

/// Any number the eye is meant to compare down a column: mono, tabular, and
/// never restyled per row.
struct Figure: View {
    let text: String
    var size: CGFloat = 12.5
    var weight: Font.Weight = .regular
    var color: Color = Instrument.ink

    init(
        _ text: String, size: CGFloat = 12.5,
        weight: Font.Weight = .regular, color: Color = Instrument.ink
    ) {
        self.text = text
        self.size = size
        self.weight = weight
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(Instrument.mono(size, weight))
            .monospacedDigit()
            .foregroundStyle(color)
    }
}

/// The line that closes a screen: what the numbers above it don't say, in one
/// sentence, quietly.
struct QuietLine<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .font(Instrument.sans(12.5))
            .foregroundStyle(Instrument.muted)
            .padding(.top, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Page furniture

/// Every page's top block: what you are looking at, one line of what it means,
/// and the page's own controls — over a rule. The one bar of chrome a page
/// gets; nothing goes in the window title bar.
struct PageHead<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    init(
        _ title: String, subtitle: String? = nil,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: 20) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(Instrument.sans(18, .semibold))
                        .tracking(-0.18)
                        .foregroundStyle(Instrument.ink)
                    if let subtitle {
                        Text(subtitle)
                            .font(Instrument.sans(12.5))
                            .foregroundStyle(Instrument.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                trailing
            }
            .padding(.horizontal, Instrument.gutter)
            .padding(.top, 16)
            .padding(.bottom, 13)
            Rule(weight: .section)
        }
    }
}

/// The heading a measured page gets instead of a title: the figure itself,
/// big and mono, with what it counts beside it and how it compares under it.
struct HeroHead<Trailing: View>: View {
    let figure: String
    let caption: String
    var detail: AnyView?
    @ViewBuilder var trailing: Trailing

    init<Detail: View>(
        figure: String, caption: String,
        @ViewBuilder detail: () -> Detail,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.figure = figure
        self.caption = caption
        self.detail = AnyView(detail())
        self.trailing = trailing()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: 20) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(figure)
                            .font(Instrument.mono(30, .medium))
                            .monospacedDigit()
                            .tracking(-0.6)
                            .foregroundStyle(Instrument.ink)
                        Text(caption)
                            .font(Instrument.sans(13))
                            .foregroundStyle(Instrument.muted)
                    }
                    detail
                }
                Spacer(minLength: 0)
                trailing
            }
            .padding(.horizontal, Instrument.gutter)
            .padding(.top, 18)
            .padding(.bottom, 14)
            Rule(weight: .section)
        }
    }
}

/// A block of the page below the head — a ribbon, a week's rows — pinned above
/// the scrolling table and closed with a rule.
struct Band<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
                .padding(.horizontal, Instrument.gutter)
                .padding(.top, 16)
                .padding(.bottom, 14)
            Rule(weight: .section)
        }
    }
}

/// A table's column heads: mono, tracked, over a rule. Takes the same cells
/// the rows below it use, so a column can't drift from its heading.
struct ColumnHead<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) { content }
                .font(Instrument.eyebrow())
                .tracking(1)
                .foregroundStyle(Instrument.ghost)
                .textCase(.uppercase)
                // A wrapped column head pushes its own table's first row down
                // and stops reading as a heading at all.
                .lineLimit(1)
                .padding(.top, 10)
                .padding(.bottom, 7)
            Rule(weight: .section)
        }
    }
}

/// The scrolling half of a page: the table under the pinned head, with the
/// gutter already applied.
struct PageBody<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.horizontal, Instrument.gutter)
                .padding(.bottom, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// What a page says when it has nothing to show. One sentence, in the muted
/// register — no illustration, because an instrument with nothing on it should
/// look like an instrument with nothing on it.
struct BlankSlate: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(Instrument.sans(13))
            .foregroundStyle(Instrument.muted)
            .frame(maxWidth: 460, alignment: .leading)
            .padding(.vertical, 18)
    }
}
