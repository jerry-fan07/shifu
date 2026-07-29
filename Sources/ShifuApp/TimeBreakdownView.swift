import Charts
import ShifuCore
import SwiftUI

/// The Time tab's *Summary* mode (design.md §7): where the window's time
/// actually went, Screen Time style — a hero total, a donut, and one ranked row
/// per group that expands into the apps and domains behind it.
///
/// The timeline's legend answers "which color is which"; this answers "how much
/// of my day was that", which is the question the legend kept being asked.
struct TimeBreakdownView: View {
    let slices: [TimeSlice]
    let lens: TimeLens
    /// Same-length window immediately before this one, for the delta line.
    let previousMs: Int64
    /// "today" / "this week".
    let periodLabel: String
    /// "yesterday" / "the previous 7 days".
    let comparisonLabel: String

    @State private var expanded: Set<String> = []

    private var total: Int64 { slices.reduce(0) { $0 + $1.ms } }

    var body: some View {
        if slices.isEmpty {
            SenseiEmptyState(
                "Nothing tracked \(periodLabel)",
                message: "The scroll is blank. Work a while — the analyzer "
                    + "passes hourly, and I keep the record.")
            // Greedy like the ScrollView it stands in for, so the page's
            // controls stay pinned to the top instead of centering with it.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    headline
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(slices) { row($0) }
                    }
                }
                .padding(.bottom, 8)
            }
        }
    }

    // MARK: - Headline

    private var headline: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Eyebrow("tracked \(periodLabel)")
                Text(TimeBreakdown.duration(total))
                    .font(Dojo.display(42))
                    .monospacedDigit()
                if let delta {
                    Label(delta.text, systemImage: delta.symbol)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Across \(lens.counted(slices.count))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            donut
        }
        .dojoCard(padding: 18)
    }

    private var donut: some View {
        Chart(slices) { slice in
            SectorMark(
                angle: .value("Time", slice.ms),
                innerRadius: .ratio(0.66),
                angularInset: 1.5
            )
            .cornerRadius(3)
            .foregroundStyle(slice.color)
        }
        .chartLegend(.hidden)
        .frame(width: 132, height: 132)
        // The hole carries the leader — the share the biggest group took.
        .overlay {
            if let top = slices.first {
                VStack(spacing: 0) {
                    Text(percent(top.share))
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(lens.display(top.name))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(width: 78)
            }
        }
        .accessibilityLabel("Share of tracked time by \(lens.rawValue.lowercased())")
    }

    /// Nil when there is nothing to compare against, or the change is noise.
    private var delta: (symbol: String, text: String)? {
        guard previousMs > 0, total > 0 else { return nil }
        let change = Double(total - previousMs) / Double(previousMs)
        guard abs(change) >= 0.01 else { return nil }
        let percent = Int((abs(change) * 100).rounded())
        return (change > 0 ? "arrow.up" : "arrow.down",
                "\(percent)% vs \(comparisonLabel)")
    }

    // MARK: - Ranked rows

    private func row(_ slice: TimeSlice) -> some View {
        let isOpen = expanded.contains(slice.id)
        return VStack(alignment: .leading, spacing: 7) {
            Button {
                if isOpen { expanded.remove(slice.id) } else { expanded.insert(slice.id) }
            } label: {
                HStack(spacing: 9) {
                    Circle()
                        .fill(slice.color)
                        .frame(width: 10, height: 10)
                    Text(lens.display(slice.name))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(TimeBreakdown.duration(slice.ms))
                        .monospacedDigit()
                    Text(percent(slice.share))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            bar(slice)

            if isOpen { inside(slice) }
        }
        .padding(.vertical, 7)
        .animation(.easeInOut(duration: 0.15), value: isOpen)
    }

    private func bar(_ slice: TimeSlice) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Dojo.well)
                Capsule()
                    .fill(slice.color)
                    // A hairline of track always shows, so a 0.4% group is
                    // still visibly a group rather than an empty rail.
                    .frame(width: max(4, proxy.size.width * slice.share))
            }
        }
        .frame(height: 7)
    }

    /// What the group was actually made of — the drill-down the old legend
    /// could not give.
    private func inside(_ slice: TimeSlice) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(slice.sources) { source in
                HStack(spacing: 6) {
                    Text(source.name)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(TimeBreakdown.duration(source.ms))
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Text(footnote(slice))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.leading, 19)
        .padding(.top, 2)
        .transition(.opacity)
    }

    private func footnote(_ slice: TimeSlice) -> String {
        var parts = ["\(slice.blocks) block\(slice.blocks == 1 ? "" : "s")"]
        if let peak = slice.peakHour {
            parts.append("busiest around \(TimeBreakdown.hourLabel(peak))")
        }
        return parts.joined(separator: " · ")
    }

    private func percent(_ share: Double) -> String {
        share > 0 && share < 0.01 ? "<1%" : "\(Int((share * 100).rounded()))%"
    }
}

/// The timeline's legend, replacing the Charts default: same colors, but each
/// entry also carries its total and share so the strip under the bars is
/// information rather than a color key.
struct TimeLegendStrip: View {
    let slices: [TimeSlice]
    let lens: TimeLens

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 260), spacing: 10)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(slices) { slice in
                HStack(spacing: 6) {
                    Circle()
                        .fill(slice.color)
                        .frame(width: 8, height: 8)
                    Text(lens.display(slice.name))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(TimeBreakdown.duration(slice.ms))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }
        }
    }
}
