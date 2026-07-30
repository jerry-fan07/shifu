import ShifuCore
import SwiftUI

// The Practice band's three places (design.md §5.2).
//
// - Due — the queue you are about to sit down with.
// - Inbox — decks Shifu has drafted, waiting for a yes.
// - Deck — everything you have kept, and the record of working it.
//
// Cards exist because a deck was asked for; nothing proposes a card on its
// own, which is why the Inbox holds deck offers rather than loose cards.

// MARK: - Due

/// What is due now, and the one button that starts it.
struct DueView: View {
    @EnvironmentObject private var store: LedgerStore
    @Environment(\.openWindow) private var openWindow
    @State private var editing: Note?

    var body: some View {
        let due = store.deckDueNotes
        return VStack(spacing: 0) {
            HeroHead(
                figure: "\(due.count)",
                caption: due.count == 1 ? "card due now" : "cards due now"
            ) {
                Text(subtitle)
                    .font(Instrument.sans(12.5))
                    .foregroundStyle(Instrument.muted)
            } trailing: {
                HStack(spacing: 7) {
                    FilterMenu(options: deckOptions, selection: $store.reviewDeck)
                    SolidButton(title: "Review \(due.count)") {
                        openWindow(id: "review")
                        NSApp.activate(ignoringOtherApps: true)
                    }
                    .opacity(due.isEmpty ? 0.35 : 1)
                    .allowsHitTesting(!due.isEmpty)
                }
            }
            PageBody {
                if due.isEmpty {
                    BlankSlate(
                        store.allCards.isEmpty
                            ? "No cards yet. Accept a deck in the Inbox, or open a task and "
                                + "ask for one."
                            : "Nothing due. The deck rests until the next card comes round.")
                } else {
                    CardTable(cards: due) { editing = $0 }
                }
            }
        }
        .onAppear { store.refresh() }
        .sheet(item: $editing) { note in CardEditSheet(note: note) }
    }

    private var subtitle: String {
        var parts = ["\(store.reviewsToday) reviewed today"]
        if let streak = store.reviewStreak, streak > 1 { parts.append("\(streak)-day streak") }
        parts.append("\(store.allCards.count) in the deck")
        return parts.joined(separator: " · ")
    }

    /// Decks first, then themes, then tasks: a deck is a thing the user asked
    /// for, the other two are filters over whatever happens to be there. Only
    /// `ready` decks appear — picking one mid-build would show a half-empty
    /// deck and read as a bug.
    private var deckOptions: [(label: String, value: ReviewDeck)] {
        var options: [(label: String, value: ReviewDeck)] = [("All notes", .all)]
        options += store.decks.filter { $0.status == .ready }.map {
            ("Deck · \($0.title)", ReviewDeck.deck(key: $0.key, name: $0.title))
        }
        options += store.themes.map {
            ("Theme · \($0.name)", ReviewDeck.theme(key: $0.key, name: $0.name))
        }
        options += store.recentTasks.map {
            ("Task · \($0.task.name)", ReviewDeck.task(key: $0.task.key, name: $0.task.name))
        }
        return options
    }
}

// MARK: - Deck

/// The whole deck, and the record of having worked it. The heatmap is the only
/// picture in the app that is about you rather than about your time — which is
/// why it earns the space.
struct DeckView: View {
    @EnvironmentObject private var store: LedgerStore
    @State private var editing: Note?

    var body: some View {
        VStack(spacing: 0) {
            HeroHead(
                figure: "\(store.allCards.count)",
                caption: store.allCards.count == 1 ? "card kept" : "cards kept"
            ) {
                Text(subtitle)
                    .font(Instrument.sans(12.5))
                    .foregroundStyle(Instrument.muted)
            } trailing: {
                EmptyView()
            }
            if !store.reviewsByDay.isEmpty {
                Band { ReviewHeatmapView(counts: store.reviewsByDay) }
            }
            PageBody {
                building
                if store.allCards.isEmpty {
                    BlankSlate(
                        "No cards yet. Cards come from decks — accept one in the Inbox, or "
                            + "open a task and ask for a deck.")
                } else {
                    CardTable(cards: store.allCards) { editing = $0 }
                }
            }
        }
        .onAppear { store.refresh() }
        .sheet(item: $editing) { note in CardEditSheet(note: note) }
    }

    private var subtitle: String {
        var parts = ["\(store.dueNotes.count) due"]
        if let median = store.medianIntervalDays {
            parts.append("median interval \(median) day\(median == 1 ? "" : "s")")
        }
        parts.append("\(store.decks.count) deck\(store.decks.count == 1 ? "" : "s")")
        return parts.joined(separator: " · ")
    }

    /// Decks still filling in. Shown here rather than in the Inbox: they have
    /// already been accepted, so there is nothing left to decide.
    @ViewBuilder private var building: some View {
        let pending = store.decks.filter { $0.status != .ready }
        if !pending.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Eyebrow("Building")
                    .padding(.top, 12)
                    .padding(.bottom, 6)
                ForEach(pending) { deck in
                    Rule()
                    HStack(spacing: 9) {
                        ProgressView().controlSize(.small)
                        Text("“\(deck.title)”")
                            .font(Instrument.sans(12.5))
                            .foregroundStyle(Instrument.ink)
                        Text("finishes with the next analysis run")
                            .font(Instrument.sans(11.5))
                            .foregroundStyle(Instrument.muted)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 7)
                }
            }
            .padding(.bottom, 6)
        }
    }
}

// MARK: - Inbox

/// Decks Shifu has drafted from a task, with their first cards already
/// written — the samples being the whole point, since they are the deck's real
/// cards rather than a preview of them. Keep what you want to remember; a
/// dismissed offer is deleted, not filed.
struct InboxView: View {
    @EnvironmentObject private var store: LedgerStore

    var body: some View {
        VStack(spacing: 0) {
            PageHead(
                store.deckSuggestions.isEmpty
                    ? "Inbox"
                    : "Inbox · \(store.deckSuggestions.count) candidate"
                        + "\(store.deckSuggestions.count == 1 ? "" : "s")",
                subtitle: "Drawn from what you have been reading. Accepting one keeps its "
                    + "sample cards immediately and builds the rest in the background."
            )
            PageBody {
                if store.deckSuggestions.isEmpty {
                    BlankSlate(
                        "Nothing waiting. Shifu offers a deck when a task has enough "
                            + "reading behind it to make cards worth keeping.")
                }
                ForEach(store.deckSuggestions) { suggestion in
                    candidate(suggestion)
                    Rule()
                }
            }
        }
        .onAppear { store.refresh() }
    }

    private func candidate(_ suggestion: DeckStore.PendingSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Text(suggestion.title)
                        .font(Instrument.sans(13.5, .semibold))
                        .foregroundStyle(Instrument.ink)
                    Figure("from \(suggestion.taskName)", size: 10.5, color: Instrument.faint)
                }
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    if store.hasLLMBackend {
                        SolidButton(title: "Keep") { store.acceptDeckSuggestion(suggestion) }
                    } else {
                        // Without a key the build could never run, and the deck
                        // would sit "Building…" forever (§5.2).
                        Text("Needs DeepSeek (Settings)")
                            .font(Instrument.sans(11.5))
                            .foregroundStyle(Instrument.ghost)
                    }
                    OutlineButton(title: "Discard") { store.dismissDeckSuggestion(suggestion) }
                }
            }
            .padding(.bottom, 9)
            ForEach(Array(suggestion.samples.enumerated()), id: \.offset) { _, card in
                sample(card)
            }
        }
        .padding(.top, 14)
        .padding(.bottom, 13)
    }

    /// One sample card, laid out the way the review session will show it: the
    /// question, then the answer, each keyed by a single mono letter.
    private func sample(_ card: DeckStore.SampleCard) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            line("Q", CardMarkup.plainText(card.question), color: Instrument.ink)
            line("A", CardMarkup.plainText(card.answer), color: Instrument.body)
        }
        .padding(.bottom, 8)
        .frame(maxWidth: 720, alignment: .leading)
    }

    private func line(_ key: String, _ text: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Figure(key, size: 11, weight: .medium, color: Instrument.faint)
                .frame(width: 14, alignment: .trailing)
            Text(text)
                .font(Instrument.sans(13))
                .lineSpacing(2)
                .foregroundStyle(color)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - The shared card table

/// Every card the same way, on both Practice tables: the question itself
/// carries the row, because a topic and a due date have never once been enough
/// to know which card you are looking at.
struct CardTable: View {
    let cards: [Note]
    var onEdit: (Note) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ColumnHead {
                Text("Card").frame(maxWidth: .infinity, alignment: .leading)
                Text("Topic").frame(width: 104, alignment: .leading)
                Text("Due").frame(width: 92, alignment: .trailing)
                Text("Difficulty").frame(width: 84, alignment: .trailing)
            }
            ForEach(cards) { note in
                Button { onEdit(note) } label: {
                    HStack(spacing: 14) {
                        Text(question(note))
                            .font(Instrument.sans(12.5))
                            .foregroundStyle(Instrument.ink)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(note.topic)
                            .font(Instrument.sans(12.5))
                            .foregroundStyle(Instrument.muted)
                            .lineLimit(1)
                            .frame(width: 104, alignment: .leading)
                        Figure(
                            CardStatus.dueDescription(note),
                            color: CardStatus(note: note).color)
                            .frame(width: 92, alignment: .trailing)
                        Figure(difficulty(note), color: Instrument.muted)
                            .frame(width: 84, alignment: .trailing)
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Rule()
            }
        }
    }

    private func question(_ note: Note) -> String {
        guard let pair = note.questionAnswer else { return note.topic }
        // One row can't carry styled markup, so it is flattened rather than
        // left as raw LaTeX.
        return CardMarkup.plainText(pair.question)
            .replacingOccurrences(of: "\n", with: " ")
    }

    private func difficulty(_ note: Note) -> String {
        guard let srs = note.srs, srs.reps > 0 else { return "—" }
        return String(format: "%.1f", srs.difficulty)
    }
}

/// Where a card sits in the review cycle. The colour always ships with the
/// word beside it — "3d overdue", "due today" — never on its own.
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
        case .overdue: return Instrument.overdue
        case .dueToday: return Instrument.alert
        case .newCard: return Instrument.accentText
        case .soon, .later: return Instrument.muted
        }
    }

    /// "3d overdue", "due today", "in 12d", "new".
    static func dueDescription(_ note: Note, now: Date = Date()) -> String {
        guard let srs = note.srs, srs.reps > 0 else { return "new" }
        let days = Int((srs.due.timeIntervalSince(now) / 86_400).rounded(.down))
        if days < 0 { return "\(-days)d overdue" }
        if Calendar.current.isDate(srs.due, inSameDayAs: now) { return "due today" }
        return "in \(max(1, days))d"
    }
}
