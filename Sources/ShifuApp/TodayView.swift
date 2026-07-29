import ShifuCore
import SwiftUI

/// The mentor's front page (design.md §7): a greeting, one line of wisdom,
/// today's tracked total with its top categories, the numbers that want
/// attention, and today's task log. Everything here is a read the other pages
/// already own — this page is the "how goes the day" glance.
struct TodayView: View {
    @EnvironmentObject private var store: LedgerStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if store.isPaused { pausedBanner }
                greetingCard
                statRow
                pathSection
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Dojo.paper)
        .navigationTitle("Today")
        .onAppear {
            store.refresh()
            store.runAnalysis()
        }
    }

    // MARK: - Greeting

    private var greetingCard: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(greeting)
                        .font(.system(size: 27, weight: .semibold, design: .rounded))
                    Text("“\(Wisdom.daily())”")
                        .font(Dojo.voice(size: 14.5))
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(TimeBreakdown.duration(trackedTodayMs))
                        .font(.system(size: 40, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("tracked today")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !topCategories.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(topCategories, id: \.name) { entry in
                            categoryChip(entry)
                        }
                    }
                }
            }
            Spacer(minLength: 8)
            SenseiFigure(size: 108, mood: store.isPaused ? .resting : .serene)
                .padding(.trailing, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dojoCard(padding: 20)
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: return "Good morning."
        case 12..<17: return "Good afternoon."
        case 17..<22: return "Good evening."
        default: return "The late hours."
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

    private func categoryChip(_ entry: (name: String, ms: Int64)) -> some View {
        let colors = TimePalette.colors(for: topCategories.map(\.name), lens: .category)
        return HStack(spacing: 5) {
            Circle()
                .fill(colors[entry.name] ?? TimePalette.otherColor)
                .frame(width: 7, height: 7)
            Text("\(TimeBreakdown.duration(entry.ms)) \(entry.name)")
                .font(.caption)
                .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Dojo.well, in: Capsule())
    }

    // MARK: - Numbers that want attention

    private var statRow: some View {
        HStack(spacing: 10) {
            StatTile(value: store.dueNotes.count, label: "cards due", accented: true)
            StatTile(value: store.inboxNotes.count, label: "in inbox")
            StatTile(value: store.reviewsToday, label: "reviewed today")
            StatTile(value: store.suggestions.count, label: "on the radar")
            Spacer()
        }
    }

    // MARK: - Today's path

    private var pathSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Today’s path")
                .font(.headline)
            if store.todayLogs.isEmpty {
                Text("Nothing on the path yet. Work a while — I will keep the record.")
                    .font(Dojo.voice())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .dojoCard()
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(store.todayLogs.prefix(Self.maxLogRows)),
                            id: \.rowID) { entry in
                        logRow(entry)
                        if entry.rowID != store.todayLogs.prefix(Self.maxLogRows).last?.rowID {
                            Divider()
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

    private func logRow(_ entry: TaskStore.DayLogEntry) -> some View {
        NavigationLink(value: entry.taskID) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
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
                    .monospacedDigit()
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Paused

    private var pausedBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "moon.zzz")
                .foregroundStyle(Dojo.accentText)
            if let until = store.pausedUntil {
                Text("Capture is resting until \(until, format: .dateTime.hour().minute()).")
            } else {
                Text("Capture is resting.")
            }
            Spacer()
            Button("Resume") { store.resume() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(12)
        .background(Dojo.accentSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
