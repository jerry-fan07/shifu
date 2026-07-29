import ShifuCore
import SwiftUI

/// GitHub-style calendar heatmap of reviews per day, last 26 weeks. One green
/// hue, light→dark with count (sequential ramp); zero-days sit on the
/// recessive surface. Tooltips carry the exact numbers.
struct ReviewHeatmapView: View {
    let counts: [Date: Int]
    var now: Date = Date()

    private static let cellSize: CGFloat = 12
    private static let gap: CGFloat = 3

    var body: some View {
        let weeks = weekStarts()
        VStack(alignment: .leading, spacing: 4) {
            monthLabels(weeks: weeks)
            HStack(alignment: .top, spacing: Self.gap) {
                weekdayLabels
                ForEach(weeks, id: \.self) { weekStart in
                    weekColumn(weekStart)
                }
            }
            legend
        }
    }

    /// Start of each displayed week, oldest first, current week last. Columns
    /// run Monday→Sunday like the rest of the app.
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
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(Self.rampColor(count))
                        .frame(width: Self.cellSize, height: Self.cellSize)
                        .help("\(count) review\(count == 1 ? "" : "s") · "
                            + day.formatted(.dateTime.month(.abbreviated).day()))
                } else {
                    Color.clear
                        .frame(width: Self.cellSize, height: Self.cellSize)
                }
            }
        }
    }

    /// Month abbreviation over each column that starts a new month; labels
    /// overflow their column like GitHub's.
    private func monthLabels(weeks: [Date]) -> some View {
        let calendar = Calendar.current
        return HStack(alignment: .top, spacing: Self.gap) {
            Color.clear.frame(width: 26, height: 1)   // over the weekday gutter
            ForEach(Array(weeks.enumerated()), id: \.offset) { index, weekStart in
                let month = calendar.component(.month, from: weekStart)
                let previous = index > 0
                    ? calendar.component(.month, from: weeks[index - 1]) : 0
                ZStack(alignment: .topLeading) {
                    Color.clear.frame(width: Self.cellSize, height: 12)
                    if index > 0, month != previous {
                        Text(weekStart.formatted(.dateTime.month(.abbreviated)))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
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
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 23, height: Self.cellSize)
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 3) {
            Text("\(counts.values.reduce(0, +)) reviews in the last "
                + "\(LedgerStore.HeatmapSpan.weeks) weeks")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text("Less")
                .font(.caption2)
                .foregroundStyle(.secondary)
            ForEach([0, 1, 3, 6, 10], id: \.self) { step in
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(Self.rampColor(step))
                    .frame(width: 10, height: 10)
            }
            Text("More")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// Quantized sequential ramp: one hue, intensity tracks count, and it
    /// adapts to light/dark because it's an opacity over the surface.
    static func rampColor(_ count: Int) -> Color {
        switch count {
        case 0: return Color.primary.opacity(0.06)
        case 1...2: return .green.opacity(0.30)
        case 3...5: return .green.opacity(0.55)
        case 6...9: return .green.opacity(0.80)
        default: return .green
        }
    }
}
