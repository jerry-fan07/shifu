import ShifuCore
import SwiftUI

/// *Cards* tab home (design.md §5.2): review-activity heatmap, deck picker,
/// and an urgency overview of every card. Inbox triage and the review
/// session are separate screens pushed from here.
struct CardsTabView: View {
    @EnvironmentObject private var store: LedgerStore
    @State private var path: [Screen] = []
    @State private var editingCard: Note?

    enum Screen: Hashable {
        case inbox
        case review
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    statsRow
                    activitySection
                    deckRow
                    cardsSection
                }
                .padding(20)
            }
            .navigationDestination(for: Screen.self) { screen in
                switch screen {
                case .inbox: InboxView()
                case .review: ReviewSessionView()
                }
            }
        }
        .onAppear { store.refresh() }
        .sheet(item: $editingCard) { note in
            CardEditSheet(note: note)
        }
    }

    // MARK: - Header stats

    private var statsRow: some View {
        HStack(spacing: 12) {
            StatTile(value: store.dueNotes.count, label: "due now")
            StatTile(value: store.inboxNotes.count, label: "in inbox")
            StatTile(value: store.allCards.count, label: "cards")
            StatTile(value: store.reviewsToday, label: "reviewed today")
            Spacer()
        }
    }

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Review activity")
                .font(.headline)
            ReviewHeatmapView(counts: store.reviewsByDay)
        }
    }

    // MARK: - Deck + navigation

    private var deckRow: some View {
        HStack {
            Picker("Deck", selection: $store.reviewDeck) {
                Text("All notes").tag(ReviewDeck.all)
                ForEach(store.themes) { theme in
                    Text("Theme · \(theme.name)")
                        .tag(ReviewDeck.theme(key: theme.key, name: theme.name))
                }
                ForEach(store.recentTasks) { overview in
                    Text("Task · \(overview.task.name)")
                        .tag(ReviewDeck.task(key: overview.task.key, name: overview.task.name))
                }
            }
            .frame(maxWidth: 320)
            Spacer()
            Button {
                path.append(.inbox)
            } label: {
                Label("Inbox · \(store.inboxNotes.count)", systemImage: "tray")
            }
            Button {
                path.append(.review)
            } label: {
                Label("Review · \(store.deckDueNotes.count) due", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.deckDueNotes.isEmpty)
        }
    }

    // MARK: - All cards by urgency

    private var cardsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("All cards")
                .font(.headline)
            if store.allCards.isEmpty {
                emptyDeckView
            } else {
                CardUrgencyGridView(cards: store.allCards) { note in
                    editingCard = note
                }
                urgencyLegend
                Divider()
                LazyVStack(spacing: 0) {
                    ForEach(store.allCards) { note in
                        CardListRow(note: note) { editingCard = note }
                        Divider()
                    }
                }
            }
        }
    }

    /// Empty deck. This used to offer the freshest reviewable inbox
    /// candidates to keep, but automatic extraction no longer writes a Q/A —
    /// the inbox is reference notes now, so that list would be permanently
    /// empty. Cards come from decks the user asked for (§5.2), and that is
    /// where the empty state points.
    private var emptyDeckView: some View {
        ContentUnavailableView(
            "No cards yet", systemImage: "rectangle.stack",
            description: Text("Cards come from decks. Accept a suggested deck above, "
                + "or open a task in the Vault tab and ask for one.")
        )
    }

    private var urgencyLegend: some View {
        HStack(spacing: 14) {
            ForEach(CardStatus.allCases, id: \.self) { status in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(status.color)
                        .frame(width: 8, height: 8)
                    Text(status.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Hero-number tile: big value, muted label underneath.
private struct StatTile: View {
    let value: Int
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(value)")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Where a card sits in the review cycle. Status colors always ship with a
/// text label (legend, list rows) — never color alone.
enum CardStatus: CaseIterable {
    case overdue, dueToday, newCard, soon, later

    init(note: Note, now: Date = Date()) {
        guard let srs = note.srs, srs.reps > 0 else {
            self = .newCard
            return
        }
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)
        let endOfToday = startOfToday.addingTimeInterval(86_400)
        if srs.due < startOfToday {
            self = .overdue
        } else if srs.due < endOfToday {
            self = .dueToday
        } else if srs.due < now.addingTimeInterval(3 * 86_400) {
            self = .soon
        } else {
            self = .later
        }
    }

    var label: String {
        switch self {
        case .overdue: return "Overdue"
        case .dueToday: return "Due today"
        case .newCard: return "New"
        case .soon: return "Soon"
        case .later: return "Scheduled"
        }
    }

    var color: Color {
        switch self {
        case .overdue: return .red
        case .dueToday: return .orange
        case .newCard: return .blue
        case .soon: return .yellow
        case .later: return .green
        }
    }

    var symbol: String {
        switch self {
        case .overdue: return "exclamationmark.circle"
        case .dueToday: return "clock"
        case .newCard: return "sparkle"
        case .soon: return "hourglass"
        case .later: return "checkmark.circle"
        }
    }

    /// "3 d overdue", "due today", "due in 12 d".
    static func dueDescription(_ note: Note, now: Date = Date()) -> String {
        guard let srs = note.srs, srs.reps > 0 else { return "never reviewed" }
        let days = Int((srs.due.timeIntervalSince(now) / 86_400).rounded(.down))
        if days < 0 { return "\(-days) d overdue" }
        if Calendar.current.isDate(srs.due, inSameDayAs: now) { return "due today" }
        return "due in \(max(1, days)) d"
    }
}

/// One square per card, most urgent first — the deck's state at a glance.
struct CardUrgencyGridView: View {
    let cards: [Note]
    var onTap: (Note) -> Void

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 14, maximum: 14), spacing: 3)],
            alignment: .leading, spacing: 3
        ) {
            ForEach(cards) { note in
                let status = CardStatus(note: note)
                RoundedRectangle(cornerRadius: 3)
                    .fill(status.color.opacity(0.85))
                    .frame(width: 14, height: 14)
                    .help("\(note.topic) — \(status.label), \(CardStatus.dueDescription(note))")
                    .onTapGesture { onTap(note) }
            }
        }
    }
}

/// One card row: topic, question snippet, status chip with due distance.
private struct CardListRow: View {
    let note: Note
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(note.topic).bold()
                    if let qa = note.questionAnswer {
                        // One styled line won't fit here, so the markup is
                        // flattened rather than left as raw LaTeX.
                        Text(CardMarkup.plainText(qa.question)
                            .replacingOccurrences(of: "\n", with: " "))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Text(CardStatus.dueDescription(note))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                statusChip
            }
            .contentShape(Rectangle())
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }

    private var statusChip: some View {
        let status = CardStatus(note: note)
        return Label(status.label, systemImage: status.symbol)
            .font(.caption)
            .foregroundStyle(status.color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(status.color.opacity(0.12), in: Capsule())
    }
}

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
