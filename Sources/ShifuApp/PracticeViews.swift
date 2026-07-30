import ShifuCore
import SwiftUI

// The Practice band's two places (design.md §5.2).
//
// - Due — the queue you are about to sit down with.
// - Decks — everything you have kept, shelved by the deck that minted it,
//   with the offers waiting to become one.
//
// Cards exist because a deck was asked for; nothing proposes a card on its
// own, which is why the offers are deck offers rather than loose cards.

// MARK: - Due

/// What is due now, the one button that starts it, and the heatmap of having
/// shown up — the record of the habit lives with the queue, because this is
/// the tab a session actually starts from.
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
            if !store.reviewsByDay.isEmpty {
                Band { ReviewHeatmapView(counts: store.reviewsByDay) }
            }
            PageBody {
                if due.isEmpty {
                    BlankSlate(
                        store.allCards.isEmpty
                            ? "No cards yet. Accept or start a deck in Decks, or open a "
                                + "task and ask for one."
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
    /// deck and read as a bug — and paused ones sit out here the way their
    /// cards sit out the queue.
    private var deckOptions: [(label: String, value: ReviewDeck)] {
        var options: [(label: String, value: ReviewDeck)] = [("All notes", .all)]
        options += store.decks.filter { $0.status == .ready && !$0.paused }.map {
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

// MARK: - Decks

/// The shelf as a list: one row per deck, the offers waiting above it, the
/// strays at the end. Opening a row *is* the expansion — a deck's cards live
/// on its own page (`DeckPage`), because a deck built for the long haul runs
/// to hundreds of cards and a list that inlines them stops being a list. The
/// old Inbox folds in as the Suggested band, an offer being nothing more
/// than a deck that hasn't been said yes to.
struct DecksView: View {
    @EnvironmentObject private var store: LedgerStore
    @EnvironmentObject private var router: Router

    var body: some View {
        VStack(spacing: 0) {
            HeroHead(
                figure: "\(store.decks.count)",
                caption: store.decks.count == 1 ? "deck kept" : "decks kept"
            ) {
                Text(subtitle)
                    .font(Instrument.sans(12.5))
                    .foregroundStyle(Instrument.muted)
            } trailing: {
                newDeckControl
            }
            PageBody {
                if store.decks.isEmpty, store.deckSuggestions.isEmpty,
                   store.allCards.isEmpty {
                    BlankSlate(
                        "No decks yet. Shifu offers one when a task has enough reading "
                            + "behind it, and New deck starts one from any recent task.")
                } else {
                    suggested
                    shelf
                }
            }
        }
        .onAppear { store.refresh() }
    }

    private var subtitle: String {
        var parts = ["\(store.allCards.count) card\(store.allCards.count == 1 ? "" : "s") kept"]
        parts.append("\(store.dueNotes.count) due")
        if let median = store.medianIntervalDays {
            parts.append("median interval \(median) day\(median == 1 ? "" : "s")")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: New deck

    /// Mints a deck from any recent task that doesn't already have one — the
    /// same one-deck-per-task route as the task page's button, and like it an
    /// escape hatch from a dismissed or declined offer, which are otherwise
    /// permanent. Gated on a configured key like every deck mint: without one
    /// nothing could build the deck, and it would sit "building" forever.
    @ViewBuilder private var newDeckControl: some View {
        if !store.hasLLMBackend {
            Text("A deck needs DeepSeek (Settings)")
                .font(Instrument.sans(11.5))
                .foregroundStyle(Instrument.ghost)
        } else if !candidateTasks.isEmpty {
            ActionMenu(
                title: "New deck",
                options: candidateTasks.map { overview in
                    (overview.task.name, {
                        store.createDeck(
                            taskKey: overview.task.key, title: overview.task.name)
                    })
                })
        }
    }

    /// Recent tasks with no deck and no open offer. A task whose offer was
    /// dismissed stays listed — that is the escape hatch working.
    private var candidateTasks: [TaskStore.Overview] {
        let spoken = Set(store.decks.map(\.taskKey))
            .union(store.deckSuggestions.map(\.taskKey))
        return store.recentTasks.filter { !spoken.contains($0.task.key) }
    }

    // MARK: Suggested (the former Inbox)

    /// Decks Shifu has drafted from a task, with their first cards already
    /// written — the samples being the whole point, since they are the deck's
    /// real cards rather than a preview of them. Keep writes them immediately
    /// and builds the rest; a discarded offer is deleted, not filed.
    @ViewBuilder private var suggested: some View {
        if !store.deckSuggestions.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Eyebrow("Suggested · from what you have been reading")
                    .padding(.top, 12)
                    .padding(.bottom, 6)
                ForEach(store.deckSuggestions) { suggestion in
                    Rule()
                    candidate(suggestion)
                }
            }
            .padding(.bottom, 10)
        }
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

    // MARK: The shelf

    /// One row per deck — its state at a glance, its cards behind the click.
    /// The strays close the list.
    @ViewBuilder private var shelf: some View {
        let groups = deckGroups
        let loose = store.looseCards
        if !groups.isEmpty || !loose.isEmpty {
            ColumnHead {
                Text("Deck").frame(maxWidth: .infinity, alignment: .leading)
                Text("Cards").frame(width: 84, alignment: .trailing)
                Text("Due now").frame(width: 92, alignment: .trailing)
            }
            ForEach(groups) { group in
                deckRow(group)
            }
            if !loose.isEmpty {
                looseRow(loose)
            }
        }
    }

    private struct DeckGroup: Identifiable {
        let deck: DeckStore.Deck
        let cards: [Note]
        var id: String { deck.key }
    }

    /// Cards under the deck that minted them, newest deck first — the order
    /// `DeckStore.decks` already returns.
    private var deckGroups: [DeckGroup] {
        let byDeck = Dictionary(
            grouping: store.allCards.filter { $0.deck != nil },
            by: { $0.deck ?? "" })
        return store.decks.map { DeckGroup(deck: $0, cards: byDeck[$0.key] ?? []) }
    }

    @ViewBuilder private func deckRow(_ group: DeckGroup) -> some View {
        let due = store.dueNotes.filter { $0.deck == group.deck.key }.count
        Button { router.open(.deck(group.deck.id)) } label: {
            HStack(spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    // The deck's name carries the row the way a theme's does:
                    // one size up from the table's figures, in semibold.
                    Text(group.deck.title)
                        .font(Instrument.sans(13.5, .semibold))
                        .foregroundStyle(Instrument.ink)
                        .lineLimit(1)
                    // A deck minted from the task page wears the task's own
                    // name, and "X from X" says nothing.
                    if group.deck.title != group.deck.taskName {
                        Figure("from \(group.deck.taskName)", size: 10.5,
                               color: Instrument.faint)
                            .lineLimit(1)
                    }
                    if group.deck.paused {
                        Tag("Paused")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Figure("\(group.cards.count)", color: Instrument.muted)
                    .frame(width: 84, alignment: .trailing)
                if group.deck.status == .ready {
                    // A paused deck's due count is honestly zero (the gate
                    // holds its cards back), and the tag already says why.
                    Figure("\(due)", color: due > 0 ? Instrument.accentText : Instrument.muted)
                        .frame(width: 92, alignment: .trailing)
                } else {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Figure("building", color: Instrument.muted)
                    }
                    .frame(width: 92, alignment: .trailing)
                }
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        Rule()
    }

    @ViewBuilder private func looseRow(_ loose: [Note]) -> some View {
        let due = Set(store.dueNotes.map(\.id))
        Button { router.open(.looseCards) } label: {
            HStack(spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Text("Loose cards")
                        .font(Instrument.sans(13.5, .semibold))
                        .foregroundStyle(Instrument.ink)
                    Figure("outside any deck", size: 10.5, color: Instrument.faint)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Figure("\(loose.count)", color: Instrument.muted)
                    .frame(width: 84, alignment: .trailing)
                let dueCount = loose.filter { due.contains($0.id) }.count
                Figure("\(dueCount)",
                       color: dueCount > 0 ? Instrument.accentText : Instrument.muted)
                    .frame(width: 92, alignment: .trailing)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        Rule()
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
            CardColumnHead()
            CardRows(cards: cards, onEdit: onEdit)
        }
    }
}

/// The four columns both card tables share, so the Decks shelf and the Due
/// table can't drift apart.
struct CardColumnHead: View {
    var body: some View {
        ColumnHead {
            Text("Card").frame(maxWidth: .infinity, alignment: .leading)
            Text("Topic").frame(width: 104, alignment: .leading)
            Text("Due").frame(width: 92, alignment: .trailing)
            Text("Difficulty").frame(width: 84, alignment: .trailing)
        }
    }
}

/// The rows without the head — the Decks shelf interleaves deck headers
/// between groups of these under one shared column head.
struct CardRows: View {
    let cards: [Note]
    var onEdit: (Note) -> Void

    var body: some View {
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
