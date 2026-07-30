import Foundation
import GRDB
import Testing
@testable import ShifuCore

@Suite struct ReviewGateTests {
    private func deck(
        _ key: String, paused: Bool = false, newPerDay: Int? = nil
    ) -> DeckStore.Deck {
        DeckStore.Deck(
            id: 1, key: key, taskKey: "sem:task", taskName: "Task", title: key,
            status: .ready, createdAt: 0, builtAt: nil, cardCount: 0,
            paused: paused, newPerDay: newPerDay)
    }

    private func card(_ topic: String, deck: String?, reps: Int) -> Note {
        Note(topic: topic, taskKey: "sem:task", deck: deck, state: .kept,
             srs: FSRS.State(due: Date(timeIntervalSince1970: 0), reps: reps),
             body: "ref\n\nQ: q?\nA: a.")
    }

    @Test func pausedDeckSitsOutEntirely() {
        let due = [card("new", deck: "deck:a", reps: 0),
                   card("seen", deck: "deck:a", reps: 3),
                   card("loose", deck: nil, reps: 0)]
        let gated = ReviewGate.schedulable(
            due, decks: [deck("deck:a", paused: true)], introducedToday: [:])
        #expect(gated.map(\.topic) == ["loose"])
    }

    @Test func capAdmitsOnlyTheRemainingAllowanceOfNewCards() {
        let due = [card("n1", deck: "deck:a", reps: 0),
                   card("n2", deck: "deck:a", reps: 0),
                   card("n3", deck: "deck:a", reps: 0),
                   card("seen", deck: "deck:a", reps: 2)]
        let gated = ReviewGate.schedulable(
            due, decks: [deck("deck:a", newPerDay: 3)],
            introducedToday: ["deck:a": 2])
        // Two of today's three were already introduced, so one new card gets
        // in — and the review card is never gated.
        #expect(gated.map(\.topic) == ["n1", "seen"])
    }

    @Test func spentAllowanceAdmitsReviewsButNoNewCards() {
        let due = [card("n1", deck: "deck:a", reps: 0),
                   card("seen", deck: "deck:a", reps: 5)]
        let gated = ReviewGate.schedulable(
            due, decks: [deck("deck:a", newPerDay: 20)],
            introducedToday: ["deck:a": 20])
        #expect(gated.map(\.topic) == ["seen"])
    }

    @Test func uncappedAndForeignDecksPassUntouched() {
        let due = [card("n1", deck: "deck:a", reps: 0),
                   card("gone", deck: "deck:pruned-away", reps: 0),
                   card("loose", deck: nil, reps: 0)]
        let gated = ReviewGate.schedulable(
            due, decks: [deck("deck:a")], introducedToday: [:])
        #expect(gated.count == 3)
    }

    /// The SQL half: only *first* grades today count against the allowance —
    /// a card reviewed yesterday and again today is a review, not an
    /// introduction, however many times it comes back today.
    @Test func introducedTodayCountsFirstGradesOnly() throws {
        let database = try ShifuDatabase.inMemory()
        let dayMs: Int64 = 86_400_000
        let todayMs = Int64(Calendar.current.startOfDay(for: Date())
            .timeIntervalSince1970 * 1_000) + 3_600_000
        try database.queue.write { db in
            for (note, deckKey) in [("n1", "deck:a"), ("n2", "deck:a"), ("old", "deck:a"),
                                    ("other", "deck:b")] {
                try db.execute(sql: """
                    INSERT INTO vault_index (note_id, path, kind, captured, content_hash,
                                             mtime, deck_key)
                    VALUES (?, ?, 'note', 0, 0, 0, ?)
                    """, arguments: [note, "\(note).md", deckKey])
            }
            // Two introductions in deck:a today, one in deck:b; "old" was
            // introduced yesterday and reviewed again today.
            for (note, at) in [("n1", todayMs), ("n2", todayMs + 60_000),
                               ("old", todayMs - dayMs), ("old", todayMs + 120_000),
                               ("other", todayMs)] {
                try db.execute(sql: """
                    INSERT INTO srs_reviews (note_id, reviewed_at, grade, interval_days)
                    VALUES (?, ?, 3, 1.0)
                    """, arguments: [note, at])
            }
        }
        let introduced = try ReviewGate.introducedToday(database: database)
        #expect(introduced["deck:a"] == 2)
        #expect(introduced["deck:b"] == 1)
    }
}
