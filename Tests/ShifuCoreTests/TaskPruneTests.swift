import Foundation
import GRDB
import Testing
@testable import ShifuCore

@Suite struct TaskPruneTests {
    private let calendar = Calendar.current
    private var day1: Date { calendar.startOfDay(for: Date(timeIntervalSince1970: 1_760_000_000)) }

    private func ms(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1_000) }

    /// A legacy task (minted before the substance gate) with one attached
    /// activity of the given length, last active at `endedAt`.
    @discardableResult
    private func seedTask(
        _ database: ShifuDatabase, key: String, name: String, minutes: Double,
        endedAt: Int64
    ) throws -> Int64 {
        try database.queue.write { db in
            var task = WorkTask(key: key, name: name,
                                createdAt: endedAt, lastActiveAt: endedAt)
            try task.insert(db)
            var activity = Activity(
                startedAt: endedAt - Int64(minutes * 60_000), endedAt: endedAt,
                appBundle: "com.apple.Safari",
                domain: key.hasPrefix("domain:") ? String(key.dropFirst(7)) : nil,
                category: .work)
            try activity.insert(db)
            try db.execute(sql: "UPDATE activities SET task_id = ? WHERE id = ?",
                           arguments: [task.id, activity.id])
            var log = TaskLog(taskID: task.id!, dayStart: endedAt - endedAt % 86_400_000,
                              durationMs: Int64(minutes * 60_000), summary: name)
            try log.insert(db)
            return task.id!
        }
    }

    @Test func prunesOnlyStaleSubThresholdDefaultNamedTasks() throws {
        let database = try ShifuDatabase.inMemory()
        let stale = ms(day1)
        let now = day1.addingTimeInterval(9 * 86_400)

        let junk = try seedTask(database, key: "domain:nytimes.com", name: "nytimes.com",
                                minutes: 3, endedAt: stale)
        let renamed = try seedTask(database, key: "topic:skim-rust", name: "Rust research",
                                   minutes: 3, endedAt: stale)
        let big = try seedTask(database, key: "domain:github.com", name: "github.com",
                               minutes: 45, endedAt: stale)
        try seedTask(database, key: "domain:united.com", name: "united.com",
                     minutes: 3, endedAt: ms(now) - 3_600_000)
        // Filed under a theme by hand: junk by every other measure, kept
        // because the user said it belongs somewhere.
        let filed = try seedTask(database, key: "domain:kayak.com", name: "kayak.com",
                                 minutes: 3, endedAt: stale)
        let trips = try #require(try ThemeStore.create(named: "Trips", database: database))
        try TaskStore.assignTheme(taskID: filed, themeKey: trips, database: database)

        try database.queue.write { db in
            try db.execute(sql: """
                INSERT INTO task_merge_suggestions (task_a, task_b, cosine, status, created_at)
                VALUES (?, ?, 0.95, 'new', 0), (?, ?, 0.95, 'dismissed', 0)
                """, arguments: [junk, big, renamed, big])
            try db.execute(sql: """
                INSERT INTO theme_suggestions (task_id, theme_key, cosine, status, created_at)
                VALUES (?, ?, 0.9, 'new', 0)
                """, arguments: [junk, trips])
        }

        let pruned = try TaskStore.prune(database: database, now: now, calendar: calendar)
        #expect(pruned == 1)

        let keys = try database.queue.read { db in
            try String.fetchAll(db, sql: "SELECT key FROM tasks ORDER BY key")
        }
        #expect(keys == ["domain:github.com", "domain:kayak.com",
                         "domain:united.com", "topic:skim-rust"])

        // The activity survives task-less; the junk task's log cascaded away.
        let state = try database.queue.read { db in
            (orphans: try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM activities WHERE task_id IS NULL
                """) ?? -1,
             junkLogs: try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM task_logs WHERE task_id = \(junk)
                """) ?? -1,
             merges: try String.fetchAll(db, sql: "SELECT status FROM task_merge_suggestions"),
             themes: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM theme_suggestions") ?? -1)
        }
        #expect(state.orphans == 1)
        #expect(state.junkLogs == 0)
        #expect(state.merges == ["dismissed"])  // only the open pair naming junk died
        #expect(state.themes == 0)

        // Re-running finds nothing left to prune.
        #expect(try TaskStore.prune(database: database, now: now, calendar: calendar) == 0)
    }

    /// Prune used to carry a second clause for system-surface `app:` tasks,
    /// exempt from the staleness rule because the lock screen accrued time
    /// daily and so was never stale enough to take. That clause is gone: no
    /// such task can be minted (`LedgerBuilder` writes the blocks no more) and
    /// `v25-system-shell-purge` took the ones on disk. What must not have
    /// changed is the rest — a busy, recent, app-keyed task is still nobody's
    /// debris, whatever its bundle looks like.
    @Test func leavesBusyRecentAppKeyedTasksAlone() throws {
        let database = try ShifuDatabase.inMemory()
        let now = day1.addingTimeInterval(86_400)
        let recent = ms(now) - 3_600_000

        try seedTask(database, key: "app:com.mitchellh.ghostty", name: "ghostty",
                     minutes: 400, endedAt: recent)
        try seedTask(database, key: "app:com.apple.dock", name: "Desk setup",
                     minutes: 400, endedAt: recent)

        #expect(try TaskStore.prune(database: database, now: now, calendar: calendar) == 0)

        let keys = try database.queue.read { db in
            try String.fetchAll(db, sql: "SELECT key FROM tasks ORDER BY key")
        }
        #expect(keys == ["app:com.apple.dock", "app:com.mitchellh.ghostty"])
    }
}
