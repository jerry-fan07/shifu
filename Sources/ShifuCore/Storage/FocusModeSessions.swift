import Foundation
import GRDB

/// Maintenance for `focus_mode_sessions` (design.md §4.4).
public enum FocusModeSessions {
    /// Closes sessions left open by a daemon that exited while Focus Mode was on
    /// — a crash, a restart, a logout. Those rows keep `ended_at` NULL forever,
    /// so any future duration sum either skips them or treats them as running
    /// until now; both distort adherence stats far more than the millisecond
    /// skew of a normally-closed session.
    ///
    /// The end time can't be recovered exactly — nothing recorded the moment the
    /// process died. The best available evidence is the last observation written
    /// during the session, which is when we last know the daemon was alive. With
    /// no observations at all (capture paused for the whole session) the session
    /// collapses to zero length, which is the honest answer: we have no evidence
    /// it was ever active.
    ///
    /// Must run before this process opens a session of its own, or it would
    /// immediately close the new row — `FocusModeController.init` calls it.
    ///
    /// - Returns: how many rows were closed.
    @discardableResult
    public static func closeDangling(database: ShifuDatabase) throws -> Int {
        try database.queue.write { db in
            let dangling = try Row.fetchAll(db, sql: """
                SELECT id, started_at FROM focus_mode_sessions
                WHERE ended_at IS NULL ORDER BY started_at
                """)
            for row in dangling {
                let rowID: Int64 = row["id"]
                let startedAt: Int64 = row["started_at"]
                // Never let an old dangling row swallow a later session's
                // activity: stop at the next session's start.
                let nextStart = try Int64.fetchOne(
                    db, sql: "SELECT MIN(started_at) FROM focus_mode_sessions WHERE started_at > ?",
                    arguments: [startedAt]
                ) ?? Int64.max
                let lastActivity = try Int64.fetchOne(
                    db, sql: "SELECT MAX(last_seen) FROM observations "
                        + "WHERE last_seen >= ? AND last_seen < ?",
                    arguments: [startedAt, nextStart]
                )
                try db.execute(
                    sql: "UPDATE focus_mode_sessions SET ended_at = ? WHERE id = ?",
                    arguments: [lastActivity ?? startedAt, rowID]
                )
            }
            return dangling.count
        }
    }
}
