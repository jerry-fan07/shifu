import Foundation
import ShifuCore

/// Vault triage and review actions (design.md §5.1–5.2), plus the Cards
/// screen's heatmap span. Split out of LedgerStore.swift for length only;
/// `refreshVaultNotes` stays there because it writes the store's own
/// `private(set)` state.
@MainActor
extension LedgerStore {
    /// Everything one vault walk yields, so the walk can live out here while
    /// the store keeps its `private(set)` publishing to itself.
    struct VaultSnapshot {
        var cards: [Note] = []
        var due: [Note] = []
        var reviewsByDay: [Date: Int] = [:]
    }

    /// One vault walk feeding the review queue and the Cards screens.
    /// Queues are sorted most-urgent first (earliest due date; cards that
    /// never entered scheduling sort ahead of everything).
    func vaultSnapshot() -> VaultSnapshot {
        var snapshot = VaultSnapshot()
        let notes = (try? vault.allNotes()) ?? []
        snapshot.cards = notes
            .filter { $0.state == .kept && $0.questionAnswer != nil }
            .sorted { ($0.srs?.due ?? .distantPast) < ($1.srs?.due ?? .distantPast) }
        let now = Date()
        snapshot.due = snapshot.cards.filter { $0.srs.map { $0.due <= now } ?? true }
        // Deck review settings (§5.2): paused decks sit out, capped decks
        // introduce only today's allowance of new cards. The cards list keeps
        // everything — settings shape the queue, not the shelf. Sorted
        // earliest-due first above, so the allowance goes to the oldest cards.
        if let database = try? db() {
            snapshot.due = ReviewGate.schedulable(
                snapshot.due,
                decks: (try? DeckStore.decks(database: database)) ?? [],
                introducedToday: (try? ReviewGate.introducedToday(
                    database: database, now: now)) ?? [:])
        }
        // A week of slack so the heatmap's week-aligned first column has
        // counts for its leading days too.
        let heatmapStart = Calendar.current.date(
            byAdding: .day, value: -(HeatmapSpan.days + 7),
            to: Calendar.current.startOfDay(for: now))!
        let log = (try? vault.reviewLog(since: heatmapStart)) ?? []
        snapshot.reviewsByDay = log.reduce(into: [:]) { counts, date in
            counts[Calendar.current.startOfDay(for: date), default: 0] += 1
        }
        return snapshot
    }

    /// The task's living overview document, if the compiler has written one
    /// (vault-features.md §2.1). Read from the file rather than the index —
    /// it is one known path, and the index is disposable.
    func taskOverview(taskKey: String) -> TaskOverview? {
        vault.taskOverview(taskKey: taskKey)
    }

    /// How far back the review-activity heatmap looks (26 weeks ≈ 6 months).
    enum HeatmapSpan {
        static let weeks = 26
        static let days = weeks * 7
    }

    /// Cards outside every live deck: kept before decks existed, or stamped
    /// for a deck whose task has since been pruned or merged away. They still
    /// serve the All queue (§5.2) — shared by the Decks shelf row and the
    /// page behind it.
    var looseCards: [Note] {
        let live = Set(decks.map(\.key))
        return allCards.filter { card in
            guard let deck = card.deck else { return true }
            return !live.contains(deck)
        }
    }

    /// The cards a forecast may count: the shelf, less whatever a paused deck
    /// holds. A paused deck's cards are out of every queue and count (§5.2), so
    /// they are not coming due — drawing them as load ahead would put a wall on
    /// the chart that no amount of reviewing could clear. Same rule the shelf's
    /// per-deck "due now" column follows, so the band and the rows can't
    /// disagree.
    var scheduledCards: [Note] {
        let paused = Set(decks.filter(\.paused).map(\.key))
        guard !paused.isEmpty else { return allCards }
        return allCards.filter { card in
            guard let deck = card.deck else { return true }
            return !paused.contains(deck)
        }
    }

    var reviewsToday: Int {
        reviewsByDay[Calendar.current.startOfDay(for: Date())] ?? 0
    }

    /// Consecutive days ending today with at least one review. Today counts
    /// only once it has one, so an unstarted morning doesn't read as a break —
    /// the run is measured back from yesterday until then.
    var reviewStreak: Int? {
        let calendar = Calendar.current
        var day = calendar.startOfDay(for: Date())
        if reviewsByDay[day] == nil {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: day)
            else { return nil }
            day = yesterday
        }
        var run = 0
        while let count = reviewsByDay[day], count > 0 {
            run += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day)
            else { break }
            day = previous
        }
        return run > 0 ? run : nil
    }

    /// The middle scheduled interval across cards that have been reviewed at
    /// least once — the one number that says whether the deck is settling or
    /// still churning. Nil until something has been graded.
    var medianIntervalDays: Int? {
        let intervals = allCards
            .compactMap { $0.srs }
            .filter { $0.reps > 0 }
            .map(\.intervalDays)
            .sorted()
        guard !intervals.isEmpty else { return nil }
        return Int(intervals[intervals.count / 2].rounded())
    }

    func discard(_ note: Note) {
        try? vault.discard(note)
        refreshSoon()
    }

    func review(_ note: Note, grade: FSRS.Grade) {
        _ = try? vault.review(note, grade: grade)
        refreshSoon()
    }

    /// Persists a card edit (topic + reference + Q/A) from the card editor.
    /// The file keeps its identity — `VaultStore.save` finds it by id.
    func updateCard(
        _ note: Note, topic: String, reference: String, question: String, answer: String
    ) {
        var updated = note
        let trimmedTopic = topic.trimmingCharacters(in: .whitespaces)
        if !trimmedTopic.isEmpty { updated.topic = trimmedTopic }
        let hasQA = !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // Clearing the Q/A demotes the card to a reference note (§5.1).
        updated.body = hasQA
            ? Note.composeBody(reference: reference, question: question, answer: answer)
            : reference.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try? vault.save(updated)
        refreshSoon()
    }
}
