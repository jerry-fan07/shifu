import Charts
import ShifuCore
import SwiftUI

/// Dashboard (design.md §7): *Time*, *Vault*, *Cards*, and *Radar* tabs.
/// Shows onboarding instead until the first-run flow completes.
struct DashboardView: View {
    @AppStorage("shifu.onboarded") private var onboarded = false

    var body: some View {
        if onboarded {
            tabs
        } else {
            OnboardingView()
        }
    }

    private var tabs: some View {
        TabView {
            TimeTabView()
                .tabItem { Label("Time", systemImage: "chart.bar") }
            VaultTabView()
                .tabItem { Label("Vault", systemImage: "tray.full") }
            CardsTabView()
                .tabItem { Label("Cards", systemImage: "rectangle.stack") }
            RadarTabView()
                .tabItem { Label("Radar", systemImage: "dot.radiowaves.left.and.right") }
        }
        .frame(minWidth: 680, minHeight: 580)
    }
}

/// *Time* tab: stacked bars, day/week toggle, block drill-down.
/// System fonts and colors throughout (§7).
struct TimeTabView: View {
    enum Span: String, CaseIterable { case day = "Day", week = "Week" }

    @EnvironmentObject private var store: LedgerStore
    @State private var span: Span = .day

    static let categoryColors: KeyValuePairs<String, Color> = [
        "work": .blue, "learning": .green, "entertainment": .orange,
        "social": .pink, "communication": .teal, "admin": .gray,
        "private": .secondary, "unclassified": Color.gray.opacity(0.4)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("", selection: $span) {
                ForEach(Span.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .frame(width: 180)

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
        let category: String
        let hours: Double
        let order: Int
    }

    private var buckets: [Bucket] {
        let (from, to) = range
        let activities = store.activities(from: from, to: to)
        let cal = Calendar.current
        let dayZero = cal.startOfDay(for: from)
        // bucket label → (chronological order, category → ms)
        var sums: [String: (order: Int, byCategory: [String: Int64])] = [:]
        for activity in activities {
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
                var entry = sums[label] ?? (order: order, byCategory: [:])
                entry.byCategory[activity.category.rawValue, default: 0]
                    += Int64(slice * 1_000)
                sums[label] = entry
                cursor = bucketEnd
            }
        }
        return sums.flatMap { label, entry in
            entry.byCategory.map { category, ms in
                Bucket(label: label, category: category, hours: Double(ms) / 3_600_000, order: entry.order)
            }
        }
        .sorted { $0.order < $1.order }
    }

    @ViewBuilder private var chart: some View {
        let data = buckets
        if data.isEmpty {
            ContentUnavailableView(
                "No activity yet",
                systemImage: "chart.bar",
                description: Text("The analyzer runs hourly. Data appears once shifud has been watching for a while.")
            )
        } else {
            GeometryReader { proxy in
                Chart(data) { bucket in
                    BarMark(
                        x: .value(span == .day ? "Hour" : "Day", bucket.label),
                        y: .value("Hours", bucket.hours)
                    )
                    .foregroundStyle(by: .value("Category", bucket.category))
                }
                .chartForegroundStyleScale(Self.categoryColors)
                .chartXAxis {
                    AxisMarks(values: axisLabels(in: data, width: proxy.size.width)) {
                        AxisGridLine()
                        AxisTick()
                        // Charts otherwise squeezes each label into its own bar's
                        // width and ellipsises it; we've already thinned for space.
                        AxisValueLabel(collisionResolution: .disabled)
                    }
                }
            }
        }
    }

    /// Every bucket gets a label while they fit; past that, every *n*th one. Without
    /// this the axis truncates to "…" as soon as the window narrows (§7).
    private func axisLabels(in data: [Bucket], width: CGFloat) -> [String] {
        var seen: Set<String> = []
        let labels = data.map(\.label).filter { seen.insert($0).inserted }
        guard !labels.isEmpty, width > 0 else { return labels }
        let perLabel: CGFloat = span == .day ? 25 : 46   // widest label plus breathing room
        let room = max(1, Int(width / perLabel))
        let step = max(1, Int((Double(labels.count) / Double(room)).rounded(.up)))
        return labels.enumerated().compactMap { $0.offset.isMultiple(of: step) ? $0.element : nil }
    }

    private var blockList: some View {
        let (from, to) = range
        let activities = store.activities(from: from, to: to)
            .sorted { $0.startedAt > $1.startedAt }
        return List(activities, id: \.id) { activity in
            HStack {
                Text(Date(timeIntervalSince1970: Double(activity.startedAt) / 1_000),
                     format: .dateTime.hour().minute())
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text(activity.domain ?? shortBundle(activity.appBundle))
                    .lineLimit(1)
                Spacer()
                Text(LedgerStore.hours(activity.durationMs))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text(activity.category.rawValue)
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
        }
        .listStyle(.inset)
    }

    private func shortBundle(_ bundle: String) -> String {
        bundle.split(separator: ".").last.map(String.init) ?? bundle
    }
}
