import Foundation
import GRDB
import Testing
@testable import ShifuCore

/// The focus score's arithmetic, and the session read under it. The score's
/// whole claim is that it mirrors the live Focus Mode contract — work and
/// learning on-task, unclassified and private neutral, the rest off-task —
/// so most of these pin that agreement.
@Suite struct FocusReportTests {
    private func block(
        _ category: String, from: Int64, to: Int64
    ) -> LedgerBuilder.LabeledActivity {
        LedgerBuilder.LabeledActivity(
            id: from, startedAt: from, endedAt: to, category: category, source: "app")
    }

    private func raw(_ id: Int64, from: Int64, to: Int64) -> FocusModeSessions.Session {
        FocusModeSessions.Session(id: id, startedAt: from, endedAt: to)
    }

    @Test func categoriesSplitTheWayTheLiveControllerSplitsThem() {
        let sessions = FocusReport.sessions(
            [raw(1, from: 0, to: 100_000)],
            activities: [
                block("work", from: 0, to: 40_000),
                block("learning", from: 40_000, to: 50_000),
                block("entertainment", from: 50_000, to: 70_000),
                block("private", from: 70_000, to: 80_000),
                block("unclassified", from: 80_000, to: 90_000),
                // A category the enum never heard of is neutral, not punished.
                block("a-new-category", from: 90_000, to: 100_000)
            ],
            from: 0, to: 100_000)
        #expect(sessions.count == 1)
        #expect(sessions.first?.onTaskMs == 50_000)
        #expect(sessions.first?.offTaskMs == 20_000)
        #expect(sessions.first?.score == 50_000.0 / 70_000.0)
    }

    @Test func blocksAndSessionsAreClippedToTheWindow() {
        // The session leaks past both window edges; only the inside counts.
        let sessions = FocusReport.sessions(
            [raw(1, from: -50_000, to: 150_000)],
            activities: [block("work", from: -50_000, to: 60_000)],
            from: 0, to: 100_000)
        #expect(sessions.first?.startedAt == 0)
        #expect(sessions.first?.endedAt == 100_000)
        #expect(sessions.first?.onTaskMs == 60_000)
    }

    @Test func aSessionClippedToNothingDropsOut() {
        let sessions = FocusReport.sessions(
            [raw(1, from: 200_000, to: 300_000)], activities: [], from: 0, to: 100_000)
        #expect(sessions.isEmpty)
    }

    /// A session with no classified evidence has no score — not a perfect one.
    @Test func nothingClassifiedMeansNoScoreRatherThanFullMarks() {
        let sessions = FocusReport.sessions(
            [raw(1, from: 0, to: 100_000)],
            activities: [block("private", from: 0, to: 100_000)],
            from: 0, to: 100_000)
        #expect(sessions.first?.score == nil)
        #expect(FocusReport.score(sessions) == nil)
    }

    /// The window's figure pools classified time rather than averaging the
    /// per-session scores, so a long clean session outweighs a short lapse.
    @Test func theWindowScoreIsPooledNotAveraged() {
        let sessions = FocusReport.sessions(
            [raw(1, from: 0, to: 90_000), raw(2, from: 100_000, to: 110_000)],
            activities: [
                block("work", from: 0, to: 90_000),
                block("social", from: 100_000, to: 110_000)
            ],
            from: 0, to: 200_000)
        #expect(FocusReport.score(sessions) == 0.9)
    }
}

@Suite struct FocusModeSessionReadTests {
    private func insert(
        _ db: ShifuDatabase, startedAt: Int64, endedAt: Int64?
    ) throws {
        try db.queue.write {
            try $0.execute(
                sql: "INSERT INTO focus_mode_sessions (started_at, ended_at) VALUES (?, ?)",
                arguments: [startedAt, endedAt])
        }
    }

    /// The dogfood table is mostly sub-second rows — the toggle flipping, not
    /// anyone focusing — and they outnumber the real sessions three to one.
    @Test func toggleBlipsAreNotSessions() throws {
        let db = try ShifuDatabase.inMemory()
        try insert(db, startedAt: 0, endedAt: 800)
        try insert(db, startedAt: 10_000, endedAt: 10_000 + FocusModeSessions.minSessionMs)
        let sessions = try FocusModeSessions.overlapping(
            from: 0, to: 1_000_000, liveEnd: nil, database: db)
        #expect(sessions.map(\.id).count == 1)
        #expect(sessions.first?.startedAt == 10_000)
    }

    @Test func anOpenRowRunsToNowOnlyWhileFocusModeIsOn() throws {
        let db = try ShifuDatabase.inMemory()
        try insert(db, startedAt: 0, endedAt: nil)

        // Focus Mode on: the row is live and runs to the supplied now.
        let live = try FocusModeSessions.overlapping(
            from: 0, to: 1_000_000, liveEnd: 500_000, database: db)
        #expect(live.first?.endedAt == 500_000)
        #expect(live.first?.isLive == true)

        // Focus Mode off: the same row is a crashed daemon's leftover, and its
        // end is unknown — crediting it to now would invent hours.
        let stale = try FocusModeSessions.overlapping(
            from: 0, to: 1_000_000, liveEnd: nil, database: db)
        #expect(stale.isEmpty)
    }

    @Test func onlyOverlappingSessionsComeBack() throws {
        let db = try ShifuDatabase.inMemory()
        try insert(db, startedAt: 0, endedAt: 100_000)            // before
        try insert(db, startedAt: 150_000, endedAt: 250_000)      // straddles
        try insert(db, startedAt: 300_000, endedAt: 400_000)      // inside
        try insert(db, startedAt: 600_000, endedAt: 700_000)      // after
        let sessions = try FocusModeSessions.overlapping(
            from: 200_000, to: 500_000, liveEnd: nil, database: db)
        #expect(sessions.map(\.startedAt) == [150_000, 300_000])
    }
}
