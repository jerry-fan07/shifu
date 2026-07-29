import Foundation
import GRDB

/// Suggested themes (design.md §5.3) — the queue `ThemeClusterer` writes to
/// when it wants an initiative that doesn't exist yet.
///
/// Themes are the user's own structure, so the model never mints one. What it
/// can do is *notice* one: a proposal carries the title, the gist, and the
/// blocks the model put behind it, and renders below the Themes grid as
/// "Shifu noticed … — Add / Dismiss". Accepting mints the theme and files
/// those blocks in one step, so an accepted theme is never a named empty box.
///
/// Same permanence rule as the merge and task→theme queues: `key` is unique,
/// so a re-proposal updates one row and a dismissal is remembered forever.
public enum ThemeProposals {
    /// One open proposal, with its evidence rolled up live from `activities`
    /// — the count and hours are what accepting would actually file, not what
    /// the blocks were worth when the model proposed them.
    public struct Pending: Identifiable, Sendable {
        public var id: Int64
        public var key: String
        public var name: String
        public var gist: String?
        public var blockCount: Int
        public var totalMs: Int64
    }

    // MARK: - Writes (clusterer side)

    /// Records — or refreshes — one proposal and the blocks behind it. The
    /// theme is described by the same `RosterEntry` the clusterer offers the
    /// model, since key/name/gist is exactly what a proposal is.
    ///
    /// Returns true when this is a *new* initiative for the user to look at;
    /// an already-open, already-dismissed, or already-accepted key returns
    /// false, so nothing the user has ruled on comes back as news.
    ///
    /// Runs inside the clusterer's batch write, hence the raw `Database`.
    @discardableResult
    static func record(
        _ db: Database, theme: SemanticTaskGrouper.RosterEntry,
        blockIDs: [Int64], now: Int64
    ) throws -> Bool {
        let key = theme.key
        try db.execute(sql: """
            INSERT INTO theme_proposals (key, name, gist, status, created_at)
            VALUES (?, ?, ?, 'new', ?)
            ON CONFLICT(key) DO NOTHING
            """, arguments: [key, theme.name, theme.gist, now])
        let isNew = db.changesCount > 0
        guard let proposalID = try Int64.fetchOne(
            db, sql: "SELECT id FROM theme_proposals WHERE key = ?", arguments: [key])
        else { return false }
        // Blocks accumulate across runs even on a dismissed proposal: nothing
        // surfaces it again, but if the user later creates that theme by hand
        // the key matches and the evidence is there.
        for blockID in blockIDs {
            try db.execute(sql: """
                INSERT OR IGNORE INTO theme_proposal_blocks (proposal_id, activity_id)
                VALUES (?, ?)
                """, arguments: [proposalID, blockID])
        }
        return isNew
    }

    // MARK: - Reads

    /// Open proposals, biggest evidence first — the order that puts "you've
    /// spent nine hours on this" above "you glanced at this once".
    ///
    /// A proposal whose key already exists as a real theme drops out: the user
    /// created it by hand in the meantime, and the question is answered.
    public static func pending(database: ShifuDatabase) throws -> [Pending] {
        try database.queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT p.id, p.key, p.name, p.gist,
                       COUNT(a.id) AS block_count,
                       COALESCE(SUM(a.ended_at - a.started_at), 0) AS total_ms
                FROM theme_proposals p
                LEFT JOIN theme_proposal_blocks b ON b.proposal_id = p.id
                LEFT JOIN activities a ON a.id = b.activity_id
                WHERE p.status = 'new'
                  AND NOT EXISTS (SELECT 1 FROM themes t WHERE t.key = p.key)
                GROUP BY p.id
                ORDER BY total_ms DESC
                """
            ).map { row in
                Pending(id: row["id"], key: row["key"], name: row["name"],
                        gist: row["gist"], blockCount: row["block_count"],
                        totalMs: row["total_ms"])
            }
        }
    }

    // MARK: - User actions

    /// Accepts: mint the theme under the proposed key and file its blocks.
    /// Returns the theme key, or nil if the proposal vanished.
    ///
    /// Only *unfiled* blocks move — a block the user filed by hand, or one a
    /// later run put somewhere else, keeps the home it has. `theme_user_set`
    /// stays 0: the user judged the theme, not each block, and that bit means
    /// "this block's filing is the user's" to prune and auto-merge.
    @discardableResult
    public static func accept(
        _ proposal: Pending, database: ShifuDatabase, now: Date = Date()
    ) throws -> String? {
        let nowMs = Int64(now.timeIntervalSince1970 * 1_000)
        return try database.queue.write { db -> String? in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT key, name, gist FROM theme_proposals WHERE id = ?",
                arguments: [proposal.id]) else { return nil }
            let key: String = row["key"]
            let lastActive = try Int64.fetchOne(db, sql: """
                SELECT COALESCE(MAX(a.ended_at), 0) FROM theme_proposal_blocks b
                JOIN activities a ON a.id = b.activity_id
                WHERE b.proposal_id = ?
                """, arguments: [proposal.id]) ?? 0
            try db.execute(sql: """
                INSERT INTO themes (key, name, gist, created_at, last_active_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET
                    last_active_at = MAX(last_active_at, excluded.last_active_at)
                """, arguments: [key, row["name"] as String, row["gist"] as String?,
                                 nowMs, max(lastActive, nowMs)])
            try db.execute(sql: """
                UPDATE activities SET theme_key = ?
                WHERE theme_key IS NULL AND id IN
                      (SELECT activity_id FROM theme_proposal_blocks WHERE proposal_id = ?)
                """, arguments: [key, proposal.id])
            try db.execute(
                sql: "UPDATE theme_proposals SET status = 'accepted' WHERE id = ?",
                arguments: [proposal.id])
            return key
        }
    }

    public static func dismiss(proposalID: Int64, database: ShifuDatabase) throws {
        try database.queue.write { db in
            try db.execute(
                sql: "UPDATE theme_proposals SET status = 'dismissed' WHERE id = ?",
                arguments: [proposalID])
        }
    }

    /// "None of these are mine" — clears the open queue in one action, with
    /// the same permanence as dismissing each row.
    @discardableResult
    public static func dismissAll(database: ShifuDatabase) throws -> Int {
        try database.queue.write { db in
            try db.execute(
                sql: "UPDATE theme_proposals SET status = 'dismissed' WHERE status = 'new'")
            return db.changesCount
        }
    }

    /// Marks a key as ruled out without there being a proposal for it — how a
    /// *deleted* theme keeps the clusterer from proposing it straight back.
    static func dismissKey(_ key: String, name: String, db: Database, now: Int64) throws {
        try db.execute(sql: """
            INSERT INTO theme_proposals (key, name, status, created_at)
            VALUES (?, ?, 'dismissed', ?)
            ON CONFLICT(key) DO UPDATE SET status = 'dismissed'
            """, arguments: [key, name, now])
    }
}
