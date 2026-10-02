import Foundation
import GRDB

/// The read under a Load reading (design.md §4.6): eight weeks of blocks with
/// their task and theme resolved, plus the open deadlines, handed to
/// `Workload.read`. One query, on page appear — not on every refresh, since
/// eight weeks is on the order of ten thousand rows.
public enum WorkloadStore {
    /// Blocks overlapping the last `Workload.weeks` weeks, oldest first. A
    /// `theme_key` with no `themes` row resolves to no theme at all: a
    /// proposal the user hasn't accepted is not an initiative they named.
    public static func blocks(
        database: ShifuDatabase, now: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)
    ) throws -> [Workload.Block] {
        let from = now - Int64(Workload.weeks) * Workload.weekMs
        return try database.queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT a.started_at, a.ended_at, a.category, a.task_id,
                       t.name AS task_name, th.id AS theme_id, th.name AS theme_name
                FROM activities a
                LEFT JOIN tasks t ON t.id = a.task_id
                LEFT JOIN themes th ON th.key = a.theme_key
                WHERE a.ended_at > ? AND a.started_at < ?
                ORDER BY a.started_at
                """, arguments: [from, now]
            ).map { row in
                Workload.Block(
                    startedAt: row["started_at"], endedAt: row["ended_at"],
                    category: row["category"], taskID: row["task_id"],
                    taskName: row["task_name"], themeID: row["theme_id"],
                    themeName: row["theme_name"])
            }
        }
    }

    /// The whole reading, for the page and for `shifu load`.
    public static func reading(
        database: ShifuDatabase, unit: Workload.Unit = .task,
        now: Int64 = Int64(Date().timeIntervalSince1970 * 1_000),
        calendar: Calendar = .current
    ) throws -> Workload.Reading {
        Workload.read(
            blocks: try blocks(database: database, now: now),
            deadlines: try DeadlineStore.open(database: database),
            unit: unit, now: now, calendar: calendar)
    }
}
