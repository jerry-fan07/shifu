import AppKit
import ShifuCore
import SwiftUI

// The rows a note's prose is set in. `CardTextView` decides *what* each run of
// the Markdown is; this file decides what each of those looks like.
//
// The rule they share: a note is not a document with typography of its own, it
// is a page of this app. So a section name is set in the app's section register
// (the eyebrow), a clock time is set in the app's figure face and hung in a
// margin, and a list that turns out to be a table is drawn as one.

// MARK: - A stretch of the day

/// The rail a timeline hangs off, in numbers — shared so that a caller which
/// stacks its own blocks under a timeline (the task page's day) can hang them
/// off the same column, and the day reads as one document.
enum SessionRail {
    /// Between the span and the rail, the rail itself, and the rail and the
    /// prose.
    static let gap: CGFloat = 12
    static let width: CGFloat = 2
    static let lead: CGFloat = 14

    static func contentInset(gutter: CGFloat) -> CGFloat { gutter + gap + width + lead }
}

/// One stretch, as the note wrote it: the span in the margin, the prose beside
/// it, and the rail between them that makes a stack of these a timeline rather
/// than a list of paragraphs.
///
/// `detail` is what the *front matter* knows and the prose doesn't — a lead
/// reading "00:00–03:27" is often three separate stretches — so it only
/// appears where the caller has the note's own `sessions:` to count.
struct SessionRow<Prose: View>: View {
    let span: String
    var detail: String?
    var isActive = false
    var gutter: CGFloat
    var baseSize: CGFloat = 12.5
    @ViewBuilder var prose: Prose

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .trailing, spacing: 3) {
                Figure(span, size: baseSize - 1,
                       color: isActive ? Instrument.ink : Instrument.faint)
                if let detail {
                    Figure(detail, size: baseSize - 2.5, color: Instrument.ghost)
                }
            }
            .padding(.top, baseSize * 0.12)     // mono cap-height against prose
            .frame(width: gutter, alignment: .trailing)
            .padding(.trailing, SessionRail.gap)
            Rectangle()
                .fill(isActive ? Instrument.accent : Instrument.edge)
                .frame(width: SessionRail.width)
            prose
                .padding(.leading, SessionRail.lead)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - A timeline over days

/// A run of dated leads set the way the task page sets a day: the ribbon
/// above, the rows below, and one hover shared between them. Hovering a row
/// lights its rail and its mark on the ribbon; everything else — the other
/// marks, the other rows' prose — recedes.
struct ProseTimeline: View {
    struct Row: Identifiable {
        let id: Int
        let span: String
        let text: AttributedString
    }

    let rows: [Row]
    var baseSize: CGFloat = 13
    var gutter: CGFloat
    var color: Color = Instrument.body

    @State private var active: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DateRibbon(
                marks: rows.map {
                    DateRibbon.Mark(
                        dates: NoteProse.spanDates($0.span),
                        caption: NoteProse.dayLabel($0.span))
                },
                highlight: active)
                .padding(.leading, SessionRail.contentInset(gutter: gutter))
            ForEach(rows) { row in
                stretch(row)
            }
        }
    }

    private func stretch(_ row: Row) -> some View {
        SessionRow(
            span: NoteProse.dayLabel(row.span), detail: nil,
            isActive: active == row.id, gutter: gutter, baseSize: baseSize
        ) {
            Text(row.text)
                .font(Instrument.sans(baseSize))
                .lineSpacing(baseSize * 0.26)
                .foregroundStyle(
                    active == nil || active == row.id ? color : Instrument.faint)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 14)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { active = row.id } else if active == row.id { active = nil }
        }
    }
}

// MARK: - Lists that turned out to be tables

/// `problem → fix`, as the two columns it is. The arrow is the row's spine:
/// what went wrong on the left, what settled it on the right, so a column of
/// them can be read down either side.
struct PairRow: View {
    let before: AttributedString
    let after: AttributedString
    var baseSize: CGFloat = 12.5

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(before)
                .font(Instrument.sans(baseSize))
                .lineSpacing(baseSize * 0.26)
                .foregroundStyle(Instrument.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
            Figure("→", size: baseSize - 0.5, color: Instrument.faint)
                .frame(width: 22)
                .padding(.top, 1)
            Text(after)
                .font(Instrument.sans(baseSize))
                .lineSpacing(baseSize * 0.26)
                .foregroundStyle(Instrument.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .textSelection(.enabled)
        .padding(.vertical, 9)
    }
}

/// One decision: what was decided, and — under it, quieter — why. Numbered,
/// because a day's decisions are a countable list and "three things were
/// settled" is the first thing the eye should be able to take from it.
struct ClaimRow: View {
    let index: Int
    let claim: AttributedString
    let reason: AttributedString?
    var baseSize: CGFloat = 12.5

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Figure(String(format: "%02d", index), size: baseSize - 2, color: Instrument.ghost)
                .padding(.top, 2)
                .frame(width: 18, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(claim)
                    .font(Instrument.sans(baseSize, .medium))
                    .lineSpacing(baseSize * 0.26)
                    .foregroundStyle(Instrument.ink)
                if let reason {
                    Text(reason)
                        .font(Instrument.sans(baseSize))
                        .lineSpacing(baseSize * 0.26)
                        .foregroundStyle(Instrument.muted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .textSelection(.enabled)
        .padding(.vertical, 9)
    }
}

/// A wiki link from a note body — a place the reader can go, set as a chip so
/// a row of them reads as a shelf rather than as a sentence with brackets in
/// it. Inert when nothing is indexed under that title.
struct LinkChip: View {
    let target: String
    var action: (() -> Void)?

    var body: some View {
        Button { action?() } label: {
            Text(target)
                .font(Instrument.sans(11.5))
                .foregroundStyle(action == nil ? Instrument.muted : Instrument.accentText)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(action == nil ? Instrument.rule : Instrument.accent.opacity(0.3),
                                lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
    }
}

/// A source the day was spent in, as the head sets them: the note's own
/// `sources:` list, in the figure face because they are labels, not prose.
struct SourceChip: View {
    let name: String

    var body: some View {
        Figure(name, size: 10.5, color: Instrument.muted)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Instrument.rule, lineWidth: 1))
    }
}

// MARK: - Layout

/// Chips wrapped onto as many lines as they need. A `LazyVGrid` can't do this
/// — its columns are fixed and a chip is as wide as its word.
struct FlowRow: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 5

    private struct Line {
        var count = 0
        var width: CGFloat = 0
        var height: CGFloat = 0

        var isEmpty: Bool { count < 1 }
    }

    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGSize {
        let lines = self.lines(subviews, width: proposal.width ?? .infinity)
        let stacked = lines.reduce(0) { $0 + $1.height }
        return CGSize(
            width: proposal.width ?? lines.map(\.width).max() ?? 0,
            height: stacked + lineSpacing * CGFloat(max(0, lines.count - 1)))
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var top = bounds.minY
        var index = 0
        for line in lines(subviews, width: bounds.width) {
            var left = bounds.minX
            for _ in 0..<line.count {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: left, y: top + (line.height - size.height) / 2),
                    proposal: ProposedViewSize(size))
                left += size.width + spacing
                index += 1
            }
            top += line.height + lineSpacing
        }
    }

    private func lines(_ subviews: Subviews, width: CGFloat) -> [Line] {
        var lines: [Line] = []
        var line = Line()
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let extended = line.isEmpty ? size.width : line.width + spacing + size.width
            if extended > width, !line.isEmpty {
                lines.append(line)
                line = Line()
            }
            line.width = line.isEmpty ? size.width : line.width + spacing + size.width
            line.height = max(line.height, size.height)
            line.count += 1
        }
        if !line.isEmpty { lines.append(line) }
        return lines
    }
}
