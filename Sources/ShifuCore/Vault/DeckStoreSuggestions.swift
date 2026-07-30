import Foundation
import GRDB

/// The proposal half of `DeckStore` (design.md §5.2), split from
/// DeckStore.swift for type length only: everything about an offer that has
/// not yet been said yes to, and the accept that turns one into a deck.
extension DeckStore {
    /// An open deck proposal awaiting Create/Dismiss on the Cards screen.
    public struct PendingSuggestion: Identifiable, Sendable, Equatable {
        public var id: Int64
        public var taskKey: String
        public var taskName: String
        public var title: String
        public var samples: [SampleCard]
    }

    // MARK: - Queries

    /// Open proposals, oldest first. JOINs tasks for the same reason `decks`
    /// does — a proposal for a task that no longer exists is noise.
    public static func pendingSuggestions(database: ShifuDatabase) throws -> [PendingSuggestion] {
        try database.queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT s.id, s.task_key, s.title, s.sample_cards, t.name AS task_name
                FROM deck_suggestions s JOIN tasks t ON t.key = s.task_key
                WHERE s.status = 'new' ORDER BY s.created_at
                """).compactMap { row in
                guard let title = row["title"] as String?,
                      let raw = row["sample_cards"] as String? else { return nil }
                return PendingSuggestion(
                    id: row["id"], taskKey: row["task_key"], taskName: row["task_name"],
                    title: title, samples: decodeSamples(raw))
            }
        }
    }

    /// How many open proposals are actually shown to the user. Counts only
    /// rows that still JOIN a live task, so an orphan can never consume the
    /// suggester's cap — belt to `TaskPrune`/`TaskMerging`'s suspenders.
    public static func openSuggestionCount(database: ShifuDatabase) throws -> Int {
        try database.queue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM deck_suggestions s JOIN tasks t ON t.key = s.task_key
                WHERE s.status = 'new'
                """) ?? 0
        }
    }

    /// Task keys with a deck or a suggestion of any status — the suggester
    /// skips all of them, so a dismissal or a `worth: false` verdict is never
    /// re-billed.
    public static func spokenForTaskKeys(database: ShifuDatabase) throws -> Set<String> {
        try database.queue.read { db in
            var keys = Set(try String.fetchAll(db, sql: "SELECT task_key FROM decks"))
            keys.formUnion(try String.fetchAll(db, sql: "SELECT task_key FROM deck_suggestions"))
            return keys
        }
    }

    // MARK: - The proposal lifecycle

    /// Files a proposal the suggester judged worth building.
    public static func suggest(
        taskKey: String, title: String, samples: [SampleCard],
        database: ShifuDatabase, now: Date = Date()
    ) throws {
        let nowMs = Int64(now.timeIntervalSince1970 * 1_000)
        let json = encodeSamples(samples)
        try database.queue.write { db in
            try db.execute(sql: """
                INSERT INTO deck_suggestions (task_key, title, sample_cards, status, created_at)
                VALUES (?, ?, ?, 'new', ?)
                ON CONFLICT(task_key) DO NOTHING
                """, arguments: [taskKey, title, json, nowMs])
        }
    }

    /// Records that the model judged a task not worth a deck. The row is the
    /// memory: a declined task is never evaluated again, which is what keeps
    /// the weekly probe from re-billing the same verdict forever.
    public static func decline(
        taskKey: String, database: ShifuDatabase, now: Date = Date()
    ) throws {
        let nowMs = Int64(now.timeIntervalSince1970 * 1_000)
        try database.queue.write { db in
            try db.execute(sql: """
                INSERT INTO deck_suggestions (task_key, status, created_at)
                VALUES (?, 'declined', ?)
                ON CONFLICT(task_key) DO NOTHING
                """, arguments: [taskKey, nowMs])
        }
    }

    /// The user said no. Like a declined row this is permanent — the task
    /// page's Create button is the escape hatch.
    public static func dismiss(suggestionID: Int64, database: ShifuDatabase) throws {
        try database.queue.write { db in
            try db.execute(sql: "UPDATE deck_suggestions SET status = 'dismissed' WHERE id = ?",
                           arguments: [suggestionID])
        }
    }

    /// The user said yes: mint the deck `pending`, write the sample cards as
    /// real kept cards (they were reviewable on the suggestion, so they are
    /// reviewable now — the deck's build only adds to them), and close the
    /// proposal. Returns the deck key for the caller to hand to `--build-deck`.
    @discardableResult
    public static func accept(
        _ suggestion: PendingSuggestion, database: ShifuDatabase, vault: VaultStore,
        now: Date = Date()
    ) throws -> String? {
        guard let deckKey = try create(title: suggestion.title, taskKey: suggestion.taskKey,
                                       database: database, now: now) else { return nil }
        for sample in suggestion.samples {
            try write(sample, deckKey: deckKey, taskKey: suggestion.taskKey,
                      vault: vault, now: now)
        }
        try database.queue.write { db in
            try db.execute(sql: "UPDATE deck_suggestions SET status = 'accepted' WHERE id = ?",
                           arguments: [suggestion.id])
        }
        return deckKey
    }

    // MARK: - Plumbing

    static func encodeSamples(_ samples: [SampleCard]) -> String {
        guard let data = try? JSONEncoder().encode(samples) else { return "[]" }
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    static func decodeSamples(_ json: String) -> [SampleCard] {
        guard let data = json.data(using: .utf8),
              let samples = try? JSONDecoder().decode([SampleCard].self, from: data)
        else { return [] }
        return samples
    }
}
