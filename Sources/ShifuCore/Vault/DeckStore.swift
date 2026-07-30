import Foundation
import GRDB

/// Read/write API over flashcard decks (design.md §5.2). A deck is the only
/// thing that mints cards now: automatic extraction writes Q&A-free reference
/// notes, and every card in the review queue traces back to a deck the user
/// asked for — either by accepting a suggestion or by pressing the button on a
/// task's page. The request *is* the confirmation, so deck cards skip the
/// inbox and are born `kept` with FSRS seeded; pruning happens during review.
///
/// Building a deck needs the network, which only `shifu-analyzer` may touch
/// (§8), so the app requests a build by launching the analyzer with
/// `--build-deck <key>`. There is no analyzer single-instance lock, so
/// concurrent builds are kept apart by the compare-and-set on `status` here
/// rather than by a lock: `claimForBuild` is the only door in.
public enum DeckStore {
    public static let keyPrefix = "deck:"

    /// Where a deck sits in its one-way lifecycle. `pending` is a deck with
    /// nothing but its sample cards; `building` is claimed by an analyzer
    /// process; `ready` has its full card set.
    public enum Status: String, Sendable {
        case pending
        case building
        case ready
    }

    /// How long a claim may sit in `building` before another process may take
    /// it. A build is two LLM calls; an hour means the claimant crashed.
    public static let staleClaimMs: Int64 = 3_600_000

    /// How many never-reviewed cards a freshly minted deck may introduce per
    /// day. Chosen so a big deck drips in over weeks rather than landing due
    /// all at once; the deck page can raise it, lower it, or lift it.
    public static let defaultNewPerDay = 20

    /// How many cards the user asked the deck to hold. A range, not a number,
    /// because a model can honour "5-10" where it cannot hit "7"; `upper` is
    /// also enforced in code by the builder, so it is a real ceiling. Absent
    /// entirely for automatic sizing — the builder judges, no hard limit.
    public struct CardRange: Hashable, Sendable {
        public var lower: Int
        public var upper: Int

        public init(lower: Int, upper: Int) {
            self.lower = lower
            self.upper = upper
        }

        /// Both columns or neither: a lone bound is a write-path bug read
        /// back as automatic rather than as a crash.
        init?(lower: Int?, upper: Int?) {
            guard let lower, let upper else { return nil }
            self.init(lower: lower, upper: upper)
        }
    }

    /// One deck as the UI sees it. `cardCount` is derived from `vault_index`
    /// on every read, never stored — the user prunes cards during review, so a
    /// stored count would start drifting the moment the feature is used as
    /// designed. `paused` and `newPerDay` are the deck's review settings,
    /// applied by `ReviewGate` wherever a due queue is built.
    public struct Deck: Identifiable, Sendable, Equatable {
        public var id: Int64
        public var key: String
        public var taskKey: String
        public var taskName: String
        public var title: String
        public var status: Status
        public var createdAt: Int64
        public var builtAt: Int64?
        public var cardCount: Int
        public var paused: Bool
        /// Nil is uncapped.
        public var newPerDay: Int?
        /// What the user asked the deck to be about, verbatim; the builder
        /// folds it into its prompt. Nil when none were given.
        public var instructions: String?
        /// How many cards were asked for. Nil is automatic — no hard limit.
        public var cardRange: CardRange?
    }

    /// The deck row the builder works from. No task name: a claim must not
    /// depend on the task still existing (prune and merge delete task rows),
    /// and a deck whose task is gone still has to reach `ready` so the drain
    /// stops retrying it.
    public struct Claim: Sendable, Equatable {
        public var key: String
        public var taskKey: String
        public var title: String
        /// Rides the claim so a drain retry, in a process the page never
        /// touched, still builds the deck the user described.
        public var instructions: String?
        /// Rides for the same reason; the builder holds `upper` as a hard
        /// ceiling, not just a prompt line.
        public var cardRange: CardRange?
    }

    /// One proposed card, shown on the suggestion before the user commits and
    /// written verbatim as the deck's first card on accept.
    public struct SampleCard: Codable, Sendable, Equatable {
        public var topic: String
        public var note: String
        public var question: String
        public var answer: String

        public init(topic: String, note: String, question: String, answer: String) {
            self.topic = topic
            self.note = note
            self.question = question
            self.answer = answer
        }
    }

    /// `deck:` + the task key's slug. Derived from the (already unique) task
    /// key and never from the title — see the v17 migration note.
    public static func key(forTaskKey taskKey: String) -> String {
        keyPrefix + VaultStore.taskSlug(taskKey)
    }

    // MARK: - Queries

    /// Decks whose task still exists, newest first. Rows for pruned or
    /// merged-away tasks drop out of the UI here rather than being deleted:
    /// their cards stay in the vault and keep serving the All queue.
    public static func decks(database: ShifuDatabase) throws -> [Deck] {
        try database.queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT d.id, d.key, d.task_key, d.title, d.status, d.created_at, d.built_at,
                       d.paused, d.new_per_day, d.instructions, d.cards_min, d.cards_max,
                       t.name AS task_name,
                       (SELECT COUNT(*) FROM vault_index vi WHERE vi.deck_key = d.key)
                           AS card_count
                FROM decks d JOIN tasks t ON t.key = d.task_key
                ORDER BY d.created_at DESC
                """).map(deck(from:))
        }
    }

    /// The task's deck, if it has one. Used by the task page to swap its
    /// "Create flashcard deck" button for the deck's live state.
    public static func deck(taskKey: String, database: ShifuDatabase) throws -> Deck? {
        try database.queue.read { db in
            try Row.fetchOne(db, sql: """
                SELECT d.id, d.key, d.task_key, d.title, d.status, d.created_at, d.built_at,
                       d.paused, d.new_per_day, d.instructions, d.cards_min, d.cards_max,
                       t.name AS task_name,
                       (SELECT COUNT(*) FROM vault_index vi WHERE vi.deck_key = d.key)
                           AS card_count
                FROM decks d JOIN tasks t ON t.key = d.task_key
                WHERE d.task_key = ?
                """, arguments: [taskKey]).map(deck(from:))
        }
    }

    /// How many cards are filed under a deck — always derived, never stored.
    public static func cardCount(deckKey: String, database: ShifuDatabase) throws -> Int {
        try database.queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM vault_index WHERE deck_key = ?",
                             arguments: [deckKey]) ?? 0
        }
    }

    // MARK: - Decks

    /// Mints a deck for a task, or returns the key of the one already there —
    /// one deck per task, so pressing Create twice is a no-op rather than a
    /// second deck (refresh/regeneration is deferred, design.md §12). The New
    /// deck page passes the settings its form collected; the other routes
    /// (task page, suggestion accept) take the defaults.
    @discardableResult
    public static func create(
        title: String, taskKey: String, instructions: String? = nil,
        cardRange: CardRange? = nil, newPerDay: Int? = defaultNewPerDay,
        paused: Bool = false, database: ShifuDatabase, now: Date = Date()
    ) throws -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let brief = instructions?.trimmingCharacters(in: .whitespacesAndNewlines)
        let deckKey = key(forTaskKey: taskKey)
        let nowMs = Int64(now.timeIntervalSince1970 * 1_000)
        try database.queue.write { db in
            try db.execute(sql: """
                INSERT INTO decks (key, task_key, title, status, status_at, created_at,
                                   new_per_day, paused, instructions, cards_min, cards_max)
                VALUES (?, ?, ?, 'pending', ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(key) DO NOTHING
                """, arguments: [deckKey, taskKey, trimmed, nowMs, nowMs, newPerDay,
                                 paused, brief?.isEmpty == false ? brief : nil,
                                 cardRange?.lower, cardRange?.upper])
        }
        return deckKey
    }

    // MARK: - Management (design.md §5.2)

    /// Retitles a deck. Cards carry the deck *key*, never the title, so a
    /// rename touches one row and nothing else.
    public static func rename(key deckKey: String, to title: String,
                              database: ShifuDatabase) throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try database.queue.write { db in
            try db.execute(sql: "UPDATE decks SET title = ? WHERE key = ?",
                           arguments: [trimmed, deckKey])
        }
    }

    /// A paused deck's cards sit out every queue and every due count until it
    /// is resumed — `ReviewGate` reads the flag, nothing else changes.
    public static func setPaused(key deckKey: String, _ paused: Bool,
                                 database: ShifuDatabase) throws {
        try database.queue.write { db in
            try db.execute(sql: "UPDATE decks SET paused = ? WHERE key = ?",
                           arguments: [paused, deckKey])
        }
    }

    /// Nil lifts the daily new-card cap.
    public static func setNewPerDay(key deckKey: String, _ cap: Int?,
                                    database: ShifuDatabase) throws {
        try database.queue.write { db in
            try db.execute(sql: "UPDATE decks SET new_per_day = ? WHERE key = ?",
                           arguments: [cap, deckKey])
        }
    }

    /// Deletes a deck *and the cards it minted* — the deck is why they exist,
    /// so they go together rather than being orphaned into the loose group
    /// (the §12 decision). The review log in `srs_reviews` stays: it records
    /// what happened, not what is kept. A dismissed `deck_suggestions` row is
    /// written under the task key so the weekly suggester can't propose back
    /// what was just thrown away; the task page button and the New deck menu
    /// remain the deliberate routes back.
    public static func delete(_ deck: Deck, database: ShifuDatabase, vault: VaultStore,
                              now: Date = Date()) throws {
        for note in try vault.allNotes() where note.deck == deck.key {
            try vault.discard(note)
        }
        let nowMs = Int64(now.timeIntervalSince1970 * 1_000)
        try database.queue.write { db in
            try db.execute(sql: "DELETE FROM decks WHERE key = ?", arguments: [deck.key])
            try db.execute(sql: """
                INSERT INTO deck_suggestions (task_key, status, created_at)
                VALUES (?, 'dismissed', ?)
                ON CONFLICT(task_key) DO UPDATE SET status = 'dismissed'
                """, arguments: [deck.taskKey, nowMs])
        }
    }

    /// Writes one card into a deck: kept, FSRS-seeded, `deck:`-stamped, and
    /// deduped only against its own deck (see `VaultStore.mergeIfDuplicate`).
    /// Returns false when an equivalent card was already there.
    @discardableResult
    public static func write(
        _ card: SampleCard, deckKey: String, taskKey: String, vault: VaultStore,
        confidence: Double? = nil, now: Date = Date()
    ) throws -> Bool {
        let note = Note(
            captured: now, topic: card.topic, taskKey: taskKey, deck: deckKey,
            confidence: confidence, state: .kept,
            srs: FSRS.State(due: now),
            body: Note.composeBody(reference: card.note, question: card.question,
                                   answer: card.answer))
        guard try !vault.mergeIfDuplicate(of: note, inDeck: deckKey) else { return false }
        try vault.save(note)
        return true
    }

    // MARK: - Build lifecycle (compare-and-set, not a lock)

    /// Claims a deck for building. Exactly one caller wins: the UPDATE's
    /// WHERE clause is the compare half, and a second process sees zero rows
    /// changed. A claim older than `staleClaimMs` is reclaimable — the
    /// claimant crashed, and without this the deck would sit `building`
    /// forever with no way back.
    public static func claimForBuild(
        key deckKey: String, database: ShifuDatabase, now: Date = Date()
    ) throws -> Claim? {
        let nowMs = Int64(now.timeIntervalSince1970 * 1_000)
        return try database.queue.write { db in
            try db.execute(sql: """
                UPDATE decks SET status = 'building', status_at = ?
                WHERE key = ? AND (status = 'pending'
                                   OR (status = 'building' AND status_at < ?))
                """, arguments: [nowMs, deckKey, nowMs - staleClaimMs])
            guard db.changesCount == 1 else { return nil }
            return try Row.fetchOne(
                db, sql: """
                    SELECT key, task_key, title, instructions, cards_min, cards_max
                    FROM decks WHERE key = ?
                    """,
                arguments: [deckKey]
            ).map { Claim(key: $0["key"], taskKey: $0["task_key"], title: $0["title"],
                          instructions: $0["instructions"],
                          cardRange: CardRange(lower: $0["cards_min"],
                                               upper: $0["cards_max"])) }
        }
    }

    /// Every `pending` deck, oldest first — the hourly drain's work list, and
    /// the safety net for builds that died keyless or mid-flight.
    public static func pendingDeckKeys(database: ShifuDatabase) throws -> [String] {
        try database.queue.read { db in
            try String.fetchAll(db, sql: """
                SELECT key FROM decks WHERE status = 'pending' ORDER BY created_at
                """)
        }
    }

    public static func markReady(
        key deckKey: String, database: ShifuDatabase, now: Date = Date()
    ) throws {
        let nowMs = Int64(now.timeIntervalSince1970 * 1_000)
        try database.queue.write { db in
            try db.execute(sql: """
                UPDATE decks SET status = 'ready', status_at = ?, built_at = ? WHERE key = ?
                """, arguments: [nowMs, nowMs, deckKey])
        }
    }

    /// Hands a failed claim back so the next drain retries it.
    public static func releaseClaim(
        key deckKey: String, database: ShifuDatabase, now: Date = Date()
    ) throws {
        let nowMs = Int64(now.timeIntervalSince1970 * 1_000)
        try database.queue.write { db in
            try db.execute(sql: """
                UPDATE decks SET status = 'pending', status_at = ?
                WHERE key = ? AND status = 'building'
                """, arguments: [nowMs, deckKey])
        }
    }

    // MARK: - Plumbing

    private static func deck(from row: Row) -> Deck {
        Deck(id: row["id"], key: row["key"], taskKey: row["task_key"],
             taskName: row["task_name"], title: row["title"],
             status: Status(rawValue: row["status"]) ?? .pending,
             createdAt: row["created_at"], builtAt: row["built_at"],
             cardCount: row["card_count"], paused: row["paused"],
             newPerDay: row["new_per_day"], instructions: row["instructions"],
             cardRange: CardRange(lower: row["cards_min"], upper: row["cards_max"]))
    }

}
