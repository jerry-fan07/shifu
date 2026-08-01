import AppKit
import ShifuCore
import SwiftUI

/// Renders a card's or a note's Markdown natively (§7: no web views). Three
/// passes feed it: `CardMarkup` cuts out the code and the math, `NoteProse`
/// reads the line structure the vault writes in — session leads, sub-headings,
/// bullets, wiki links — and `NoteProse.shape` reads a *run* of list items for
/// what its own grammar says it is.
///
/// That last pass is the one that matters. The vault's lists are written by a
/// model against a prompt that asks for shapes — "bullets pairing what went
/// wrong with what fixed it", "bullets, each with the reason behind it" — so
/// the table is already in the sentences, and printing it as a column of
/// hyphens is the renderer throwing that away.
struct CardTextView: View {
    let text: String
    var baseSize: CGFloat = 13
    var alignment: TextAlignment = .leading
    var color: Color = Instrument.body

    /// One vertical slab: a logical line of prose, or a block that owns its
    /// own shape.
    private enum Block {
        case line(NoteProse.Kind, AttributedString)
        case displayMath(AttributedString)
        case code(String, language: String?)
    }

    private struct Item {
        var marker: String
        var text: AttributedString
    }

    /// A block, or the whole run of list items one belonged to — the shape of
    /// a list is a property of the run, not of any one item in it. A run of
    /// dated leads is likewise one slab: the ribbon over it belongs to the
    /// run, not to any row.
    private enum Slab {
        case block(Block)
        case list(NoteProse.ListShape, [Item])
        case links([String])
        case timeline([ProseTimeline.Row])
    }

    /// Which rail row (session or dated) the pointer is on — the body's one
    /// piece of interaction state, shared down to the rows so hovering one
    /// lights its rail and recedes its siblings' prose.
    @State private var active: Int?
    /// The parse, cached against its text: hovering a rail row re-renders
    /// this body, and re-reading a 1,200-word note's Markdown on every mouse
    /// crossing is the difference between a highlight and a stutter.
    @State private var parsed: [Slab] = []
    @State private var parsedFor: String?

    var body: some View {
        let slabs = parsedFor == text ? parsed : self.slabs(makeBlocks())
        // Measured once for the whole body rather than once per session row —
        // and sized to the widest lead the body actually has, so a note that
        // mixes clock spans and date spans still hangs both off one column.
        let gutter = Self.gutterWidth(for: slabs, baseSize: baseSize)
        VStack(alignment: horizontalAlignment, spacing: 0) {
            ForEach(slabs.indices, id: \.self) { index in
                slab(slabs[index], index: index, gutter: gutter)
                    .padding(.top, index == 0 ? 0 : Self.gap(
                        after: slabs[index - 1], before: slabs[index], baseSize: baseSize))
            }
        }
        .onAppear(perform: reparse)
        .onChange(of: text) { _, _ in reparse() }
    }

    private func reparse() {
        parsed = slabs(makeBlocks())
        parsedFor = text
    }

    @ViewBuilder private func slab(_ slab: Slab, index: Int, gutter: CGFloat) -> some View {
        switch slab {
        case .block(let block):
            switch block {
            case .line(let kind, let attributed):
                ProseLine(
                    kind: kind, text: attributed, baseSize: baseSize,
                    alignment: alignment, color: color, gutter: gutter,
                    index: index, active: $active)
            case .displayMath(let attributed):
                Text(attributed)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity)
            case .code(let code, let language):
                CodeBlockView(code: code, language: language, baseSize: baseSize)
            }
        case .list(let shape, let items):
            ProseList(shape: shape, items: items.map { ($0.marker, $0.text) },
                      baseSize: baseSize, color: color)
        case .links(let targets):
            // Inert: this is the file's own link list, and the pages that can
            // actually follow one list them as rows of their own.
            FlowRow {
                ForEach(targets, id: \.self) { LinkChip(target: $0) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .timeline(let rows):
            ProseTimeline(rows: rows, baseSize: baseSize, gutter: gutter, color: color)
        }
    }

    private var horizontalAlignment: HorizontalAlignment {
        switch alignment {
        case .center: return .center
        case .trailing: return .trailing
        default: return .leading
        }
    }

    // MARK: - Blocks

    /// Interleaves the inline and line passes. The inline pass wins the outer
    /// loop because it is the one that can swallow newlines (a fenced block
    /// spans lines); the line pass then runs over each plain run, and a line
    /// left open by an inline span — "fixed the `agy` retry" — is picked up by
    /// the next run rather than restarted.
    private func makeBlocks() -> [Block] {
        var blocks: [Block] = []
        var open: (kind: NoteProse.Kind, text: AttributedString)?
        var takesInline = false     // the open line can still absorb a span

        func flush() {
            defer { open = nil }
            guard let open,
                  !String(open.text.characters)
                      .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return }
            blocks.append(.line(open.kind, open.text))
        }
        func appendInline(_ piece: AttributedString) {
            if !takesInline { flush() }
            open = (open?.kind ?? .paragraph, (open?.text ?? AttributedString()) + piece)
            takesInline = true
        }

        for segment in CardMarkup.segments(text) {
            switch segment {
            case .text(let plain):
                for line in NoteProse.lines(plain, continuing: takesInline && open != nil) {
                    if line.continuesPrevious, open != nil {
                        open?.text += Self.markdownText(line.text)
                    } else {
                        flush()
                        open = (line.kind, Self.markdownText(line.text))
                    }
                }
                takesInline = !plain.hasSuffix("\n")
            case .inlineCode(let code):
                appendInline(Self.inlineCode(code, size: baseSize))
            case .inlineMath(let runs):
                appendInline(Self.math(runs, size: baseSize))
            case .displayMath(let runs):
                flush()
                takesInline = false
                blocks.append(.displayMath(Self.math(runs, size: baseSize + 3)))
            case .codeBlock(let code, let language):
                flush()
                takesInline = false
                blocks.append(.code(code, language: language))
            }
        }
        flush()
        return blocks
    }

    /// Gathers runs of list items, and asks what each run is — the heading the
    /// run sits under first (§2.1 names its shapes), its own grammar second.
    /// Runs of dated leads gather the same way, into the timeline their
    /// ribbon spans.
    private func slabs(_ blocks: [Block]) -> [Slab] {
        var slabs: [Slab] = []
        var items: [Item] = []
        var links: [String] = []
        var rows: [ProseTimeline.Row] = []
        var heading: String?

        func closeList() {
            guard !items.isEmpty else { return }
            let shape = NoteProse.shape(
                of: items.map { String($0.text.characters) }, under: heading)
            slabs.append(.list(shape, items))
            items = []
        }
        func closeLinks() {
            guard !links.isEmpty else { return }
            slabs.append(.links(links))
            links = []
        }
        func closeTimeline() {
            guard !rows.isEmpty else { return }
            slabs.append(.timeline(rows))
            rows = []
        }

        for block in blocks {
            switch block {
            case .line(.bullet(let marker), let text):
                closeLinks()
                closeTimeline()
                items.append(Item(marker: marker, text: text))
            case .line(.link(let target), _):
                closeList()
                closeTimeline()
                links.append(target)
            case .line(.dated(let span), let text):
                closeList()
                closeLinks()
                rows.append(ProseTimeline.Row(id: rows.count, span: span, text: text))
            default:
                closeList()
                closeLinks()
                closeTimeline()
                if case .line(.heading, let text) = block {
                    heading = String(text.characters)
                }
                slabs.append(.block(block))
            }
        }
        closeList()
        closeLinks()
        closeTimeline()
        return slabs
    }

    /// The space above a slab, from what it is and what it follows: a change of
    /// *kind* is a bigger break than a change of paragraph.
    private static func gap(after previous: Slab, before next: Slab, baseSize: CGFloat)
        -> CGFloat {
        let scale = baseSize / 13
        if case .block(.line(.heading(let level), _)) = next {
            return (level >= 3 ? 18 : 23) * scale
        }
        if case .block(.line(.heading, _)) = previous { return 7 * scale }
        switch next {
        case .list, .links: return 9 * scale
        case .block(.line(.session, _)), .timeline: return 15 * scale
        default: return 9 * scale
        }
    }

    // MARK: - AttributedString builders

    /// Plain text through the inline Markdown parser so **bold** / *italic* in
    /// extracted notes render; falls back to the literal string.
    static func markdownText(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: NoteProse.inlineSafe(text),
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    /// The styled run between two character offsets — how a list item that
    /// came apart at a clause keeps the inline code in both halves.
    static func slice(_ text: AttributedString, from: Int, to: Int? = nil) -> AttributedString {
        let characters = text.characters
        let count = characters.count
        let start = characters.index(characters.startIndex, offsetBy: min(from, count))
        let end = to.map { characters.index(characters.startIndex, offsetBy: min($0, count)) }
            ?? characters.endIndex
        guard start <= end else { return text }
        return AttributedString(text[start..<end])
    }

    static func inlineCode(_ code: String, size: CGFloat) -> AttributedString {
        var attributed = AttributedString(code)
        attributed.font = Instrument.mono(size - 1)
        attributed.backgroundColor = .primary.opacity(0.06)
        return attributed
    }

    /// The width a session's span column takes at `baseSize` — the figure and
    /// the space before the rail. Exposed because a caller that stacks its own
    /// blocks under a timeline (the task page's day) has to hang them off the
    /// same column, or the day reads as two documents.
    static func sessionGutter(baseSize: CGFloat) -> CGFloat {
        SessionRail.contentInset(gutter: spanWidth(baseSize))
    }

    /// Wide enough for one "00:00–00:00" — measured, because the figure face is
    /// whichever of Plex Mono and SF Mono is installed. A model that merged two
    /// stretches into one lead writes a longer label; that one wraps inside the
    /// column rather than widening it for every row.
    static func spanWidth(_ baseSize: CGFloat) -> CGFloat {
        measured("00:00–00:00", baseSize: baseSize)
    }

    /// The gutter a body needs: the clock column, widened to the date column
    /// ("Aug 29–Aug 29" at the widest month name) only when the body actually
    /// hangs dated leads — a work note's sessions shouldn't pay a timeline's
    /// margin.
    private static func gutterWidth(for slabs: [Slab], baseSize: CGFloat) -> CGFloat {
        let dated = slabs.contains {
            if case .timeline = $0 { return true }
            return false
        }
        guard dated else { return spanWidth(baseSize) }
        let month = Calendar(identifier: .gregorian).shortMonthSymbols
            .max { $0.count < $1.count } ?? "May"
        return max(spanWidth(baseSize),
                   measured("\(month) 29–\(month) 29", baseSize: baseSize))
    }

    private static func measured(_ template: String, baseSize: CGFloat) -> CGFloat {
        let font = Instrument.monoFont(baseSize - 1)
        return ceil((template as NSString).size(withAttributes: [.font: font]).width)
    }

    /// Styled math runs: serif throughout, italic only for variables so
    /// digits, operators and function names stay upright the way a typeset
    /// formula has them, with raised/lowered smaller runs for scripts and
    /// fraction halves (CardMarkup.MathRun).
    static func math(_ runs: [CardMarkup.MathRun], size: CGFloat) -> AttributedString {
        var attributed = AttributedString()
        for run in runs {
            var piece = AttributedString(run.text)
            let pointSize = run.script == .normal ? size + 1 : size * 0.72
            let font = Font.system(size: pointSize, design: .serif)
            piece.font = run.style == .variable ? font.italic() : font
            switch run.script {
            case .normal: break
            case .raised: piece.baselineOffset = size * 0.38
            case .lowered: piece.baselineOffset = -size * 0.18
            }
            attributed += piece
        }
        return attributed
    }
}

/// One logical line, in the register its kind earns: a section name as the
/// app's eyebrow, a list item with its marker in a gutter so the wrap hangs
/// under the text and not under the bullet, and a session as a timeline row.
///
/// A named type rather than a `@ViewBuilder` switch inline: this one is
/// instantiated once per line, and a five-branch `_ConditionalContent`
/// multiplied out that far has crashed IRGen in this target before.
struct ProseLine: View {
    let kind: NoteProse.Kind
    let text: AttributedString
    var baseSize: CGFloat = 13
    var alignment: TextAlignment = .leading
    var color: Color = Instrument.body
    var gutter: CGFloat = 0
    /// This line's place in the body, and the body's shared "which rail row
    /// is hovered" state. Only session and dated rows read or write it; left
    /// nil, a timeline renders inert.
    var index: Int = 0
    var active: Binding<Int?>?

    var body: some View {
        switch kind {
        case .paragraph:
            prose(alignment)
        case .heading(let level):
            heading(level)
        case .bullet(let marker):
            BulletRow(marker: marker, text: text, baseSize: baseSize, color: color)
        case .session(let span):
            railRow(span: span)
        case .dated(let span):
            // The same rail a session hangs off, with days for clocks — a
            // timeline over weeks instead of a day, read down the same edge.
            railRow(span: NoteProse.dayLabel(span))
        case .link(let target):
            LinkChip(target: target)
        }
    }

    /// One timeline row, with the day view's linked dimming: hovering lights
    /// this row's rail and span and recedes its siblings' prose, so "which
    /// stretch is this paragraph?" reads the same on every rail in the app.
    private func railRow(span: String) -> some View {
        let hovered = active?.wrappedValue
        return SessionRow(
            span: span, detail: nil, isActive: hovered == index,
            gutter: gutter, baseSize: baseSize
        ) {
            prose(.leading, dimmed: hovered != nil && hovered != index)
        }
        .contentShape(Rectangle())
        .onHover { inside in
            if inside {
                active?.wrappedValue = index
            } else if active?.wrappedValue == index {
                active?.wrappedValue = nil
            }
        }
    }

    private func prose(_ textAlignment: TextAlignment, dimmed: Bool = false) -> some View {
        Text(text)
            .font(Instrument.sans(baseSize))
            .lineSpacing(baseSize * 0.26)
            .multilineTextAlignment(textAlignment)
            .foregroundStyle(dimmed ? Instrument.faint : color)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// `##` and `###` are section names, so they are set the way every other
    /// section name in the app is — the terminal register, not a bigger bold.
    /// In the accent, not the page chrome's grey: these are the *document's*
    /// own structure, and the one hue that is text-safe in both appearances
    /// marks them as such. (Not the palette's gold — that is the focus chart
    /// slot, and chrome must not impersonate a series.)
    /// `#`, which the compiler never writes but a hand-edited note might, is a
    /// title.
    @ViewBuilder private func heading(_ level: Int) -> some View {
        if level == 1 {
            Text(text)
                .font(Instrument.sans(baseSize + 3, .semibold))
                .tracking(-0.2)
                .foregroundStyle(Instrument.ink)
                .textSelection(.enabled)
        } else {
            Eyebrow(String(text.characters), color: Instrument.accentText,
                    size: max(10, baseSize - 2.5))
        }
    }
}

/// One list item in the plain shape: the marker in a gutter of its own so the
/// second line hangs under the words and not under the bullet.
struct BulletRow: View {
    let marker: String
    let text: AttributedString
    var baseSize: CGFloat = 13
    var color: Color = Instrument.body

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(marker)
                .font(marker == "•" ? Instrument.sans(baseSize) : Instrument.mono(baseSize - 1))
                .foregroundStyle(Instrument.ghost)
                .frame(width: width, alignment: .leading)
            Text(text)
                .font(Instrument.sans(baseSize))
                .lineSpacing(baseSize * 0.26)
                .foregroundStyle(color)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var width: CGFloat {
        marker == "•" ? baseSize * 1.05 : baseSize * 0.62 * CGFloat(marker.count) + 6
    }
}

/// A run of list items, drawn as whatever `NoteProse.shape` found it to be.
struct ProseList: View {
    let shape: NoteProse.ListShape
    let items: [(marker: String, text: AttributedString)]
    var baseSize: CGFloat = 13
    var color: Color = Instrument.body

    var body: some View {
        VStack(alignment: .leading, spacing: shape == .plain ? 5 : 0) {
            ForEach(items.indices, id: \.self) { index in
                row(items[index], index: index)
            }
        }
    }

    @ViewBuilder private func row(
        _ item: (marker: String, text: AttributedString), index: Int
    ) -> some View {
        switch shape {
        case .plain:
            BulletRow(marker: item.marker, text: item.text, baseSize: baseSize, color: color)
        case .pairs:
            let split = NoteProse.pairBreak(String(item.text.characters))
            Rule()
            PairRow(
                before: CardTextView.slice(item.text, from: 0, to: split?.head),
                // A row without an arrow (a heading put it in this shape) is a
                // problem still open: the fix column stays empty rather than
                // echoing the whole sentence.
                after: split.map { CardTextView.slice(item.text, from: $0.tail) }
                    ?? AttributedString(),
                baseSize: baseSize)
        case .claims:
            // A titled item splits at its label's colon; only prose without
            // one falls back to the clause break.
            let plain = String(item.text.characters)
            let split = NoteProse.labelBreak(plain) ?? NoteProse.claimBreak(plain)
            Rule()
            ClaimRow(
                index: index + 1,
                claim: CardTextView.slice(item.text, from: 0, to: split?.head),
                reason: split.map {
                    AttributedString($0.lead) + CardTextView.slice(item.text, from: $0.tail)
                },
                baseSize: baseSize)
        }
    }
}

/// One fenced code block: monospaced, selectable, on a recessive surface with
/// the language tag as a corner caption.
struct CodeBlockView: View {
    let code: String
    let language: String?
    var baseSize: CGFloat = 13

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let language, !language.isEmpty {
                Eyebrow(language, size: 9.5)
            }
            Text(code)
                .font(Instrument.mono(baseSize - 1))
                .textSelection(.enabled)
                .foregroundStyle(Instrument.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(Instrument.well, in: RoundedRectangle(cornerRadius: 6))
    }
}
