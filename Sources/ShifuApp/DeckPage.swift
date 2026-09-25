import ShifuCore
import SwiftUI

// One deck as a page, and the loose cards' page beside it (design.md §5.2).
// Split from PracticeViews.swift for length only — the Decks list that opens
// these lives there.

// MARK: - One deck's page

/// The deck page's rail: the way back, and the two things you can do to the
/// deck itself — the same shape as a theme's rail.
struct DeckContents: View {
    @EnvironmentObject private var store: LedgerStore
    @EnvironmentObject private var router: Router
    let deckID: Int64
    @State private var renaming = false
    @State private var draftTitle = ""
    @State private var confirmingDelete = false

    private var deck: DeckStore.Deck? {
        store.decks.first { $0.id == deckID }
    }

    var body: some View {
        RailColumn {
            RailBack(title: "Decks") { router.go(to: .decks) }
        } footer: {
            Button("Rename deck") {
                draftTitle = deck?.title ?? ""
                renaming = true
            }
            .buttonStyle(.plain)
            .font(Instrument.sans(11.5))
            .foregroundStyle(Instrument.railInk)
            Button("Delete deck") { confirmingDelete = true }
                .buttonStyle(.plain)
                .font(Instrument.sans(11.5))
                .foregroundStyle(Instrument.alert)
        }
        .alert("Rename deck", isPresented: $renaming) {
            TextField("Deck title", text: $draftTitle)
            Button("Rename") {
                if let deck {
                    store.renameDeck(key: deck.key, to: draftTitle)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Delete “\(deck?.title ?? "")”?", isPresented: $confirmingDelete
        ) {
            Button("Delete deck and its cards", role: .destructive) {
                if let deck { store.deleteDeck(deck) }
                router.go(to: .decks)
            }
        } message: {
            Text("Its \(deck?.cardCount ?? 0) cards go with it; the review log stays. "
                + "Shifu won't suggest this deck again — the task's own page still can "
                + "make one.")
        }
    }
}

/// One deck as a page: what it is and how it reviews in the head, every card
/// below — the expansion the Decks list deliberately doesn't inline.
struct DeckPage: View {
    @EnvironmentObject private var store: LedgerStore
    let deckID: Int64
    @State private var editing: Note?
    @State private var addingCards = false

    private var deck: DeckStore.Deck? {
        store.decks.first { $0.id == deckID }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let deck {
                let cards = store.allCards.filter { $0.deck == deck.key }
                HeroHead(
                    figure: "\(cards.count)",
                    caption: cards.count == 1 ? "card in this deck" : "cards in this deck"
                ) {
                    Text(subtitle(deck))
                        .font(Instrument.sans(12.5))
                        .foregroundStyle(Instrument.muted)
                        .lineLimit(2)
                } trailing: {
                    HStack(spacing: 7) {
                        addCardsControl(deck)
                        reviewSettings(deck)
                    }
                }
                PageBody {
                    if cards.isEmpty {
                        BlankSlate(
                            deck.status == .ready
                                ? "Nothing left — every card was pruned during review."
                                : "The first cards arrive with the next analysis run.")
                    } else {
                        chapteredTable(cards)
                    }
                }
            }
        }
        .onAppear { store.refresh() }
        .sheet(item: $editing) { note in CardEditSheet(note: note) }
        .sheet(isPresented: $addingCards) {
            if let deck { AddCardsSheet(deck: deck) }
        }
    }

    // MARK: Chapters

    /// One run of cards under one label — the section the "Add cards" build
    /// that wrote them was asked for (§5.2). `title` nil is the unlabelled
    /// first build.
    private struct Chapter {
        let title: String?
        let cards: [Note]
    }

    /// The deck's cards, grouped by the chapter that added them. One flat
    /// table until a labelled chapter exists — a deck never grown needs no
    /// headings — with the unlabelled first build reading first.
    @ViewBuilder private func chapteredTable(_ cards: [Note]) -> some View {
        let chapters = chapters(cards)
        if chapters.count == 1 {
            CardTable(cards: cards) { editing = $0 }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                CardColumnHead()
                ForEach(chapters, id: \.title) { chapter in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Eyebrow(chapter.title ?? "First cards")
                        Figure("\(chapter.cards.count)", color: Instrument.muted)
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 18)
                    .padding(.bottom, 4)
                    CardRows(cards: chapter.cards) { editing = $0 }
                }
            }
        }
    }

    private func chapters(_ cards: [Note]) -> [Chapter] {
        var order: [String?] = []
        var groups: [String?: [Note]] = [:]
        for card in cards {
            if groups[card.section] == nil { order.append(card.section) }
            groups[card.section, default: []].append(card)
        }
        if let index = order.firstIndex(of: nil), index != 0 {
            order.remove(at: index)
            order.insert(nil, at: 0)
        }
        return order.map { Chapter(title: $0, cards: groups[$0] ?? []) }
    }

    // MARK: Head

    /// The way a deck grows (§5.2): a new build pass over the same task,
    /// narrowed to its own topics and grouped as a chapter. Only a ready
    /// deck takes one — an in-flight build owns the request columns — and
    /// without a backend nothing could run it.
    @ViewBuilder private func addCardsControl(_ deck: DeckStore.Deck) -> some View {
        if store.hasLLMBackend && deck.status == .ready {
            OutlineButton(title: "Add cards") { addingCards = true }
        }
    }

    private func subtitle(_ deck: DeckStore.Deck) -> String {
        var parts: [String] = []
        if deck.title != deck.taskName { parts.append("from \(deck.taskName)") }
        let due = store.dueNotes.filter { $0.deck == deck.key }.count
        parts.append("\(due) due now")
        // What the deck was asked to be — the size and the brief, as one part
        // so "asked for" is never said twice.
        switch (deck.cardRange, deck.instructions) {
        case let (range?, brief?):
            parts.append("asked for \(range.lower)–\(range.upper) cards — \(brief)")
        case let (range?, nil):
            parts.append("asked for \(range.lower)–\(range.upper) cards")
        case let (nil, brief?):
            parts.append("asked for: \(brief)")
        case (nil, nil):
            break
        }
        if deck.status != .ready {
            // A first build and an addition wear different words: the deck
            // mid-addition is still fully reviewable, and "building" over a
            // hundred settled cards would read as none of them counting.
            parts.append(deck.everBuilt
                ? "adding cards — they arrive with the next analysis run"
                : "building — the rest arrive with the next analysis run")
        }
        if deck.paused {
            parts.append("paused — its cards sit out every queue")
        }
        return parts.joined(separator: " · ")
    }

    /// The deck's two review settings (§5.2): how many new cards a day it may
    /// introduce, and whether it reviews at all. Both act through the queue
    /// gate, so the due figures on this page answer them immediately.
    private func reviewSettings(_ deck: DeckStore.Deck) -> some View {
        HStack(spacing: 7) {
            FilterMenu(
                prefix: "New cards",
                options: newPerDayOptions(deck),
                selection: Binding(
                    get: { deck.newPerDay },
                    set: { store.setDeckNewPerDay(key: deck.key, $0) }))
            OutlineButton(title: deck.paused ? "Resume reviews" : "Pause reviews") {
                store.setDeckPaused(key: deck.key, !deck.paused)
            }
        }
    }

    /// The standard steps, plus whatever nonstandard cap is already stored so
    /// the menu never shows an empty label.
    private func newPerDayOptions(_ deck: DeckStore.Deck) -> [(label: String, value: Int?)] {
        var caps = [5, 10, 20, 40]
        if let current = deck.newPerDay, !caps.contains(current) {
            caps.append(current)
            caps.sort()
        }
        var options: [(label: String, value: Int?)] = caps.map { ("\($0) a day", $0) }
        options.append(("No daily cap", nil))
        return options
    }
}

// MARK: - The Add cards sheet

/// The form a deck grows on (§5.2): which of its task's topics the new
/// chapter draws from, what the chapter is called, an optional brief, and
/// how many cards. A sheet rather than a page — the deck already has the
/// page, and the request belongs to it. Submitting re-opens the deck's build
/// request and launches the analyzer; the deck keeps reviewing meanwhile.
struct AddCardsSheet: View {
    @EnvironmentObject private var store: LedgerStore
    @Environment(\.dismiss) private var dismiss
    let deck: DeckStore.Deck

    @State private var topicOptions: [String] = []
    @State private var pickedTopics: Set<String> = []
    @State private var chapter = ""
    /// The last chapter name this form wrote itself — a typed name survives
    /// topic churn, an untouched one keeps following the selection.
    @State private var autoChapter = ""
    @State private var instructions = ""
    @State private var cardRange: DeckStore.CardRange?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add cards to “\(deck.title)”")
                .font(.title3)
                .bold()
            Text("A new pass over the task's screen time. The cards land in this "
                + "deck as their own chapter and review under its existing settings.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if topicOptions.count > 1 {
                        labelled("Topics the new cards may cover") {
                            TopicChecklist(options: topicOptions,
                                           selection: $pickedTopics)
                        }
                    }
                    labelled("Chapter — how the cards are grouped on the deck's page") {
                        TextField("Chapter name", text: $chapter)
                            .textFieldStyle(.roundedBorder)
                    }
                    labelled("Instructions — optional, followed on this build "
                        + "and every retry") {
                        TextEditor(text: $instructions)
                            .font(.system(size: 12.5))
                            .frame(minHeight: 54)
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .strokeBorder(.quaternary)
                            )
                    }
                    labelled("Card count — a range's top is enforced, not just asked for") {
                        SegmentedBar(options: cardCountOptions, selection: $cardRange)
                    }
                }
                .padding(.vertical, 2)
            }
            footer
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 440)
        .onAppear {
            topicOptions = store.deckTopicOptions(taskKey: deck.taskKey)
            pickedTopics = Set(topicOptions)
        }
        .onChange(of: pickedTopics) { followTopics() }
    }

    /// The same ladder as the New deck form, whose top the build enforces.
    private var cardCountOptions: [(label: String, value: DeckStore.CardRange?)] {
        [("Automatic", nil),
         ("3–5", DeckStore.CardRange(lower: 3, upper: 5)),
         ("5–10", DeckStore.CardRange(lower: 5, upper: 10)),
         ("10–30", DeckStore.CardRange(lower: 10, upper: 30))]
    }

    /// Nil when the checklist wasn't narrowed: the pass reads every topic.
    private var narrowedTopics: [String]? {
        guard topicOptions.count > 1, pickedTopics.count < topicOptions.count
        else { return nil }
        return topicOptions.filter(pickedTopics.contains)
    }

    /// A narrowed pass names its own chapter until the user renames it —
    /// "Genetics · Heredity" for free beats an unlabelled group.
    private func followTopics() {
        let trimmed = chapter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty || trimmed == autoChapter else { return }
        let suggested = narrowedTopics?.joined(separator: " · ") ?? ""
        chapter = suggested
        autoChapter = suggested
    }

    /// A shown checklist needs at least one topic left on — unchecking
    /// everything asks for a pass over nothing.
    private var canAdd: Bool {
        topicOptions.count <= 1 || !pickedTopics.isEmpty
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Add cards") {
                store.addCards(to: deck, instructions: instructions,
                               topics: narrowedTopics, cardRange: cardRange,
                               section: chapter)
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canAdd)
        }
    }

    private func labelled<Content: View>(
        _ label: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
        }
    }
}

// MARK: - The loose cards' page

/// The strays' rail: nothing but the way back and the reason they exist.
struct LooseContents: View {
    @EnvironmentObject private var router: Router

    var body: some View {
        RailColumn {
            RailBack(title: "Decks") { router.go(to: .decks) }
        } footer: {
            Text("Cards kept before decks existed, or whose deck's task is gone. "
                + "They serve the All queue.")
                .font(Instrument.sans(11.5))
                .foregroundStyle(Instrument.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The strays as their own page. Nothing to rename, pause, or delete — they
/// have no deck to hold the settings, which is the point of the group.
struct LooseCardsPage: View {
    @EnvironmentObject private var store: LedgerStore
    @State private var editing: Note?

    var body: some View {
        let cards = store.looseCards
        let due = Set(store.dueNotes.map(\.id))
        return VStack(spacing: 0) {
            HeroHead(
                figure: "\(cards.count)",
                caption: cards.count == 1 ? "loose card" : "loose cards"
            ) {
                Text("\(cards.filter { due.contains($0.id) }.count) due now · "
                    + "kept before decks existed, or left behind by a pruned task")
                    .font(Instrument.sans(12.5))
                    .foregroundStyle(Instrument.muted)
            } trailing: {
                EmptyView()
            }
            PageBody {
                CardTable(cards: cards) { editing = $0 }
            }
        }
        .onAppear { store.refresh() }
        .sheet(item: $editing) { note in CardEditSheet(note: note) }
    }
}
