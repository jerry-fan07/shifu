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
                } trailing: {
                    reviewSettings(deck)
                }
                PageBody {
                    if cards.isEmpty {
                        BlankSlate(
                            deck.status == .ready
                                ? "Nothing left — every card was pruned during review."
                                : "The first cards arrive with the next analysis run.")
                    } else {
                        CardTable(cards: cards) { editing = $0 }
                    }
                }
            }
        }
        .onAppear { store.refresh() }
        .sheet(item: $editing) { note in CardEditSheet(note: note) }
    }

    private func subtitle(_ deck: DeckStore.Deck) -> String {
        var parts: [String] = []
        if deck.title != deck.taskName { parts.append("from \(deck.taskName)") }
        let due = store.dueNotes.filter { $0.deck == deck.key }.count
        parts.append("\(due) due now")
        if deck.status != .ready {
            parts.append("building — the rest arrive with the next analysis run")
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
