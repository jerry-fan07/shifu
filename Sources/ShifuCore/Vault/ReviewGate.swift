import Foundation
import GRDB

/// Applies deck review settings to a raw due list (design.md §5.2). Not a
/// scheduler — FSRS owns "when is this card due"; this owns "does its deck
/// let it into today's session". A paused deck's cards stay out entirely; a
/// deck with a daily new-card cap admits only what is left of today's
/// allowance. Due *reviews* are never gated — a review is owed, only the
/// introduction of never-reviewed cards is rationed, which is what keeps a
/// hundred-card deck (born due-now, all of it) from landing in one sitting.
///
/// Both queue builders go through here — the app's `LedgerStore` snapshot and
/// `VaultStore.due()` behind `shifu review` — so the CLI and the window can
/// never disagree about what today holds.
public enum ReviewGate {
    /// Filters `due` by its decks' settings. Allowance is spent in list
    /// order, so callers choose which new cards win by how they sort; cards
    /// outside any listed deck pass untouched (loose cards have no settings,
    /// and a deck whose task is gone dropped off the deck list with them).
    public static func schedulable(
        _ due: [Note], decks: [DeckStore.Deck], introducedToday: [String: Int]
    ) -> [Note] {
        let paused = Set(decks.filter(\.paused).map(\.key))
        var allowance: [String: Int] = [:]
        for deck in decks {
            if let cap = deck.newPerDay {
                allowance[deck.key] = max(0, cap - (introducedToday[deck.key] ?? 0))
            }
        }
        return due.filter { note in
            guard let deckKey = note.deck else { return true }
            if paused.contains(deckKey) { return false }
            guard isNew(note), let remaining = allowance[deckKey] else { return true }
            guard remaining > 0 else { return false }
            allowance[deckKey] = remaining - 1
            return true
        }
    }

    /// A card the scheduler has never seen — what the daily cap rations.
    static func isNew(_ note: Note) -> Bool { (note.srs?.reps ?? 0) == 0 }

    /// How many of each deck's cards got their *first* grade today — what
    /// today's allowance has already spent. First-ness comes from the review
    /// log rather than the card (its `reps` no longer says when rep one
    /// happened), so the count survives the card being graded again.
    public static func introducedToday(
        database: ShifuDatabase, now: Date = Date()
    ) throws -> [String: Int] {
        let startMs = Int64(Calendar.current.startOfDay(for: now)
            .timeIntervalSince1970 * 1_000)
        return try database.queue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT vi.deck_key AS deck_key, COUNT(DISTINCT r.note_id) AS introduced
                FROM srs_reviews r
                JOIN vault_index vi ON vi.note_id = r.note_id
                WHERE vi.deck_key IS NOT NULL
                  AND r.reviewed_at >= ?
                  AND NOT EXISTS (
                    SELECT 1 FROM srs_reviews earlier
                    WHERE earlier.note_id = r.note_id AND earlier.reviewed_at < ?
                  )
                GROUP BY vi.deck_key
                """, arguments: [startMs, startMs])
            return rows.reduce(into: [:]) { counts, row in
                counts[row["deck_key"]] = row["introduced"]
            }
        }
    }
}
