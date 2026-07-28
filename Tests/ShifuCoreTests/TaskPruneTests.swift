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
        projectID: Int64? = nil, endedAt: Int64
    ) throws -> Int64 {
        try database.queue.write { db in
            var task = WorkTask(key: key, name: name, projectID: projectID,
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
        let project = try TaskStore.createProject(named: "Trips", database: database)
        try seedTask(database, key: "domain:kayak.com", name: "kayak.com",
                     minutes: 3, projectID: project.id, endedAt: stale)

        try database.queue.write { db in
            try db.execute(sql: """
                INSERT INTO task_merge_suggestions (task_a, task_b, cosine, status, created_at)
                VALUES (?, ?, 0.95, 'new', 0), (?, ?, 0.95, 'dismissed', 0)
                """, arguments: [junk, big, renamed, big])
            try db.execute(sql: """
                INSERT INTO project_suggestions (task_id, project_id, cosine, status, created_at)
                VALUES (?, ?, 0.9, 'new', 0)
                """, arguments: [junk, project.id])
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
             projects: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM project_suggestions") ?? -1)
        }
        #expect(state.orphans == 1)
        #expect(state.junkLogs == 0)
        #expect(state.merges == ["dismissed"])  // only the open pair naming junk died
        #expect(state.projects == 0)

        // Re-running finds nothing left to prune.
        #expect(try TaskStore.prune(database: database, now: now, calendar: calendar) == 0)
    }
}
