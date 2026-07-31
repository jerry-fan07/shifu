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

/// The shelf as a list: the load ahead over it, one row per deck, the offers
/// waiting above those, the strays at the end. The forecast band belongs here
/// rather than on Due because it is a fact about the *shelf* — what everything
/// kept is going to cost over the next four weeks, and how much of that bill is
/// already late — where Due is only ever about the next sitting.
/// Opening a row *is* the expansion — a deck's cards live
/// on its own page (`DeckPage`), because a deck built for the long haul runs
/// to hundreds of cards and a list that inlines them stops being a list. The
/// old Inbox folds in as the Suggested band, an offer being nothing more
/// than a deck that hasn't been said yes to.
struct DecksView: View {
    @EnvironmentObject private var store: LedgerStore
    @EnvironmentObject private var router: Router

    var body: some View {
        let forecast = ReviewForecast.build(cards: store.scheduledCards)
        return VStack(spacing: 0) {
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
            if forecast.hasSchedule {
                Band { ReviewForecastView(forecast: forecast) }
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

    /// The way to the form (`NewDeckPage`): pick a source task, brief the
    /// builder, set the title and review settings — the same one-deck-per-task
    /// route as the task page's button, and like it an escape hatch from a
    /// dismissed or declined offer, which are otherwise permanent. Gated on a
    /// configured key like every deck mint: without one nothing could build
    /// the deck, and it would sit "building" forever.
    @ViewBuilder private var newDeckControl: some View {
        if store.hasLLMBackend {
            SolidButton(title: "New deck", glyph: "+") { router.open(.newDeck) }
        } else {
            Text("A deck needs DeepSeek (Settings)")
                .font(Instrument.sans(11.5))
                .foregroundStyle(Instrument.ghost)
        }
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
    ///
    /// The band above is the shelf's total; these are the same question asked
    /// per deck, which is the only way to answer the one the total can't:
    /// *which* deck is burying you. Every row's spark is scaled to one shared
    /// ceiling, so their heights can be compared down the column.
    @ViewBuilder private var shelf: some View {
        let groups = deckGroups
        let loose = store.looseCards
        let looseForecast = ReviewForecast.build(cards: loose, span: ShelfMeasures.sparkDays)
        if !groups.isEmpty || !loose.isEmpty {
            let ceiling = max(
                loose.isEmpty ? 0 : looseForecast.peak,
                groups.filter { $0.drawsSpark }.map { $0.forecast.peak }.max() ?? 0)
            ColumnHead {
                Text("Deck").frame(maxWidth: .infinity, alignment: .leading)
                Text("Cards").frame(width: 56, alignment: .trailing)
                Text("Behind").frame(width: 62, alignment: .trailing)
                Text("Due now").frame(width: 70, alignment: .trailing)
                Text("Next \(ShelfMeasures.sparkDays) days")
                    .frame(width: ShelfMeasures.sparkColumn, alignment: .trailing)
            }
            ForEach(groups) { group in
                deckRow(group, ceiling: ceiling)
            }
            if !loose.isEmpty {
                looseRow(loose, forecast: looseForecast, ceiling: ceiling)
            }
        }
    }

    private struct DeckGroup: Identifiable {
        let deck: DeckStore.Deck
        let cards: [Note]
        let forecast: ReviewForecast
        var id: String { deck.key }

        /// A paused deck's cards are out of every queue *and count* (§5.2), and
        /// a deck still building has nothing settled to forecast — both would
        /// otherwise draw a week of work that is not coming.
        var drawsSpark: Bool { deck.status == .ready && !deck.paused }
    }

    /// Cards under the deck that minted them, newest deck first — the order
    /// `DeckStore.decks` already returns. The forecasts are built here, once
    /// per body pass, rather than per row.
    private var deckGroups: [DeckGroup] {
        let byDeck = Dictionary(
            grouping: store.allCards.filter { $0.deck != nil },
            by: { $0.deck ?? "" })
        return store.decks.map { deck in
            let cards = byDeck[deck.key] ?? []
            return DeckGroup(
                deck: deck, cards: cards,
                forecast: ReviewForecast.build(cards: cards, span: ShelfMeasures.sparkDays))
        }
    }

    @ViewBuilder private func deckRow(_ group: DeckGroup, ceiling: Int) -> some View {
        let due = store.dueNotes.filter { $0.deck == group.deck.key }.count
        Button { router.open(.deck(group.deck.id)) } label: {
            HStack(spacing: 14) {
                ShelfName(
                    title: group.deck.title,
                    // A deck minted from the task page wears the task's own
                    // name, and "X from X" says nothing.
                    detail: group.deck.title == group.deck.taskName
                        ? nil : "from \(group.deck.taskName)",
                    unstarted: group.forecast.unstarted,
                    paused: group.deck.paused,
                    building: group.deck.status != .ready)
                ShelfMeasures(
                    cards: group.cards.count, dueNow: due,
                    // A paused deck's counts are honestly nothing (the gate
                    // holds its cards back), and the tag already says why.
                    forecast: group.drawsSpark ? group.forecast : nil,
                    ceiling: ceiling)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        Rule()
    }

    @ViewBuilder private func looseRow(
        _ loose: [Note], forecast: ReviewForecast, ceiling: Int
    ) -> some View {
        let due = Set(store.dueNotes.map(\.id))
        Button { router.open(.looseCards) } label: {
            HStack(spacing: 14) {
                ShelfName(
                    title: "Loose cards", detail: "outside any deck",
                    unstarted: forecast.unstarted, paused: false)
                ShelfMeasures(
                    cards: loose.count,
                    dueNow: loose.filter { due.contains($0.id) }.count,
                    forecast: forecast, ceiling: ceiling)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        Rule()
    }
}

// MARK: - The shelf's cells

/// What a shelf row is called, over what it was made from. Two lines rather
/// than one: with four measures to the right of it there is no room to run the
/// source task inline, and at the window's minimum width the name was the
/// thing that got truncated.
private struct ShelfName: View {
    let title: String
    /// Where the cards came from — the source task, or "outside any deck".
    let detail: String?
    /// Cards never reviewed. Named here because they are deliberately absent
    /// from the spark (`ReviewForecast.unstarted`), and a deck whose hundred
    /// cards all sit in that pool would otherwise draw an empty week with no
    /// account of where they went.
    let unstarted: Int
    let paused: Bool
    /// A deck still filling in. The spinner rides beside the name rather than
    /// in a measure column (design.md §5.2 only asks that it be on the row):
    /// while a deck builds, every measure to the right of it is "—", and the
    /// state belongs where the eye lands first — next to what it is a state of.
    var building = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                // The deck's name carries the row the way a theme's does: one
                // size up from the table's figures, in semibold.
                Text(title)
                    .font(Instrument.sans(13.5, .semibold))
                    .foregroundStyle(Instrument.ink)
                    .lineLimit(1)
                if building {
                    ProgressView().controlSize(.small)
                    Figure("building", size: 11, color: Instrument.faint)
                } else if paused {
                    Tag("Paused")
                }
            }
            if !line.isEmpty {
                Figure(line, size: 10.5, color: Instrument.faint).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var line: String {
        var parts: [String] = []
        if let detail { parts.append(detail) }
        if unstarted > 0 { parts.append("\(unstarted) never started") }
        return parts.joined(separator: " · ")
    }
}

/// The four measures every shelf row ends with, so the deck rows and the loose
/// row can't drift apart: how many cards, how far behind, how many the next
/// sitting holds, and the week ahead.
///
/// `behind` and `dueNow` are deliberately both here and deliberately different:
/// the first is the debt (reviews whose day has passed), the second is the
/// session `ReviewGate` would actually hand you, new-card ration included.
private struct ShelfMeasures: View {
    let cards: Int
    let dueNow: Int
    /// Nil for a deck with no week to draw — paused, or still building. It also
    /// blanks the two urgency figures, since neither means anything about a
    /// deck no queue is drawing from.
    let forecast: ReviewForecast?
    let ceiling: Int

    /// How far ahead a row looks. Shorter than the band's four weeks on
    /// purpose: a table cell has room for a week, and a row's question is
    /// "what is about to land" where the band's is "what shape is the month".
    static let sparkDays = 7
    /// Wide enough for the marks and for the head over them. Trailing-aligned
    /// like every figure column, which also buys the air that keeps the marks
    /// from reading as an extension of the due-now count beside them.
    static let sparkColumn: CGFloat = 100

    /// Its own stack at the row's spacing, so the cells line up under the
    /// column heads exactly as if they had been written inline.
    var body: some View {
        HStack(spacing: 14) {
            Figure("\(cards)", color: Instrument.muted)
                .frame(width: 56, alignment: .trailing)
            Figure(figure(behind), color: color(behind, when: Instrument.overdue))
                .frame(width: 62, alignment: .trailing)
            Figure(figure(dueNow), color: color(dueNow, when: Instrument.accentText))
                .frame(width: 70, alignment: .trailing)
            spark.frame(width: Self.sparkColumn, alignment: .trailing)
        }
    }

    private var behind: Int { forecast?.backlog ?? 0 }

    /// A deck nothing is scheduling has no count to report — a zero would read
    /// as "caught up", which is a different claim from "not playing".
    private func figure(_ count: Int) -> String {
        forecast == nil ? "—" : "\(count)"
    }

    /// A figure only wears its status colour when it *is* one. The dash a
    /// sidelined deck shows is not an urgent nothing.
    private func color(_ count: Int, when hot: Color) -> Color {
        forecast != nil && count > 0 ? hot : Instrument.muted
    }

    @ViewBuilder private var spark: some View {
        if let forecast {
            ForecastSpark(forecast: forecast, ceiling: ceiling)
        } else {
            Color.clear.frame(height: 1)
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
