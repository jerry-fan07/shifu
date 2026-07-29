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
                    suggestionsSection
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

    // MARK: - Deck suggestions (design.md §5.2)

    /// Proposed decks and the decks still filling in. Cards are user-requested
    /// now, so this section is where most of them start: the samples are real
    /// cards, which is what makes the offer judgeable rather than a guess.
    @ViewBuilder private var suggestionsSection: some View {
        let building = store.decks.filter { $0.status != .ready }
        if !store.deckSuggestions.isEmpty || !building.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Suggested decks")
                    .font(.headline)
                ForEach(store.deckSuggestions) { suggestion in
                    DeckSuggestionCard(suggestion: suggestion)
                }
                ForEach(building) { deck in
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Building “\(deck.title)”…")
                        Text("finishes with the next analysis if DeepSeek is unavailable")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Deck + navigation

    /// Decks first, then themes, then tasks: a deck is a thing the user asked
    /// for, the other two are filters over whatever happens to be there.
    /// Only `ready` decks appear — picking one mid-build would show a
    /// half-empty deck and read as a bug.
    private var deckOptions: [(label: String, value: ReviewDeck)] {
        var options: [(label: String, value: ReviewDeck)] = [("All notes", .all)]
        options += store.decks.filter { $0.status == .ready }.map {
            ("Deck · \($0.title)", ReviewDeck.deck(key: $0.key, name: $0.title))
        }
        options += store.themes.map {
            ("Theme · \($0.name)", ReviewDeck.theme(key: $0.key, name: $0.name))
        }
        options += store.recentTasks.map {
            ("Task · \($0.task.name)",
             ReviewDeck.task(key: $0.task.key, name: $0.task.name))
        }
        return options
    }

    private var deckRow: some View {
        HStack {
            FilterMenu(options: deckOptions, selection: $store.reviewDeck)
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

/// One proposed deck: what it would be called, which task it came out of,
/// and its sample cards — the samples being the whole point, since they are
/// the deck's real first cards rather than a preview of them.
private struct DeckSuggestionCard: View {
    @EnvironmentObject private var store: LedgerStore
    let suggestion: DeckStore.PendingSuggestion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(suggestion.title)
                        .font(.subheadline.weight(.semibold))
                    Text("from task \(suggestion.taskName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if store.hasLLMBackend {
                    Button("Create") { store.acceptDeckSuggestion(suggestion) }
                        .buttonStyle(.borderedProminent)
                } else {
                    // Without a key the build could never run, and the deck
                    // would sit "Building…" forever (§5.2).
                    Text("Needs DeepSeek (Settings)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Dismiss") { store.dismissDeckSuggestion(suggestion) }
            }
            ForEach(Array(suggestion.samples.enumerated()), id: \.offset) { _, card in
                HStack(alignment: .top, spacing: 6) {
                    Text(card.topic)
                        .font(.caption.weight(.medium))
                        .frame(width: 110, alignment: .leading)
                    Text(CardMarkup.plainText(card.question))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
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
