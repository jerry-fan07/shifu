import GRDB
import Testing
@testable import ShifuCore

/// A daemon that exits while Focus Mode is on leaves `ended_at` NULL. Those rows
/// would otherwise sit open forever and distort any duration sum.
@Suite struct FocusModeSessionsTests {
    private func openSession(_ db: ShifuDatabase, startedAt: Int64) throws {
        try db.queue.write {
            try $0.execute(sql: "INSERT INTO work_mode_sessions (started_at) VALUES (?)",
                           arguments: [startedAt])
        }
    }

    private func closedSession(_ db: ShifuDatabase, from: Int64, to: Int64) throws {
        try db.queue.write {
            try $0.execute(
                sql: "INSERT INTO work_mode_sessions (started_at, ended_at) VALUES (?, ?)",
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
                "SELECT started_at, ended_at FROM work_mode_sessions ORDER BY started_at")
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
}
