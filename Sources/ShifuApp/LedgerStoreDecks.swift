import Foundation
import ShifuCore

/// The deck half of the read-side model (design.md §5.2). Split out of
/// LedgerStore.swift for length only — the state it reads is declared there.
@MainActor
extension LedgerStore {
    /// Accepting is a request, not a confirmation step: the sample cards land
    /// kept immediately and the rest of the deck builds in the background.
    func acceptDeckSuggestion(_ suggestion: DeckStore.PendingSuggestion) {
        guard let database = try? db(),
              let key = try? DeckStore.accept(suggestion, database: database, vault: vault)
        else { return }
        buildDeck(key: key)
        refreshSoon()
    }

    func dismissDeckSuggestion(_ suggestion: DeckStore.PendingSuggestion) {
        if let database = try? db() {
            try? DeckStore.dismiss(suggestionID: suggestion.id, database: database)
        }
        refreshSoon()
    }

    /// The manual route: a deck for a task the suggester never offered one for
    /// — and the escape hatch from a dismissed or declined proposal, which are
    /// otherwise permanent. Pressing it twice is a no-op; one deck per task.
    /// Returns the minted deck so the New deck page can land on it.
    @discardableResult
    func createDeck(
        taskKey: String, title: String, instructions: String? = nil,
        cardRange: DeckStore.CardRange? = nil,
        newPerDay: Int? = DeckStore.defaultNewPerDay, paused: Bool = false
    ) -> DeckStore.Deck? {
        guard let database = try? db(),
              let key = try? DeckStore.create(
                  title: title, taskKey: taskKey, instructions: instructions,
                  cardRange: cardRange, newPerDay: newPerDay, paused: paused,
                  database: database)
        else { return nil }
        buildDeck(key: key)
        refreshSoon()
        return (try? DeckStore.deck(taskKey: taskKey, database: database)) ?? nil
    }

    /// Asks the analyzer to fill a deck in. Only that binary may reach the
    /// network (§8), so a build is a launch of it.
    ///
    /// Unlike `runAnalysis` this carries no throttle. The deck row's own
    /// compare-and-set is the guard, and it is the better one: it makes a
    /// second builder a no-op even across processes, where a timestamp in this
    /// object only knows about the launches it made itself.
    func buildDeck(key: String) {
        if let existing = deckBuildProcess, existing.isRunning { return }
        guard let analyzerURL = ShifuPaths.helper("shifu-analyzer") else { return }
        let process = Process()
        process.executableURL = analyzerURL
        process.arguments = ["--force", "--build-deck", key]
        process.qualityOfService = .utility
        process.terminationHandler = { _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        do {
            try process.run()
            deckBuildProcess = process
        } catch {
            report(error)
        }
    }

    /// The task's deck, if it has one — the task page swaps its Create button
    /// for this deck's live state.
    func deck(taskKey: String) -> DeckStore.Deck? {
        guard let database = try? db() else { return nil }
        return (try? DeckStore.deck(taskKey: taskKey, database: database)) ?? nil
    }

    // MARK: - Management (deck page, design.md §5.2)

    func renameDeck(key: String, to title: String) {
        if let database = try? db() {
            try? DeckStore.rename(key: key, to: title, database: database)
        }
        refreshSoon()
    }

    /// Deletes the deck and its cards — `DeckStore.delete` owns the
    /// semantics; the confirmation dialog owns the asking.
    func deleteDeck(_ deck: DeckStore.Deck) {
        if let database = try? db() {
            try? DeckStore.delete(deck, database: database, vault: vault)
        }
        refreshSoon()
    }

    func setDeckPaused(key: String, _ paused: Bool) {
        if let database = try? db() {
            try? DeckStore.setPaused(key: key, paused, database: database)
        }
        refreshSoon()
    }

    func setDeckNewPerDay(key: String, _ cap: Int?) {
        if let database = try? db() {
            try? DeckStore.setNewPerDay(key: key, cap, database: database)
        }
        refreshSoon()
    }
}
