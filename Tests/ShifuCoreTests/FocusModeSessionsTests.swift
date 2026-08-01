import GRDB
import Testing
@testable import ShifuCore

/// A daemon that exits while Focus Mode is on leaves `ended_at` NULL. Those rows
/// would otherwise sit open forever and distort any duration sum.
@Suite struct FocusModeSessionsTests {
    private func openSession(_ db: ShifuDatabase, startedAt: Int64) throws {
        try db.queue.write {
            try $0.execute(sql: "INSERT INTO focus_mode_sessions (started_at) VALUES (?)",
                           arguments: [startedAt])
        }
    }

    private func closedSession(_ db: ShifuDatabase, from: Int64, to: Int64) throws {
        try db.queue.write {
            try $0.execute(
                sql: "INSERT INTO focus_mode_sessions (started_at, ended_at) VALUES (?, ?)",
                arguments: [from, to])
        }
    }

    private func observation(_ db: ShifuDatabase, lastSeen: Int64) throws {
        try db.queue.write {
            try $0.execute(sql: """
                INSERT INTO observations (started_at, last_seen, app_bundle, capture_kind)
                VALUES (?, ?, 'com.apple.Safari', 'ax')
                """, arguments: [lastSeen, lastSeen])
        }
    }

    private struct Span: Equatable {
        let startedAt: Int64
        let endedAt: Int64?
        init(_ startedAt: Int64, _ endedAt: Int64?) {
            self.startedAt = startedAt
            self.endedAt = endedAt
        }
    }

    private func sessions(_ db: ShifuDatabase) throws -> [Span] {
        try db.queue.read { sqlite in
            try Row.fetchAll(sqlite, sql:
                "SELECT started_at, ended_at FROM focus_mode_sessions ORDER BY started_at")
                .map { Span($0["started_at"], $0["ended_at"]) }
        }
    }

    /// The end time we can't recover exactly: fall back to the last moment the
    /// daemon is known to have been alive.
    @Test func danglingSessionClosesAtLastObservation() throws {
        let db = try ShifuDatabase.inMemory()
        try openSession(db, startedAt: 1_000)
        try observation(db, lastSeen: 5_000)
        try observation(db, lastSeen: 9_000)

        #expect(try FocusModeSessions.closeDangling(database: db) == 1)
        #expect(try sessions(db) == [Span(1_000, 9_000)])
    }

    /// No captures at all (paused throughout) means no evidence the session was
    /// ever active — collapse it rather than invent a duration.
    @Test func sessionWithoutObservationsCollapsesToZeroLength() throws {
        let db = try ShifuDatabase.inMemory()
        try openSession(db, startedAt: 1_000)

        #expect(try FocusModeSessions.closeDangling(database: db) == 1)
        #expect(try sessions(db) == [Span(1_000, 1_000)])
    }

    /// An old dangling row must not swallow a later session's activity.
    @Test func danglingSessionStopsAtTheNextSessionStart() throws {
        let db = try ShifuDatabase.inMemory()
        try openSession(db, startedAt: 1_000)          // crashed run
        try closedSession(db, from: 10_000, to: 20_000) // a later, healthy run
        try observation(db, lastSeen: 4_000)            // during the crashed run
        try observation(db, lastSeen: 15_000)           // during the later run

        #expect(try FocusModeSessions.closeDangling(database: db) == 1)
        #expect(try sessions(db) == [Span(1_000, 4_000), Span(10_000, 20_000)])
    }

    @Test func alreadyClosedSessionsAreUntouched() throws {
        let db = try ShifuDatabase.inMemory()
        try closedSession(db, from: 1_000, to: 2_000)
        try observation(db, lastSeen: 9_000)

        #expect(try FocusModeSessions.closeDangling(database: db) == 0)
        #expect(try sessions(db) == [Span(1_000, 2_000)])
    }

    @Test func repeatedRunsAreIdempotent() throws {
        let db = try ShifuDatabase.inMemory()
        try openSession(db, startedAt: 1_000)
        try observation(db, lastSeen: 5_000)

        #expect(try FocusModeSessions.closeDangling(database: db) == 1)
        #expect(try FocusModeSessions.closeDangling(database: db) == 0)
        #expect(try sessions(db) == [Span(1_000, 5_000)])
    }

    @Test func multipleDanglingSessionsAllClose() throws {
        let db = try ShifuDatabase.inMemory()
        try openSession(db, startedAt: 1_000)
        try openSession(db, startedAt: 10_000)
        try observation(db, lastSeen: 4_000)
        try observation(db, lastSeen: 14_000)

        #expect(try FocusModeSessions.closeDangling(database: db) == 2)
        #expect(try sessions(db) == [Span(1_000, 4_000), Span(10_000, 14_000)])
    }

    // MARK: - previousEnd: the far end of the "since" clock (FocusClock)

    /// One minute, the floor a row has to clear to count as a session at all.
    private var minute: Int64 { FocusModeSessions.minSessionMs }

    /// The minimum length screens closed flip-flops, never the running
    /// session: a live row seconds old must read back, or the Focus page
    /// spends its first minute denying the switch was flipped.
    @Test func aLiveRowYoungerThanAMinuteStillReads() throws {
        let db = try ShifuDatabase.inMemory()
        let minute: Int64 = 60_000
        try openSession(db, startedAt: 100 * minute)
        let now = 100 * minute + 5_000
        let sessions = try FocusModeSessions.overlapping(
            from: 0, to: 200 * minute, liveEnd: now, database: db)
        #expect(sessions.count == 1)
        #expect(sessions.first?.isLive == true)
        #expect(sessions.first?.endedAt == now)
        // A *closed* row of the same age stays screened out.
        try db.queue.write {
            try $0.execute(
                sql: "UPDATE focus_mode_sessions SET ended_at = ?", arguments: [now])
        }
        #expect(try FocusModeSessions.overlapping(
            from: 0, to: 200 * minute, liveEnd: nil, database: db).isEmpty)
    }

    /// The stand-in fills the daemon's gap and steps aside the moment the
    /// real open row reads back.
    @Test func standInAppearsOnlyUntilTheRealRowLands() {
        let minute: Int64 = 60_000
        let started = 100 * minute
        let now = started + 5_000
        let standIn = FocusModeSessions.addingStandIn(
            [], liveEnd: now, startedAt: started, from: 0, to: 200 * minute)
        #expect(standIn.count == 1)
        #expect(standIn.first?.isLive == true)
        #expect(standIn.first?.startedAt == started)
        // A real live row already read back: nothing to add.
        let real = FocusModeSessions.Session(
            id: 7, startedAt: started, endedAt: now, isLive: true)
        #expect(FocusModeSessions.addingStandIn(
            [real], liveEnd: now, startedAt: started, from: 0, to: 200 * minute) == [real])
        // Focus Mode off, or no start on record, or outside the window: no row.
        #expect(FocusModeSessions.addingStandIn(
            [], liveEnd: nil, startedAt: started, from: 0, to: 200 * minute).isEmpty)
        #expect(FocusModeSessions.addingStandIn(
            [], liveEnd: now, startedAt: nil, from: 0, to: 200 * minute).isEmpty)
        #expect(FocusModeSessions.addingStandIn(
            [], liveEnd: now, startedAt: started, from: 150 * minute,
            to: 200 * minute).isEmpty)
    }

    /// The other end of the same gap: the switch has gone off in the app, the
    /// daemon's `ended_at` write hasn't landed, and the session must not
    /// vanish off the page — and out of the score — in between.
    @Test func endedHereClosesTheRowTheSwitchJustLeftOpen() throws {
        let db = try ShifuDatabase.inMemory()
        let started = 100 * minute
        let stopped = started + 30 * minute
        try openSession(db, startedAt: started)

        let sessions = try FocusModeSessions.overlapping(
            from: 0, to: 200 * minute, liveEnd: nil, endedHere: stopped, database: db)
        #expect(sessions.count == 1)
        #expect(sessions.first?.isLive == false)
        #expect(sessions.first?.endedAt == stopped)
        // Without that moment on record the open row is still a dead daemon's
        // leftover, and crediting it would be worse than skipping it.
        #expect(try FocusModeSessions.overlapping(
            from: 0, to: 200 * minute, liveEnd: nil, database: db).isEmpty)
    }

    /// `endedHere` may only close the row the switch itself left open — the
    /// last one to start. An older leftover stopped at some moment nobody
    /// recorded, and stretching it to now would credit hours nobody focused.
    @Test func endedHereNeverClosesAnOlderLeftover() throws {
        let db = try ShifuDatabase.inMemory()
        try openSession(db, startedAt: 10 * minute)     // yesterday's crash
        try openSession(db, startedAt: 100 * minute)    // the one just flipped off
        let stopped = 130 * minute

        let sessions = try FocusModeSessions.overlapping(
            from: 0, to: 200 * minute, liveEnd: nil, endedHere: stopped, database: db)
        #expect(sessions.map(\.startedAt) == [100 * minute])
        #expect(sessions.first?.endedAt == stopped)
    }

    /// A live row's end is only ever "when it was read". Advancing it is what
    /// keeps the score moving while you watch it: the minutes captured since
    /// that read have to fall *inside* the session to be scored at all.
    @Test func advancingLiveMovesOnlyTheRunningRowAndOnlyForward() {
        let live = FocusModeSessions.Session(
            id: 1, startedAt: 100 * minute, endedAt: 110 * minute, isLive: true)
        let closed = FocusModeSessions.Session(
            id: 2, startedAt: 10 * minute, endedAt: 20 * minute, isLive: false)

        let advanced = FocusModeSessions.advancingLive([closed, live], to: 130 * minute)
        #expect(advanced.map(\.endedAt) == [20 * minute, 130 * minute])
        // A clock reading behind the row — a stale publish — never shortens it.
        #expect(FocusModeSessions.advancingLive([live], to: 105 * minute) == [live])
    }

    @Test func previousEndIsTheLatestSessionToHaveEnded() throws {
        let db = try ShifuDatabase.inMemory()
        try closedSession(db, from: 0, to: minute)
        try closedSession(db, from: 10 * minute, to: 12 * minute)
        try closedSession(db, from: 5 * minute, to: 7 * minute)

        #expect(try FocusModeSessions.previousEnd(
            before: 100 * minute, database: db) == 12 * minute)
    }

    @Test func previousEndIsNilWhenNothingHasEverBeenLogged() throws {
        let db = try ShifuDatabase.inMemory()
        #expect(try FocusModeSessions.previousEnd(before: 100 * minute, database: db) == nil)
    }

    /// The same line `overlapping` holds: a row too short to be a session is a
    /// switch being flipped, and "last focus 3s ago" after a stray double-click
    /// is a reading about the mouse, not about focusing.
    @Test func previousEndIgnoresRowsTooShortToBeASession() throws {
        let db = try ShifuDatabase.inMemory()
        try closedSession(db, from: 0, to: 2 * minute)
        try closedSession(db, from: 50 * minute, to: 50 * minute + 3_000)

        #expect(try FocusModeSessions.previousEnd(
            before: 100 * minute, database: db) == 2 * minute)
    }

    /// An open row is either the session running right now or a crashed
    /// daemon's leftover. Neither is one you were last focusing in.
    @Test func previousEndIgnoresOpenSessions() throws {
        let db = try ShifuDatabase.inMemory()
        try closedSession(db, from: 0, to: 2 * minute)
        try openSession(db, startedAt: 50 * minute)

        #expect(try FocusModeSessions.previousEnd(
            before: 100 * minute, database: db) == 2 * minute)
    }

    /// The cutoff is what makes the gap mean "before *this* session" while one
    /// is running, rather than "before now" with the running session in the way.
    @Test func previousEndStopsAtTheCutoff() throws {
        let db = try ShifuDatabase.inMemory()
        try closedSession(db, from: 0, to: 2 * minute)
        try closedSession(db, from: 20 * minute, to: 30 * minute)

        #expect(try FocusModeSessions.previousEnd(
            before: 10 * minute, database: db) == 2 * minute)
        #expect(try FocusModeSessions.previousEnd(before: minute, database: db) == nil)
    }
}
