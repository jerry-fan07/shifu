import Foundation
import GRDB

/// The drafting queue (voice.md §4.1). Shaped like `decks` and for the same
/// reason: only `shifu-analyzer` may reach the network (invariant 1), so the
/// app cannot draft — it writes down that a draft was asked for and launches
/// the binary that can. There is no analyzer single-instance lock, so the
/// interactive launch and the hourly drain are kept apart by the
/// compare-and-set in `claim`, not by a lock.
public enum VoiceDrafts {
    /// `pending → drafting → ready`, or `→ failed`.
    ///
    /// `failed` is where this diverges from `DeckStore.Status`, deliberately.
    /// A deck build that fails hands its claim back and retries silently,
    /// because nobody is watching it. A draft has someone sitting in front of
    /// it: a request that quietly returned to `pending` would spin "Drafting…"
    /// forever with no reason on screen.
    public enum Status: String, Sendable {
        case pending
        case drafting
        case ready
        case failed
    }

    /// How long a claim may sit in `drafting` before another process may take
    /// it. A draft is one call, or two with the profile rebuild in front of
    /// it; ten minutes means the claimant died.
    public static let staleClaimMs: Int64 = 600_000
    /// How many requests the desk keeps. A drafting desk is not an archive —
    /// anything worth having is copied out (voice.md §4.4).
    public static let historyLimit = 20
    /// The ceiling on one request, so a pasted document to rewrite cannot push
    /// the voice profile and the excerpts out of the context window.
    public static let maxPromptChars = 20_000

    public struct Draft: Identifiable, Sendable, Equatable {
        public var id: Int64
        public var prompt: String
        public var status: Status
        public var createdAt: Int64
        public var finishedAt: Int64?
        public var result: String?
        public var error: String?

        /// Whether the desk is waiting on the analyzer for this one.
        public var isRunning: Bool { status == .pending || status == .drafting }
    }

    // MARK: - Requesting

    /// Records a request and returns its id for the `--draft` launch. The
    /// prompt is redacted on the way in: this is a DB write like any other
    /// (invariant 2), and a request is often a pasted message to rewrite.
    /// Redaction runs *before* the length cut — the other way round, a card
    /// number spanning the cap survives as the loose digits the truncation
    /// left behind. Cutting a placeholder in half is harmless.
    public static func request(
        prompt: String, database: ShifuDatabase, now: Date = Date()
    ) throws -> Int64 {
        let text = String(
            Redactor.redact(prompt.trimmingCharacters(in: .whitespacesAndNewlines))
                .prefix(maxPromptChars))
        let nowMs = Int64(now.timeIntervalSince1970 * 1_000)
        return try database.queue.write { db in
            try db.execute(sql: """
                INSERT INTO voice_drafts (prompt, status, status_at, created_at)
                VALUES (?, 'pending', ?, ?)
                """, arguments: [text, nowMs, nowMs])
            let id = db.lastInsertedRowID
            // Trim here rather than on a schedule: the desk is bounded at the
            // only moment it can grow.
            try db.execute(sql: """
                DELETE FROM voice_drafts WHERE id NOT IN (
                    SELECT id FROM voice_drafts ORDER BY created_at DESC, id DESC LIMIT ?)
                """, arguments: [historyLimit])
            return id
        }
    }

    // MARK: - Queries

    /// Newest first — the order the desk shows them in.
    public static func recent(
        database: ShifuDatabase, limit: Int = historyLimit
    ) throws -> [Draft] {
        try database.queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, prompt, status, created_at, finished_at, result, error
                FROM voice_drafts ORDER BY created_at DESC, id DESC LIMIT ?
                """, arguments: [limit]).map(draft(from:))
        }
    }

    public static func draft(id: Int64, database: ShifuDatabase) throws -> Draft? {
        try database.queue.read { db in
            try Row.fetchOne(db, sql: """
                SELECT id, prompt, status, created_at, finished_at, result, error
                FROM voice_drafts WHERE id = ?
                """, arguments: [id]).map(draft(from:))
        }
    }

    /// Every request still waiting, oldest first — the hourly drain's work
    /// list, and the safety net for a launch that never happened (no backend
    /// configured when the button was pressed, or the app quit mid-flight).
    public static func pendingIDs(database: ShifuDatabase) throws -> [Int64] {
        try database.queue.read { db in
            try Int64.fetchAll(db, sql: """
                SELECT id FROM voice_drafts WHERE status = 'pending' ORDER BY created_at
                """)
        }
    }

    // MARK: - Lifecycle (compare-and-set, not a lock)

    /// Claims a request for drafting. Exactly one caller wins: the UPDATE's
    /// WHERE clause is the compare half, and a second process sees zero rows
    /// changed. The stale-claim door covers a claimant that crashed.
    public static func claim(
        id: Int64, database: ShifuDatabase, now: Date = Date()
    ) throws -> Draft? {
        let nowMs = Int64(now.timeIntervalSince1970 * 1_000)
        let won = try database.queue.write { db -> Bool in
            try db.execute(sql: """
                UPDATE voice_drafts SET status = 'drafting', status_at = ?
                WHERE id = ? AND (status = 'pending'
                                  OR (status = 'drafting' AND status_at < ?))
                """, arguments: [nowMs, id, nowMs - staleClaimMs])
            return db.changesCount > 0
        }
        guard won else { return nil }
        return try draft(id: id, database: database)
    }

    /// The result is redacted on the way in for the same reason the prompt is:
    /// it is a DB write, and the model was shown the user's own writing.
    public static func complete(
        id: Int64, result: String, database: ShifuDatabase, now: Date = Date()
    ) throws {
        let nowMs = Int64(now.timeIntervalSince1970 * 1_000)
        try database.queue.write { db in
            try db.execute(sql: """
                UPDATE voice_drafts
                SET status = 'ready', status_at = ?, finished_at = ?, result = ?, error = NULL
                WHERE id = ?
                """, arguments: [nowMs, nowMs, Redactor.redact(result), id])
        }
    }

    public static func fail(
        id: Int64, error: String, database: ShifuDatabase, now: Date = Date()
    ) throws {
        let nowMs = Int64(now.timeIntervalSince1970 * 1_000)
        try database.queue.write { db in
            try db.execute(sql: """
                UPDATE voice_drafts SET status = 'failed', status_at = ?, finished_at = ?,
                                        error = ?
                WHERE id = ?
                """, arguments: [nowMs, nowMs, String(error.prefix(500)), id])
        }
    }

    public static func delete(id: Int64, database: ShifuDatabase) throws {
        try database.queue.write { db in
            try db.execute(sql: "DELETE FROM voice_drafts WHERE id = ?", arguments: [id])
        }
    }

    private static func draft(from row: Row) -> Draft {
        Draft(id: row["id"], prompt: row["prompt"],
              status: Status(rawValue: row["status"]) ?? .pending,
              createdAt: row["created_at"], finishedAt: row["finished_at"],
              result: row["result"], error: row["error"])
    }
}
