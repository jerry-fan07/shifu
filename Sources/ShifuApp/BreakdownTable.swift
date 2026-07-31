import SwiftUI

/// The Breakdown's ranked rows, owning the hover state. Scoped here so a row
/// lighting up re-evaluates these rows and nothing above them: when `hovered`
/// lived on LedgerView, every crossing re-ran the whole page's body — ribbons,
/// head, previous-window read and all — at ~70–120 ms a step on a dogfood
/// ledger, and an ordinary sweep down the table pinned a full core.
struct BreakdownTable: View {
    let slices: [TimeSlice]
    let lens: TimeLens

    /// Which group's apps are showing. Hover reveals them inline rather than
    /// opening a row, so scanning the table never costs a click.
    @State private var hovered: String?

    var body: some View {
        ForEach(slices) { slice in
            groupRow(slice)
        }
    }

    private func groupRow(_ slice: TimeSlice) -> some View {
        let isPrivate = slice.name == "private"
        let isOpen = hovered == slice.id && !slice.sources.isEmpty
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                HStack(spacing: 9) {
                    SeriesSwatch(color: slice.color, hatched: isPrivate)
                    Text(lens.display(slice.name))
                        .font(Instrument.sans(13, isOpen ? .medium : .regular))
                        .foregroundStyle(isPrivate ? Instrument.muted : Instrument.ink)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Figure(
                    TimeBreakdown.duration(slice.ms),
                    color: isPrivate ? Instrument.muted : Instrument.ink)
                    .frame(width: 76, alignment: .trailing)
                Figure(percent(slice.share), color: isPrivate ? Instrument.ghost : Instrument.muted)
                    .frame(width: 54, alignment: .trailing)
                Group {
                    if isPrivate {
                        Text("never read")
                            .font(Instrument.sans(11))
                            .foregroundStyle(Instrument.ghost)
                    } else {
                        Meter(share: slice.share, color: slice.color)
                    }
                }
                .frame(width: 148, alignment: .leading)
            }
            .padding(.vertical, 7)
            if isOpen { sources(slice) }
            Rule()
        }
        .background(isOpen ? Instrument.rowTint : Color.clear)
        .contentShape(Rectangle())
        .onHover { inside in
            hovered = inside ? slice.id : (hovered == slice.id ? nil : hovered)
        }
    }

    /// What the group was actually made of. Inline on hover — the drill-down a
    /// legend could never give, at no cost to the scan.
    private func sources(_ slice: TimeSlice) -> some View {
        HStack(spacing: 18) {
            ForEach(slice.sources) { source in
                Figure(
                    "\(source.name) \(TimeBreakdown.duration(source.ms))",
                    size: 11, color: Instrument.faint)
            }
            if slice.sourceCount > slice.sources.count {
                Figure(
                    "+\(slice.sourceCount - slice.sources.count) more",
                    size: 11, color: Instrument.ghost)
            }
        }
        .padding(.leading, 18)
        .padding(.bottom, 9)
    }

    private func percent(_ share: Double) -> String {
        share > 0 && share < 0.01 ? "<1%" : "\(Int((share * 100).rounded()))%"
    }
}
