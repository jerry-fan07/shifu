import ShifuCore
import SwiftUI

/// The mentor's front page (design.md §7): today's total, the counts that want
/// attention, the day drawn as stepping stones, then the log. The window itself
/// carries the picture now — the camp, the hour's sky, and Shifu standing on the
/// terrace beside this scroll — so the page is only the reading.
struct TodayView: View {
    @EnvironmentObject private var store: LedgerStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if store.isPaused { pausedBanner }
                totalStrip
                statGrid
                trailSection
                pathSection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            store.refresh()
            store.runAnalysis()
        }
    }

    // MARK: - The day's total

    private var totalStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .lastTextBaseline, spacing: 10) {
                Text(TimeBreakdown.duration(trackedTodayMs))
                    .font(Dojo.display(38))
                    .monospacedDigit()
                Eyebrow("tracked today")
                Spacer(minLength: 0)
            }
            if !topCategories.isEmpty {
                HStack(spacing: 6) {
                    ForEach(topCategories, id: \.name) { entry in
                        DojoChip(
                            text: "\(TimeBreakdown.duration(entry.ms)) \(entry.name)",
                            dot: categoryColors[entry.name] ?? TimePalette.otherColor)
                    }
                }
            }
        }
    }

    private var trackedTodayMs: Int64 {
        store.todayTotals.values.reduce(0, +)
    }

    /// Top categories worth naming — same floor as the menu bar line.
    private var topCategories: [(name: String, ms: Int64)] {
        store.todayTotals
            .filter { $0.key != .unclassified && $0.value >= 60_000 }
            .sorted { $0.value > $1.value }
            .prefix(3)
            .map { (name: $0.key.rawValue, ms: $0.value) }
    }

    private var categoryColors: [String: Color] {
        TimePalette.colors(for: topCategories.map(\.name), lens: .category)
    }

    // MARK: - Numbers that want attention

    /// Two by two rather than a row: the scroll beside the mountain is a
    /// column, and four tiles abreast would set the window's whole width.
    private var statGrid: some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: 10, alignment: .leading), count: 2),
            spacing: 10
        ) {
            StatTile(value: store.dueNotes.count, label: "cards due", accented: true)
            StatTile(value: store.inboxNotes.count, label: "in inbox")
            StatTile(value: store.reviewsToday, label: "reviewed")
            StatTile(value: store.suggestions.count, label: "on radar")
        }
    }

    // MARK: - The day as a route

    private var trailSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading("Today’s stones", trailing: "one per hour")
            DayTrail(stones: DayTrail.stones(from: todayActivities))
                .padding(.horizontal, 4)
                .padding(.top, 6)
                .dojoCard(padding: 12)
        }
    }

    private var todayActivities: [LedgerBuilder.LabeledActivity] {
        store.labeledActivities(from: Calendar.current.startOfDay(for: Date()), to: Date())
    }

    // MARK: - Today's path

    private var pathSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(
                "Today’s path",
                trailing: store.todayLogs.isEmpty ? nil : "\(store.todayLogs.count) entries")
            if store.todayLogs.isEmpty {
                Text("Nothing on the path yet. Work a while — I will keep the record.")
                    .font(Dojo.voice())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .dojoCard()
            } else {
                let shown = Array(store.todayLogs.prefix(Self.maxLogRows))
                VStack(spacing: 0) {
                    ForEach(shown, id: \.rowID) { entry in
                        logRow(entry)
                        if entry.rowID != shown.last?.rowID {
                            Divider().padding(.leading, 44)
                        }
                    }
                }
                .dojoCard(padding: 0)
                if store.todayLogs.count > Self.maxLogRows {
                    Text("…and \(store.todayLogs.count - Self.maxLogRows) more in the Task log")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// Rows before the page defers to the Task log — a glance, not the ledger.
    private static let maxLogRows = 8

    /// Each row is a waypoint: a marker in the left gutter, the task, and how
    /// long it took.
    private func logRow(_ entry: TaskStore.DayLogEntry) -> some View {
        NavigationLink(value: entry.taskID) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Circle()
                    .strokeBorder(Dojo.accent.opacity(0.55), lineWidth: 2)
                    .frame(width: 8, height: 8)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.taskName)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Text(entry.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text(LedgerStore.hours(entry.durationMs))
                    .font(Dojo.label(11, .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Paused

    private var pausedBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "moon.zzz.fill")
                .foregroundStyle(Dojo.accentText)
            if let until = store.pausedUntil {
                Text("Shifu is asleep until \(until, format: .dateTime.hour().minute()).")
            } else {
                Text("Shifu is asleep. Nothing is being captured.")
            }
            Spacer()
            Button("Wake him") { store.resume() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(12)
        .background(Dojo.accentSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
