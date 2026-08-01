import Foundation
import GRDB

/// Maintenance and reads for `focus_mode_sessions` (design.md §4.4).
public enum FocusModeSessions {
    /// One logged focus session, ends resolved — an open row's end is the
    /// caller-supplied "now", never NULL.
    public struct Session: Identifiable, Sendable, Equatable {
        public var id: Int64
        public var startedAt: Int64
        public var endedAt: Int64
        /// Still open — Focus Mode is on right now and this row is its log.
        public var isLive: Bool

        public init(id: Int64, startedAt: Int64, endedAt: Int64, isLive: Bool = false) {
            self.id = id
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.isLive = isLive
        }
    }

    /// A real session is at least this long. The table is full of shorter
    /// rows — a double-click on the toggle, `focus off && focus on` — and on
    /// the dogfood ledger they outnumber the sessions three to one. They are
    /// honest logs of a switch flipping, not of anyone focusing.
    public static let minSessionMs: Int64 = 60_000

    /// Sessions overlapping [from, to), oldest first.
    ///
    /// `liveEnd` is what an open row's end reads as — pass "now" while Focus
    /// Mode is on. Pass nil when it is off: an open row then is a leftover
    /// from a daemon that died mid-session, and until the next daemon launch
    /// repairs it (`closeDangling`) its true end is unknown — skipping it
    /// beats crediting hours nobody focused.
    public static func overlapping(
        from: Int64, to: Int64, liveEnd: Int64?, database: ShifuDatabase
    ) throws -> [Session] {
        try database.queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, started_at, ended_at FROM focus_mode_sessions
                WHERE started_at < ? AND (ended_at > ? OR ended_at IS NULL)
                ORDER BY started_at
                """, arguments: [to, from]
            ).compactMap { row in
                let endedAt: Int64
                let isLive: Bool
                if let closed = row["ended_at"] as Int64? {
                    endedAt = closed
                    isLive = false
                } else {
                    guard let liveEnd else { return nil }
                    endedAt = liveEnd
                    isLive = true
                }
                let startedAt: Int64 = row["started_at"]
                guard endedAt - startedAt >= minSessionMs, endedAt > from else { return nil }
                return Session(
                    id: row["id"], startedAt: startedAt, endedAt: endedAt, isLive: isLive)
            }
        }
    }

    /// When the last real session before `moment` ended, or nil when there is
    /// none — the far end of the "since the previous focus session" clock
    /// (`FocusClock`).
    ///
    /// Holds the same two lines as `overlapping`: a row shorter than
    /// `minSessionMs` is a switch flipping rather than a session, and an open
    /// row is either the session running right now or a crashed daemon's
    /// leftover. Neither can be the one you were last focusing in.
    public static func previousEnd(
        before moment: Int64, database: ShifuDatabase
    ) throws -> Int64? {
        try database.queue.read { db in
            try Int64.fetchOne(db, sql: """
                SELECT MAX(ended_at) FROM focus_mode_sessions
                WHERE ended_at IS NOT NULL AND ended_at <= ?
                  AND ended_at - started_at >= ?
                """, arguments: [moment, minSessionMs])
        }
    }

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
