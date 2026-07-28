import Foundation
import GRDB

// MARK: - Prune (design.md §5.3)

extension TaskStore {
    /// How long a sub-threshold task must sit inactive before prune takes it.
    public static let pruneInactiveDays = 7

    private struct PruneCandidate {
        var id: Int64
        var key: String
        var name: String
    }

    /// Deletes noise tasks: under TaskGrouper.minNewTaskMs of lifetime
    /// activity, never renamed, in no project, inactive for pruneInactiveDays.
    /// That is the debris the substance gate now stops at the source — one-off
    /// subjects minted before the gate existed, and tasks whose activities
    /// were later re-grouped away. Semantic (`sem:`) and renamed tasks never
    /// qualify: isDefaultName only matches mechanical keys. Deleting is safe:
    /// the key re-mints the moment it earns real time, and the activities keep
    /// their ledger time, just task-less. Day logs and work notes recompile.
    @discardableResult
    public static func prune(
        database: ShifuDatabase, vault: VaultStore? = nil,
        now: Date = Date(), calendar: Calendar = .current
    ) throws -> Int {
        let cutoff = Int64(now.timeIntervalSince1970 * 1_000)
            - Int64(pruneInactiveDays) * 86_400_000
        let candidates: [PruneCandidate] = try database.queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, key, name FROM tasks
                WHERE project_id IS NULL AND last_active_at < ?
                  AND COALESCE((SELECT SUM(a.ended_at - a.started_at)
                                FROM activities a WHERE a.task_id = tasks.id), 0) < ?
                """, arguments: [cutoff, TaskGrouper.minNewTaskMs]
            ).map { PruneCandidate(id: $0["id"], key: $0["key"], name: $0["name"]) }
        }
        let doomed = candidates
            .filter { TaskGrouper.isDefaultName($0.name, forKey: $0.key) }
            .map(\.id)
        guard !doomed.isEmpty else { return 0 }

        let placeholders = databaseQuestionMarks(count: doomed.count)
        let spans: [(start: Int64, end: Int64)] = try database.queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT started_at, ended_at FROM activities WHERE task_id IN (\(placeholders))
                """, arguments: StatementArguments(doomed)
            ).map { ($0["started_at"], $0["ended_at"]) }
        }
        let days = TaskGrouper.affectedDays(of: spans, calendar: calendar)

        try database.queue.write { db in
            try db.execute(
                sql: "UPDATE activities SET task_id = NULL WHERE task_id IN (\(placeholders))",
                arguments: StatementArguments(doomed))
            // task_logs cascade away with their task.
            try db.execute(sql: "DELETE FROM tasks WHERE id IN (\(placeholders))",
                           arguments: StatementArguments(doomed))
            // Open suggestions naming a dead task are meaningless (same
            // policy as merge); resolved rows stay as the audit trail.
            try db.execute(sql: """
                DELETE FROM task_merge_suggestions
                WHERE status = 'new' AND (task_a IN (\(placeholders)) OR task_b IN (\(placeholders)))
                """, arguments: StatementArguments(doomed + doomed))
            try db.execute(sql: """
                DELETE FROM project_suggestions
                WHERE status = 'new' AND task_id IN (\(placeholders))
                """, arguments: StatementArguments(doomed))
            for day in days {
                try TaskGrouper.rebuildLogs(db, dayStart: day.start, dayEnd: day.end)
            }
        }
        if let vault {
            try WorkNoteCompiler.recompile(
                days: days, database: database, vault: vault, calendar: calendar)
        }
        return doomed.count
    }
}
