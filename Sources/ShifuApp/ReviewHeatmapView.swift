import ShifuCore
import SwiftUI

/// Calendar heatmap of reviews per day, last 26 weeks. One hue — the accent —
/// stepped light→dark with the count, over the same recessed track every other
/// meter in the app uses. Its own header carries the total, because a grid of
/// squares with no number on it is decoration.
struct ReviewHeatmapView: View {
    let counts: [Date: Int]
    var now: Date = Date()

    private static let cell: CGFloat = 10
    private static let gap: CGFloat = 3
    private static let gutter: CGFloat = 24

    var body: some View {
        let weeks = weekStarts()
        VStack(alignment: .leading, spacing: 8) {
            header
            VStack(alignment: .leading, spacing: 4) {
                monthLabels(weeks: weeks)
                HStack(alignment: .top, spacing: Self.gap) {
                    weekdayLabels
                    ForEach(weeks, id: \.self) { weekStart in
                        weekColumn(weekStart)
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack {
            Eyebrow(
                "Reviews · \(LedgerStore.HeatmapSpan.weeks) weeks · "
                    + "\(counts.values.reduce(0, +)) total")
            Spacer()
            HStack(spacing: 4) {
                Text("less")
                    .font(Instrument.mono(10))
                    .foregroundStyle(Instrument.ghost)
                ForEach([0, 1, 3, 6, 10], id: \.self) { step in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Self.ramp(step))
                        .frame(width: Self.cell, height: Self.cell)
                }
                Text("more")
                    .font(Instrument.mono(10))
                    .foregroundStyle(Instrument.ghost)
            }
        }
    }

    /// Start of each displayed week, oldest first. Columns run Monday→Sunday
    /// like the rest of the app.
    private func weekStarts() -> [Date] {
        let calendar = Calendar.current
        let thisWeek = calendar.startOfWeek(for: now)
        return (0..<LedgerStore.HeatmapSpan.weeks).compactMap { offset in
            calendar.date(
                byAdding: .weekOfYear,
                value: offset - (LedgerStore.HeatmapSpan.weeks - 1),
                to: thisWeek)
        }
    }

    private func weekColumn(_ weekStart: Date) -> some View {
        let calendar = Calendar.current
        return VStack(spacing: Self.gap) {
            ForEach(0..<7, id: \.self) { dayOffset in
                if let day = calendar.date(byAdding: .day, value: dayOffset, to: weekStart),
                   day <= now {
                    let count = counts[calendar.startOfDay(for: day)] ?? 0
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Self.ramp(count))
                        .frame(width: Self.cell, height: Self.cell)
                        .help("\(count) review\(count == 1 ? "" : "s") · "
                            + day.formatted(.dateTime.month(.abbreviated).day()))
                } else {
                    Color.clear.frame(width: Self.cell, height: Self.cell)
                }
            }
        }
    }

    /// Month abbreviation over each column that starts a new month; labels
    /// overflow their column rather than squeeze it.
    private func monthLabels(weeks: [Date]) -> some View {
        let calendar = Calendar.current
        return HStack(alignment: .top, spacing: Self.gap) {
            Color.clear.frame(width: Self.gutter, height: 1)
            ForEach(Array(weeks.enumerated()), id: \.offset) { index, weekStart in
                let month = calendar.component(.month, from: weekStart)
                let previous = index > 0
                    ? calendar.component(.month, from: weeks[index - 1]) : 0
                ZStack(alignment: .topLeading) {
                    Color.clear.frame(width: Self.cell, height: 11)
                    if index > 0, month != previous {
                        Text(weekStart.formatted(.dateTime.month(.abbreviated)))
                            .font(Instrument.mono(10))
                            .foregroundStyle(Instrument.ghost)
                            .fixedSize()
                    }
                }
            }
        }
    }

    private var weekdayLabels: some View {
        let calendar = Calendar.current.mondayFirst
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        return VStack(spacing: Self.gap) {
            // Every other row, so the labels don't crowd: Mon, Wed, Fri.
            ForEach(0..<7, id: \.self) { row in
                Text(row.isMultiple(of: 2)
                     ? symbols[(calendar.firstWeekday - 1 + row) % 7] : "")
                    .font(Instrument.mono(10))
                    .foregroundStyle(Instrument.ghost)
                    .frame(width: Self.gutter - Self.gap, height: Self.cell)
            }
        }
    }

    /// Quantized sequential ramp: one hue, intensity tracks the count, and it
    /// adapts to light and dark because it is an opacity over the same well
    /// every meter sits in.
    static func ramp(_ count: Int) -> Color {
        switch count {
        case 0: return Instrument.well
        case 1...2: return Instrument.accent.opacity(0.28)
        case 3...5: return Instrument.accent.opacity(0.5)
        case 6...9: return Instrument.accent.opacity(0.72)
        default: return Instrument.accent
        }
    }
}
