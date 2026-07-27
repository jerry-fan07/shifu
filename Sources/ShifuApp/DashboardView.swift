import Charts
import ShifuCore
import SwiftUI

/// Dashboard (design.md §7): *Time*, *Vault*, *Cards*, and *Radar* tabs.
/// Shows onboarding instead until the first-run flow completes.
struct DashboardView: View {
    enum Tab: String, CaseIterable { case time = "Time", vault = "Vault", cards = "Cards", radar = "Radar" }

    @AppStorage("shifu.onboarded") private var onboarded = false
    @State private var tab: Tab = .time

    var body: some View {
        if onboarded {
            dashboard
        } else {
            OnboardingView()
        }
    }

    private var dashboard: some View {
        content
            .frame(minWidth: 680, minHeight: 580)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    DashboardTabBar(tab: $tab)
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .time: TimeTabView()
        case .vault: VaultTabView()
        case .cards: CardsTabView()
        case .radar: RadarTabView()
        }
    }
}

/// Equal-width segmented control for the dashboard's top bar. Built by hand
/// (rather than a `Picker`) so every label gets the same width — the native
/// segmented style sizes each segment to its own text, which is what made
/// the titlebar tab strip look unevenly spaced.
private struct DashboardTabBar: View {
    @Binding var tab: DashboardView.Tab

    var body: some View {
        HStack(spacing: 2) {
            ForEach(DashboardView.Tab.allCases, id: \.self) { item in
                Button {
                    tab = item
                } label: {
                    Text(item.rawValue)
                        .font(.system(size: 13, weight: .medium))
                        .frame(minWidth: 64)
                        .padding(.vertical, 5)
                }
                .buttonStyle(.plain)
                .foregroundStyle(tab == item ? Color.primary : Color.secondary)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(tab == item ? Color.primary.opacity(0.12) : Color.clear)
                )
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
    }
}

/// *Time* tab: stacked bars, day/week toggle, block drill-down. A second
/// segmented lens picks what the stacks break down by — category, theme, or
/// task (design.md §7, §5.3). System fonts and colors throughout (§7).
struct TimeTabView: View {
    enum Span: String, CaseIterable { case day = "Day", week = "Week" }
    enum Lens: String, CaseIterable {
        case category = "Category"
        case theme = "Theme"
        case task = "Task"
    }

    @EnvironmentObject private var store: LedgerStore
    @State private var span: Span = .day
    @State private var lens: Lens = .category

    static let categoryColors: KeyValuePairs<String, Color> = [
        "work": .blue, "learning": .green, "entertainment": .orange,
        "social": .pink, "communication": .teal, "admin": .gray,
        "private": .secondary, "unclassified": Color.gray.opacity(0.4)
    ]
    /// Theme/task lenses collapse everything beyond the biggest N groups into
    /// "Other", so the legend stays readable over a busy week.
    static let maxGroups = 7

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Picker("", selection: $span) {
                    ForEach(Span.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
                Picker("", selection: $lens) {
                    ForEach(Lens.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .frame(width: 240)
                .help("What the bars break down by")
            }

            chart
                .frame(minHeight: 220)

            Divider()

            Text(span == .day ? "Blocks today" : "Blocks this week")
                .font(.headline)
            blockList
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 560)
        .onAppear { store.refresh() }
    }

    private var range: (from: Date, to: Date) {
        let cal = Calendar.current
        let now = Date()
        switch span {
        case .day:
            return (cal.startOfDay(for: now), now)
        case .week:
            let start = cal.date(byAdding: .day, value: -6, to: cal.startOfDay(for: now))!
            return (start, now)
        }
    }

    private struct Bucket: Identifiable {
        let id = UUID()
        let label: String
        let group: String
        let hours: Double
    }

    /// The lens's label for one activity.
    private func groupLabel(_ activity: LedgerBuilder.LabeledActivity) -> String {
        switch lens {
        case .category: return activity.category
        case .theme: return activity.themeName ?? "No theme"
        case .task: return activity.taskName ?? "No task"
        }
    }

    /// The biggest groups by total time in the window (theme/task lenses);
    /// everything else collapses into "Other".
    private func topGroups(_ activities: [LedgerBuilder.LabeledActivity]) -> Set<String> {
        guard lens != .category else { return [] }
        var totals: [String: Int64] = [:]
        for activity in activities {
            totals[groupLabel(activity), default: 0] += activity.durationMs
        }
        return Set(totals.sorted { $0.value > $1.value }
            .prefix(Self.maxGroups).map(\.key))
    }

    private var buckets: [Bucket] {
        let (from, to) = range
        let activities = store.labeledActivities(from: from, to: to)
        let top = topGroups(activities)
        let cal = Calendar.current
        // (bucket label, group) → ms
        var sums: [String: [String: Int64]] = [:]
        for activity in activities {
            let raw = groupLabel(activity)
            let group = lens == .category || top.contains(raw) ? raw : "Other"
            let start = Date(timeIntervalSince1970: Double(activity.startedAt) / 1_000)
            var cursor = max(start, from)
            let end = min(Date(timeIntervalSince1970: Double(activity.endedAt) / 1_000), to)
            while cursor < end {
                let bucketEnd: Date
                let label: String
                switch span {
                case .day:
                    let hour = cal.component(.hour, from: cursor)
                    label = String(format: "%02d", hour)
                    bucketEnd = cal.date(
                        bySettingHour: hour, minute: 59, second: 59, of: cursor)!
                        .addingTimeInterval(1)
                case .week:
                    label = cursor.formatted(.dateTime.weekday(.abbreviated))
                    bucketEnd = cal.startOfDay(for: cursor).addingTimeInterval(86_400)
                }
                let slice = min(end, bucketEnd).timeIntervalSince(cursor)
                sums[label, default: [:]][group, default: 0] += Int64(slice * 1_000)
                cursor = bucketEnd
            }
        }
        return sums.flatMap { label, byGroup in
            byGroup.map { group, ms in
                Bucket(label: label, group: group, hours: Double(ms) / 3_600_000)
            }
        }
        .sorted { $0.label < $1.label }
    }

    @ViewBuilder private var chart: some View {
        let data = buckets
        if data.isEmpty {
            ContentUnavailableView(
                "No activity yet",
                systemImage: "chart.bar",
                description: Text("The analyzer runs hourly. Data appears once shifud has been watching for a while.")
            )
        } else if lens == .category {
            barChart(data)
                .chartForegroundStyleScale(Self.categoryColors)
        } else {
            barChart(data)   // themes/tasks: automatic palette, top-N + Other
        }
    }

    private func barChart(_ data: [Bucket]) -> some View {
        Chart(data) { bucket in
            BarMark(
                x: .value(span == .day ? "Hour" : "Day", bucket.label),
                y: .value("Hours", bucket.hours)
            )
            .foregroundStyle(by: .value(lens.rawValue, bucket.group))
        }
    }

    private var blockList: some View {
        let (from, to) = range
        let activities = store.labeledActivities(from: from, to: to)
            .sorted { $0.startedAt > $1.startedAt }
        return List(activities, id: \.id) { activity in
            HStack {
                Text(Date(timeIntervalSince1970: Double(activity.startedAt) / 1_000),
                     format: .dateTime.hour().minute())
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text(lens == .category ? activity.source : groupLabel(activity))
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
                    .background(.quaternary, in: Capsule())
            }
        }
        .listStyle(.inset)
    }
}
