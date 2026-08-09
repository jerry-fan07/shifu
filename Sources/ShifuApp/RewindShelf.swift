import ShifuCore
import SwiftUI

/// The saved-rewind shelf (design.md §3.6): what you kept, grouped by day, in
/// the same register as the Notes shelf — a name, where it came from, how long
/// it runs, and how long it has left.
///
/// Rewinds and snips share the table rather than splitting into two, because
/// they are the same act at two lengths: "what did I keep today" is one
/// question and should have one answer.
struct RewindShelf: View {
    let rewinds: [SavedRewind]
    let onOpen: (Int64) -> Void

    var body: some View {
        PageBody {
            if rewinds.isEmpty {
                BlankSlate("Nothing kept yet. Save a rewind from the menu bar or the "
                    + "button above, and it lands here — with its frames, for as long "
                    + "as the retention window in Settings.")
            } else {
                ForEach(groups, id: \.title) { group in
                    RewindDayHeading(title: group.title, rewinds: group.rewinds)
                    columnHead
                    ForEach(group.rewinds) { rewind in
                        RewindShelfRow(rewind: rewind) { onOpen(rewind.id ?? 0) }
                        Rule(weight: .row)
                    }
                }
                QuietLine {
                    Text("Rewinds older than the retention window are deleted with their "
                        + "frames — nothing survives as a thumbnail.")
                }
            }
        }
    }

    private var columnHead: some View {
        ColumnHead {
            Text("Rewind").frame(maxWidth: .infinity, alignment: .leading)
            Text("Where it came from").frame(width: 210, alignment: .leading)
            Text("Span").frame(width: 78, alignment: .trailing)
            Text("Kept until").frame(width: 96, alignment: .trailing)
        }
    }

    /// Grouped by local day, newest first, with the day's own totals in the
    /// heading — the shelf's units are days because that is how you remember
    /// having kept something.
    private var groups: [(title: String, rewinds: [SavedRewind])] {
        let calendar = Calendar.current
        var order: [Date] = []
        var byDay: [Date: [SavedRewind]] = [:]
        for rewind in rewinds {
            let day = calendar.startOfDay(
                for: Date(timeIntervalSince1970: Double(rewind.createdAt) / 1_000))
            if byDay[day] == nil { order.append(day) }
            byDay[day, default: []].append(rewind)
        }
        return order.sorted(by: >).map { day in
            (title: Self.dayTitle(day, calendar: calendar), rewinds: byDay[day] ?? [])
        }
    }

    static func dayTitle(_ day: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
    }
}

/// A day's heading: the date, a rule to the right of it, and what that day
/// costs on disk.
struct RewindDayHeading: View {
    let title: String
    let rewinds: [SavedRewind]

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Eyebrow(title, size: 10.5, tracking: 1.1)
            Rectangle()
                .fill(Instrument.hairline)
                .frame(height: 1)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 4 }
            Figure(
                "\(rewinds.count) kept · \(RewindTransport.megabytes(bytes))",
                size: 10.5, color: Instrument.ghost)
        }
        .padding(.top, 18)
        .padding(.bottom, 4)
    }

    private var bytes: Int64 { rewinds.reduce(0) { $0 + $1.bytes } }
}

/// One row of the shelf.
struct RewindShelfRow: View {
    let rewind: SavedRewind
    let onOpen: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(rewind.title)
                        .font(Instrument.sans(13, .medium))
                        .foregroundStyle(Instrument.ink)
                    if let note = rewind.note, !note.isEmpty {
                        Text(note)
                            .font(Instrument.sans(12.5))
                            .foregroundStyle(Instrument.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    Tag(
                        rewind.kind == .rewind ? "rewind" : "frame",
                        tinted: rewind.kind == .rewind,
                        dashed: rewind.kind == .snip)
                    if let path = rewind.notePath {
                        Text(path)
                            .font(Instrument.sans(11))
                            .foregroundStyle(Instrument.ghost)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                .frame(width: 210, alignment: .leading)

                Figure(span, size: 11, color: Instrument.faint)
                    .frame(width: 78, alignment: .trailing)
                Figure(kept, size: 11, color: keptColor)
                    .frame(width: 96, alignment: .trailing)
            }
            .padding(.vertical, 9)
            .background(hovering ? Instrument.rowTint : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var span: String {
        rewind.kind == .snip ? "—" : TimeBreakdown.duration(rewind.durationMs)
    }

    /// How long it has left, in days — the unit the retention dial is in. A
    /// kept-forever rewind says so rather than printing a date far away.
    private var kept: String {
        guard let expires = rewind.expiresAt else { return "kept" }
        let days = Int(
            (Double(expires) / 1_000 - Date().timeIntervalSince1970) / 86_400)
        if days <= 0 { return "today" }
        return days == 1 ? "1 day" : "\(days) days"
    }

    private var keptColor: Color {
        guard let expires = rewind.expiresAt else { return Instrument.faint }
        let days = (Double(expires) / 1_000 - Date().timeIntervalSince1970) / 86_400
        return days <= 7 ? Instrument.alert : Instrument.faint
    }
}
