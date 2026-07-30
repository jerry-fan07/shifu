import ShifuCore
import SwiftUI

/// The *Practice* page (design.md §5.2): suggested decks, review-activity
/// heatmap, deck picker, and an urgency overview of every card. The review
/// session is a separate screen pushed from here into the page's stack.
///
/// There is no inbox. Nothing proposes a card any more — a card exists because
/// a deck was asked for, so there is nothing to triage.
struct PracticeView: View {
    @EnvironmentObject private var store: LedgerStore
    @State private var editingCard: Note?

    enum Screen: Hashable {
        case review
    }

    var body: some View {
        PageScaffold(destination: .practice) {
            reviewButton
        } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    statsRow
                    suggestionsSection
                    activitySection
                    deckRow
                    cardsSection
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
        .navigationDestination(for: Screen.self) { screen in
            switch screen {
            case .review: ReviewSessionView()
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
            StatTile(value: store.dueNotes.count, label: "due now", accented: true)
            StatTile(value: store.decks.count, label: "decks")
            StatTile(value: store.allCards.count, label: "cards")
            StatTile(value: store.reviewsToday, label: "reviewed today")
            Spacer()
        }
    }

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading(
                "Review activity",
                trailing: "\(LedgerStore.HeatmapSpan.weeks) weeks")
            ReviewHeatmapView(counts: store.reviewsByDay)
                .dojoCard(padding: 14)
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
                SectionHeading("Suggested decks")
                ForEach(store.deckSuggestions) { suggestion in
                    DeckSuggestionCard(suggestion: suggestion)
                }
                ForEach(building) { deck in
                    HStack(spacing: 9) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Building “\(deck.title)”…")
                        Text("finishes with the next analysis if DeepSeek is unavailable")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .dojoCard(padding: 12)
                }
            }
        }
    }

    // MARK: - Deck + navigation

    /// The one door out of this page, in the header where it can't be
    /// scrolled past.
    private var reviewButton: some View {
        NavigationLink(value: Screen.review) {
            Label("Review \(store.deckDueNotes.count)", systemImage: "play.fill")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .disabled(store.deckDueNotes.isEmpty)
    }

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
        HStack(spacing: 10) {
            Eyebrow("deck")
            FilterMenu(options: deckOptions, selection: $store.reviewDeck)
            Spacer()
        }
        .font(.caption)
    }

    // MARK: - All cards by urgency

    private var cardsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading(
                "All cards",
                trailing: store.allCards.isEmpty ? nil : "\(store.allCards.count)")
            if store.allCards.isEmpty {
                emptyDeckView
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    CardUrgencyGridView(cards: store.allCards) { note in
                        editingCard = note
                    }
                    urgencyLegend
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .dojoCard(padding: 14)
                LazyVStack(spacing: 0) {
                    ForEach(store.allCards) { note in
                        CardListRow(note: note) { editingCard = note }
                        if note.id != store.allCards.last?.id {
                            Divider()
                        }
                    }
                }
                .dojoCard(padding: 0)
            }
        }
    }

    /// Empty deck. Cards come from decks the user asked for (§5.2) and from
    /// nowhere else, so that is the only thing the empty state can point at.
    private var emptyDeckView: some View {
        SenseiEmptyState(
            "No cards yet",
            message: "Cards come from decks. Accept a suggested deck above, or "
                + "open a task in the Task log and ask me for one.")
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(suggestion.title)
                        .font(Dojo.display(14))
                    Text("from task \(suggestion.taskName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if store.hasLLMBackend {
                    Button("Create") { store.acceptDeckSuggestion(suggestion) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                } else {
                    // Without a key the build could never run, and the deck
                    // would sit "Building…" forever (§5.2).
                    Text("Needs DeepSeek (Settings)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Dismiss") { store.dismissDeckSuggestion(suggestion) }
                    .controlSize(.small)
            }
            ForEach(Array(suggestion.samples.enumerated()), id: \.offset) { _, card in
                HStack(alignment: .top, spacing: 8) {
                    Text(card.topic)
                        .font(Dojo.label(10, .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 110, alignment: .leading)
                    Text(CardMarkup.plainText(card.question))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dojoCard(padding: 12)
    }
}

// StatTile lives in DojoChrome.swift — the Today page shares it.
// ReviewHeatmapView lives in ReviewHeatmapView.swift.

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
        case .overdue: return Dojo.statusRed
        case .dueToday: return Dojo.statusAmber
        case .newCard: return Dojo.blue
        case .soon: return Dojo.teal
        case .later: return Dojo.statusGreen
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
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
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
