import ShifuCore
import SwiftUI

/// One day of a task, unrolled from its work note.
///
/// Nothing here is a new fact. The title is the summary line's second half,
/// the chips are its first, the rail is the `sessions:` front matter to scale,
/// the sections and their names are the note's own `###` headings, and the
/// tables are the shape the bullets were already written in. A day note is a
/// document the analyzer wrote once; this is the reading of it, and every mark
/// on the page can be pointed back at a line in the file.
///
/// Hovering a stretch lights the part of the rail it covers — the one thing the
/// page adds, and only because "which part of the day was that?" is otherwise
/// unanswerable from prose that merged three stretches into one lead.
struct DayHistoryRow: View {
    @EnvironmentObject private var store: LedgerStore
    @EnvironmentObject private var router: Router
    let day: TaskStore.DayRow
    let taskKey: String
    var startsOpen = false

    @State private var reading: DayReading?
    @State private var loaded = false
    @State private var active: String?

    /// The date column — and, under it, the column the spans hang in, so the
    /// day and its stretches are read down one edge.
    private static let column: CGFloat = 96
    private static let baseSize: CGFloat = 12.5
    /// ~95 characters at this size: as wide as prose can be and still be read
    /// line after line.
    private static let measure: CGFloat = 660
    private static var content: CGFloat { SessionRail.contentInset(gutter: column) }

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { expanded.toggle() } label: {
                head.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Only once the note has been read: an expanded row with nothing
            // in it yet is a blank gap the eye reads as a rendering fault.
            if expanded, loaded { unrolled }
        }
        .onAppear {
            guard startsOpen, !expanded else { return }
            expanded = true
            // Read in the appearing pass, with the page's own reads: this row
            // is the reason the page was opened, and a note that arrives a
            // turn later arrives after everything that could photograph it.
            readNote()
        }
        .onChange(of: expanded) { _, isOpen in
            guard isOpen, !loaded else { return }
            // A click, though, can land mid-layout, and reading there would
            // republish state the enclosing stack is still laying out.
            DispatchQueue.main.async { readNote() }
        }
    }

    private func readNote() {
        guard !loaded else { return }
        let note = store.workNote(dayStart: day.dayStart, taskKey: taskKey)
        reading = note.map { DayReading($0, links: store.linked($0.capturedLinks)) }
        loaded = true
    }

    private var dateLabel: String {
        Date(timeIntervalSince1970: Double(day.dayStart) / 1_000)
            .formatted(.dateTime.weekday(.abbreviated).day().month())
    }

    // MARK: - The head

    @ViewBuilder private var head: some View {
        if expanded, let reading {
            openHead(reading)
        } else {
            closedHead
        }
    }

    /// A day in the list: one line, and the two figures that decide whether to
    /// open it. The line is the summary's *what* — the sources half is chips on
    /// the open head, and a closed row that leads with "app, ghostty —" spends
    /// its one line naming windows instead of intent.
    private var closedTitle: String {
        let title = NoteProse.dayTitle(day.summary)
        return title.isEmpty ? day.summary : title
    }

    private var closedHead: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Figure(dateLabel, color: Instrument.faint)
                .frame(width: Self.column, alignment: .leading)
            Text(closedTitle)
                .font(Instrument.sans(Self.baseSize))
                .foregroundStyle(Instrument.body)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Figure(TimeBreakdown.duration(day.durationMs), color: Instrument.muted)
                .frame(width: 72, alignment: .trailing)
        }
        .padding(.vertical, 6)
    }

    /// A day opened: what it was about, where it was spent, and the three
    /// figures that are not the same fact — how long, in how many sittings,
    /// between which two clock times.
    private func openHead(_ reading: DayReading) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Figure(dateLabel, color: Instrument.ink)
                .frame(width: Self.column, alignment: .leading)
                .padding(.trailing, Self.content - Self.column - 16)
            VStack(alignment: .leading, spacing: 8) {
                if !reading.title.isEmpty {
                    Text(reading.title)
                        .font(Instrument.sans(15, .semibold))
                        .tracking(-0.15)
                        .foregroundStyle(Instrument.ink)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !reading.sources.isEmpty {
                    FlowRow(spacing: 5, lineSpacing: 4) {
                        ForEach(reading.sources, id: \.self) { SourceChip(name: $0) }
                    }
                }
            }
            .frame(maxWidth: Self.measure, alignment: .leading)
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 2) {
                Figure(TimeBreakdown.duration(day.durationMs), size: 15, color: Instrument.ink)
                if !reading.spans.isEmpty {
                    Figure(
                        "\(reading.spans.count) session\(reading.spans.count == 1 ? "" : "s")",
                        size: 10.5, color: Instrument.faint)
                }
                if let bracket = reading.bracket {
                    Figure(bracket, size: 10.5, color: Instrument.ghost)
                }
            }
        }
        .padding(.top, 12)
        .padding(.bottom, 2)
    }

    // MARK: - The day itself

    @ViewBuilder private var unrolled: some View {
        if let reading {
            VStack(alignment: .leading, spacing: 0) {
                if !reading.spans.isEmpty {
                    DayRibbon(spans: reading.spans, highlight: highlight)
                        .frame(maxWidth: Self.measure)
                        .padding(.leading, Self.content)
                        .padding(.top, 12)
                }
                ForEach(reading.blocks) { block in
                    stretch(block)
                }
                if !reading.blocks.isEmpty {
                    Rule().padding(.leading, Self.content)
                }
                if let detail = reading.detail, !detail.isEmpty {
                    CardTextView(text: detail, baseSize: Self.baseSize)
                        .frame(maxWidth: Self.measure, alignment: .leading)
                        .padding(.leading, Self.content)
                        .padding(.top, 16)
                }
                captured(reading)
            }
            .padding(.bottom, 16)
        } else if loaded {
            Text("No work note for this day.")
                .font(Instrument.sans(Self.baseSize))
                .foregroundStyle(Instrument.ghost)
                .padding(.leading, Self.content)
                .padding(.bottom, 10)
        }
    }

    /// Hovering a stretch answers "which part of the day was that?" three ways
    /// at once: its rail and span darken, the rail above keeps only its
    /// minutes lit, and the *other* stretches' prose recedes — the same
    /// linked-dimming the ledger's bands use, so one gesture reads as one
    /// question everywhere.
    private func stretch(_ block: NoteProse.SessionBlock) -> some View {
        SessionRow(
            span: block.span.label,
            detail: "\(max(block.covers.count, 1)) "
                + (block.covers.count > 1 ? "sessions" : "session"),
            isActive: active == block.id,
            gutter: Self.column, baseSize: Self.baseSize
        ) {
            CardTextView(
                text: block.text, baseSize: Self.baseSize,
                color: active == nil || active == block.id
                    ? Instrument.body : Instrument.faint)
                .frame(maxWidth: Self.measure, alignment: .leading)
        }
        .padding(.top, 12)
        .padding(.bottom, 4)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { active = block.id } else if active == block.id { active = nil }
        }
    }

    /// The minutes the hovered stretch covers, for the rail above to dim
    /// everything else by.
    private var highlight: Range<Int>? {
        guard let active,
              let block = reading?.blocks.first(where: { $0.id == active })
        else { return nil }
        return block.span.minutes
    }

    @ViewBuilder private func captured(_ reading: DayReading) -> some View {
        if !reading.captured.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                // The note's own `## Captured` heading, so it wears the same
                // accent the in-body section names do.
                Eyebrow("Captured", color: Instrument.accentText)
                FlowRow {
                    ForEach(reading.captured) { link in
                        LinkChip(
                            target: link.target,
                            action: link.noteID.map { noteID in
                                { router.open(.note(noteID)) }
                            })
                    }
                }
            }
            .frame(maxWidth: Self.measure, alignment: .leading)
            .padding(.leading, Self.content)
            .padding(.top, 20)
        }
    }
}

/// A work note read as a day, parsed once when the row opens.
///
/// Once, and not in `body`, because hovering a stretch re-renders this subtree
/// — and re-parsing a day's Markdown on every mouse move is the difference
/// between a highlight and a stutter.
struct DayReading {
    struct Capture: Identifiable {
        var target: String
        /// Nil when the vault has nothing indexed under that title: a note may
        /// name a page that was never written, and the link is still a fact
        /// about the day.
        var noteID: String?

        var id: String { target }
    }

    var title: String
    var sources: [String]
    var spans: [NoteProse.Span]
    var bracket: String?
    var blocks: [NoteProse.SessionBlock]
    var detail: String?
    var captured: [Capture]

    init(_ note: WorkNote, links: [String: String] = [:]) {
        title = NoteProse.dayTitle(note.summary, sources: note.sources)
        sources = note.sources
        spans = note.sessions.map { NoteProse.Span(start: $0.start, end: $0.end) }
        bracket = NoteProse.bracket(spans)
        blocks = NoteProse.sessionBlocks(note.sessionsProse ?? "", covering: spans)
        detail = note.detailProse
        captured = note.capturedLinks.map { Capture(target: $0, noteID: links[$0]) }
    }
}
