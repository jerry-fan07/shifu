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
    ///
    /// `endedHere` is the one exception to that: when *this* process turned
    /// Focus Mode off it knows exactly when, and the daemon's `ended_at` write
    /// is a filesystem event behind. Pass that moment and the still-open row
    /// closes at it instead of being dropped — otherwise the session the user
    /// just finished leaves the page, and the score with it, in the gap
    /// between the switch and the write.
    public static func overlapping(
        from: Int64, to: Int64, liveEnd: Int64?, endedHere: Int64? = nil,
        database: ShifuDatabase
    ) throws -> [Session] {
        try database.queue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, started_at, ended_at FROM focus_mode_sessions
                WHERE started_at < ? AND (ended_at > ? OR ended_at IS NULL)
                ORDER BY started_at
                """, arguments: [to, from])
            // Which open row `endedHere` may close: the last one to have
            // started. Anything older is a dead daemon's leftover, and the
            // moment this app flipped the switch says nothing about when
            // *that* session really stopped.
            let lastOpenStart = rows
                .filter { ($0["ended_at"] as Int64?) == nil }
                .map { $0["started_at"] as Int64 }
                .max()
            return rows.compactMap { row in
                let startedAt: Int64 = row["started_at"]
                let endedAt: Int64
                let isLive: Bool
                if let closed = row["ended_at"] as Int64? {
                    endedAt = closed
                    isLive = false
                } else if let liveEnd {
                    endedAt = liveEnd
                    isLive = true
                } else if let endedHere, startedAt == lastOpenStart, endedHere >= startedAt {
                    endedAt = endedHere
                    isLive = false
                } else {
                    return nil
                }
                // The minimum length screens *closed* rows — the flip-flops.
                // A live row is exempt: the session running right now starts
                // existing the moment the switch flips, or the Focus page
                // spends its first minute claiming nothing is happening.
                guard isLive || endedAt - startedAt >= minSessionMs else { return nil }
                guard endedAt > from else { return nil }
                return Session(
                    id: row["id"], startedAt: startedAt, endedAt: endedAt, isLive: isLive)
            }
        }
    }

    /// `sessions` with the running row's end moved up to `now`.
    ///
    /// A live row's end is only ever "when it was read", and the Focus page
    /// reads its rows once — on arrival, and on the switch flipping. Without
    /// this every minute captured after that read falls *outside* the session
    /// it happened in, so the score the page prints freezes at whatever it was
    /// when the page opened, however long you go on focusing. Pure and
    /// clock-free, so the view can re-ask on every publish.
    public static func advancingLive(_ sessions: [Session], to now: Int64) -> [Session] {
        sessions.map { session in
            guard session.isLive, now > session.endedAt else { return session }
            var advanced = session
            advanced.endedAt = now
            return advanced
        }
    }

    /// `sessions` with a stand-in live row appended when the switch says on
    /// but no open row has been read back. The open row is the daemon's to
    /// write: between the flip and the daemon noticing — or with no daemon
    /// running at all — the control file is the only log there is, and a
    /// Focus page that waited for the row would deny the switch was flipped.
    /// The stand-in yields the moment the real row lands.
    public static func addingStandIn(
        _ sessions: [Session], liveEnd: Int64?, startedAt: Int64?,
        from: Int64, to: Int64
    ) -> [Session] {
        guard let liveEnd, let startedAt,
              !sessions.contains(where: \.isLive),
              startedAt < to, liveEnd > from
        else { return sessions }
        return sessions + [Session(
            id: -1, startedAt: startedAt, endedAt: liveEnd, isLive: true)]
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
