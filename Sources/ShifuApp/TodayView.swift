import ShifuCore
import SwiftUI

/// The mentor's front page (design.md §7): the mountain and the hour of the day,
/// then today's total, then the day drawn as stepping stones, then the log.
/// Everything here is a read the other pages already own — this page is the
/// "how goes the day" glance, and the only one that is mostly picture.
struct TodayView: View {
    @EnvironmentObject private var store: LedgerStore

    private var sky: SkyTime { SkyTime.current() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if store.isPaused { pausedBanner }
                heroCard
                statRow
                trailSection
                pathSection
            }
            .padding(20)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Dojo.paper)
        // No navigation title: the hero already says the day, and an empty
        // toolbar strip lets the scene start at the top of the pane.
        .onAppear {
            store.refresh()
            store.runAnalysis()
        }
    }

    // MARK: - Hero

    /// Scene on top, numbers on the surface strip below it. Splitting them is
    /// what lets the sky change all day without the type ever fighting it: the
    /// only words over the painting sit in the upper sky, which is the one band
    /// each palette guarantees a contrast for.
    private var heroCard: some View {
        VStack(spacing: 0) {
            ShifuScene(
                time: sky,
                mood: store.isPaused ? .resting : .watching,
                petSize: 88)
                .frame(height: 208)
                // A wash under the text column only. The palettes already pick
                // an ink that reads on the upper sky; this is insurance for the
                // narrow window, where the peaks creep left behind the words.
                .overlay(alignment: .leading) {
                    LinearGradient(
                        colors: [
                            sky.palette.skyColors[0].opacity(0.55),
                            sky.palette.skyColors[0].opacity(0)
                        ],
                        startPoint: .leading, endPoint: .trailing)
                        .frame(width: 380)
                }
                .overlay(alignment: .topLeading) { greeting }
            totalStrip
        }
        .background(Dojo.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Dojo.hairline, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.07), radius: 12, y: 3)
    }

    private var greeting: some View {
        let palette = sky.palette
        return VStack(alignment: .leading, spacing: 6) {
            Text(Date().formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
                .uppercased())
                .font(Dojo.label())
                .tracking(1.6)
                .foregroundStyle(palette.secondaryTextColor)
            Text(greetingLine)
                .font(Dojo.display(30))
                .foregroundStyle(palette.textColor)
            Text("“\(Wisdom.daily())”")
                .font(Dojo.voice(size: 14.5))
                .foregroundStyle(palette.secondaryTextColor)
                .frame(maxWidth: 310, alignment: .leading)
        }
        .padding(22)
    }

    private var totalStrip: some View {
        HStack(alignment: .lastTextBaseline, spacing: 12) {
            Text(TimeBreakdown.duration(trackedTodayMs))
                .font(Dojo.display(34))
                .monospacedDigit()
            Eyebrow("tracked today")
            Spacer(minLength: 12)
            ForEach(topCategories, id: \.name) { entry in
                DojoChip(
                    text: "\(TimeBreakdown.duration(entry.ms)) \(entry.name)",
                    dot: categoryColors[entry.name] ?? TimePalette.otherColor)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var greetingLine: String {
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

    private var categoryColors: [String: Color] {
        TimePalette.colors(for: topCategories.map(\.name), lens: .category)
    }

    // MARK: - Numbers that want attention

    private var statRow: some View {
        HStack(spacing: 10) {
            StatTile(value: store.dueNotes.count, label: "cards due", accented: true)
            StatTile(value: store.inboxNotes.count, label: "in inbox")
            StatTile(value: store.reviewsToday, label: "reviewed")
            StatTile(value: store.suggestions.count, label: "on radar")
            Spacer()
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
