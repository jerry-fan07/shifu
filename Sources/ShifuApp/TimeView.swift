import Charts
import ShifuCore
import SwiftUI

/// The *Time* page: two modes over the same window (design.md §7).
/// *Summary* answers "where did my time go" — a Screen Time–style ranked
/// breakdown; *Timeline* answers "when" — the stacked bars and the block list.
/// A day/week span and a lens (category, theme, or task — §5.3) apply to both;
/// all three controls live in the window toolbar.
struct TimeView: View {
    enum Span: String, CaseIterable { case day = "Day", week = "Week" }
    enum Mode: String, CaseIterable { case summary = "Summary", timeline = "Timeline" }

    @EnvironmentObject private var store: LedgerStore
    @State private var span: Span = .day
    @State private var lens: TimeLens = .category
    @State private var mode: Mode = .summary

    /// Theme/task lenses collapse everything beyond the biggest N groups into
    /// "Other", so the breakdown and the legend stay readable over a busy week.
    static let maxGroups = 7

    var body: some View {
        // One read per body pass, shared by the chart, the breakdown, and the
        // block list — each used to open its own query.
        let (from, to) = range
        let activities = store.labeledActivities(from: from, to: to)
        let slices = TimeBreakdown.slices(
            activities, lens: lens, from: from, to: to,
            limit: lens == .category ? nil : Self.maxGroups)

        return VStack(alignment: .leading, spacing: 16) {
            switch mode {
            case .summary:
                TimeBreakdownView(
                    slices: slices, lens: lens,
                    previousMs: previousTotalMs,
                    periodLabel: span == .day ? "today" : "this week",
                    comparisonLabel: span == .day ? "yesterday" : "last week")
            case .timeline:
                timeline(activities: activities, slices: slices)
            }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 500)
        .background(Dojo.paper)
        .navigationTitle("Time")
        .toolbar {
            ToolbarItemGroup {
                Picker("Mode", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .help("Where the time went, or when it happened")
                Picker("Span", selection: $span) {
                    ForEach(Span.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                Picker("Lens", selection: $lens) {
                    ForEach(TimeLens.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .help("What the time is grouped by")
            }
        }
        .onAppear { store.refresh() }
    }

    @ViewBuilder
    private func timeline(
        activities: [LedgerBuilder.LabeledActivity], slices: [TimeSlice]
    ) -> some View {
        chart(activities: activities, slices: slices)
            .frame(minHeight: 200)
        if !slices.isEmpty {
            TimeLegendStrip(slices: slices, lens: lens)
        }

        Divider()

        Text(span == .day ? "Blocks today" : "Blocks this week")
            .font(.headline)
        blockList(activities)
    }

    private var range: (from: Date, to: Date) {
        let cal = Calendar.current
        let now = Date()
        switch span {
        case .day:
            return (cal.startOfDay(for: now), now)
        case .week:
            return (cal.startOfWeek(for: now), now)
        }
    }

    /// Tracked time over the same-length window immediately before this one —
    /// yesterday up to this hour, or last week up to this weekday. Read lazily:
    /// only the Summary mode's delta line asks for it.
    private var previousTotalMs: Int64 {
        let (from, to) = range
        let shift = span == .day ? -1 : -7
        let cal = Calendar.current
        guard let previousFrom = cal.date(byAdding: .day, value: shift, to: from),
              let previousTo = cal.date(byAdding: .day, value: shift, to: to)
        else { return 0 }
        return TimeBreakdown.total(
            store.labeledActivities(from: previousFrom, to: previousTo),
            from: previousFrom, to: previousTo)
    }

    private struct Bucket: Identifiable {
        let id = UUID()
        let label: String
        let group: String
        let hours: Double
        let order: Int
    }

    /// The same buckets the bars are stacked from, folded into the groups the
    /// breakdown already ranked (so both modes agree on what "Other" holds).
    private func buckets(
        _ activities: [LedgerBuilder.LabeledActivity], groups: Set<String>
    ) -> [Bucket] {
        let (from, to) = range
        let cal = Calendar.current
        let dayZero = cal.startOfDay(for: from)
        // bucket label → (chronological order, group → ms)
        var sums: [String: (order: Int, byGroup: [String: Int64])] = [:]
        for activity in activities {
            let raw = lens.label(activity)
            let group = groups.contains(raw) ? raw : TimeBreakdown.otherLabel
            let start = Date(timeIntervalSince1970: Double(activity.startedAt) / 1_000)
            var cursor = max(start, from)
            let end = min(Date(timeIntervalSince1970: Double(activity.endedAt) / 1_000), to)
            while cursor < end {
                let bucketEnd: Date
                let label: String
                let order: Int
                switch span {
                case .day:
                    let hour = cal.component(.hour, from: cursor)
                    label = String(format: "%02d", hour)
                    order = hour
                    bucketEnd = cal.date(
                        bySettingHour: hour, minute: 59, second: 59, of: cursor)!
                        .addingTimeInterval(1)
                case .week:
                    label = cursor.formatted(.dateTime.weekday(.abbreviated))
                    order = cal.dateComponents(
                        [.day], from: dayZero, to: cal.startOfDay(for: cursor)).day ?? 0
                    bucketEnd = cal.startOfDay(for: cursor).addingTimeInterval(86_400)
                }
                let slice = min(end, bucketEnd).timeIntervalSince(cursor)
                var entry = sums[label] ?? (order: order, byGroup: [:])
                entry.byGroup[group, default: 0] += Int64(slice * 1_000)
                sums[label] = entry
                cursor = bucketEnd
            }
        }
        return sums.flatMap { label, entry in
            entry.byGroup.map { group, ms in
                Bucket(label: label, group: group, hours: Double(ms) / 3_600_000,
                       order: entry.order)
            }
        }
        .sorted { $0.order < $1.order }
    }

    @ViewBuilder
    private func chart(
        activities: [LedgerBuilder.LabeledActivity], slices: [TimeSlice]
    ) -> some View {
        let data = buckets(activities, groups: Set(slices.map(\.name)))
        if data.isEmpty {
            SenseiEmptyState(
                "No activity yet",
                message: "The analyzer runs hourly. The record fills in once "
                    + "shifud has been watching a while.")
        } else {
            barChart(data)
                // Explicit domain + range rather than Charts' automatic palette:
                // the bars, the legend strip, and the Summary donut have to name
                // the same color for the same group.
                .chartForegroundStyleScale(
                    domain: slices.map(\.name), range: slices.map(\.color))
        }
    }

    private func barChart(_ data: [Bucket]) -> some View {
        let domain = bucketDomain
        return GeometryReader { proxy in
            Chart(data) { bucket in
                BarMark(
                    x: .value(span == .day ? "Hour" : "Day", bucket.label),
                    y: .value("Hours", bucket.hours)
                )
                .foregroundStyle(by: .value(lens.rawValue, bucket.group))
            }
            .chartLegend(.hidden)   // replaced by TimeLegendStrip, which carries totals
            .chartXScale(domain: domain)
            .chartXAxis {
                AxisMarks(values: axisLabels(in: domain, width: proxy.size.width)) {
                    AxisGridLine()
                    AxisTick()
                    // Charts otherwise squeezes each label into its own bar's
                    // width and ellipsises it; we've already thinned for space.
                    AxisValueLabel(collisionResolution: .disabled)
                }
            }
        }
    }

    /// Every bucket the span *covers*, in order — 00…23 for a day, Mon…Sun for a
    /// week — rather than only the ones the data happened to fill. Pinning the x
    /// scale to this keeps an idle hour, an untracked Wednesday, and the days of
    /// the week still to come as gaps on the axis instead of letting the chart
    /// close up around them (§7).
    private var bucketDomain: [String] {
        let cal = Calendar.current
        switch span {
        case .day:
            return (0..<24).map { String(format: "%02d", $0) }
        case .week:
            return (0..<7).compactMap { offset in
                cal.date(byAdding: .day, value: offset, to: range.from)?
                    .formatted(.dateTime.weekday(.abbreviated))
            }
        }
    }

    /// Every bucket gets a label while they fit; past that, every *n*th one. Without
    /// this the axis truncates to "…" as soon as the window narrows (§7).
    private func axisLabels(in labels: [String], width: CGFloat) -> [String] {
        guard !labels.isEmpty, width > 0 else { return labels }
        let perLabel: CGFloat = span == .day ? 25 : 46   // widest label plus breathing room
        let room = max(1, Int(width / perLabel))
        let step = max(1, Int((Double(labels.count) / Double(room)).rounded(.up)))
        return labels.enumerated().compactMap { $0.offset.isMultiple(of: step) ? $0.element : nil }
    }

    private func blockList(_ activities: [LedgerBuilder.LabeledActivity]) -> some View {
        List(activities.sorted { $0.startedAt > $1.startedAt }, id: \.id) { activity in
            HStack {
                Text(Date(timeIntervalSince1970: Double(activity.startedAt) / 1_000),
                     format: .dateTime.hour().minute())
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text(lens == .category ? activity.source : lens.label(activity))
                    .lineLimit(1)
                if lens != .category {
                    Text(activity.source)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer()
                Text(LedgerStore.hours(activity.durationMs))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text(activity.category)
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Dojo.well, in: Capsule())
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }
}
