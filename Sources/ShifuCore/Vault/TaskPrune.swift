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

    /// Ids of the tasks prune would take: quiet, sub-threshold, mechanically
    /// keyed, and still wearing the name the grouper gave them — plus `app:`
    /// tasks for system bundles the grouper now denylists
    /// (TaskGrouper.isSystemBundle), which accrue time daily and so never
    /// meet the staleness or substance conditions; those die regardless of
    /// size or recency. Only a rename spares a system task — not a hand-filed
    /// theme: the bundle can never be work, the denylist starves the task of
    /// new blocks either way, and the dogfood DB showed such filings were UI
    /// experiments (loginwindow filed under "Shifu Development"). The blocks
    /// keep their `theme_key`, so filed theme time survives the task.
    private static func candidates(
        database: ShifuDatabase, now: Date
    ) throws -> [Int64] {
        let cutoff = Int64(now.timeIntervalSince1970 * 1_000)
            - Int64(pruneInactiveDays) * 86_400_000
        return try database.queue.read { db in
            let debris = try Row.fetchAll(db, sql: """
                SELECT id, key, name FROM tasks
                WHERE last_active_at < ?
                  AND key NOT LIKE 'sem:%'
                  -- Filing a task under a theme by hand protects it, exactly
                  -- as filing it under a project used to (v14). A theme the
                  -- *clusterer* picked does not: it themes nearly every
                  -- block, so that would switch prune off altogether.
                  AND NOT EXISTS (SELECT 1 FROM activities a
                                  WHERE a.task_id = tasks.id AND a.theme_user_set = 1)
                  AND COALESCE((SELECT SUM(a.ended_at - a.started_at)
                                FROM activities a WHERE a.task_id = tasks.id), 0) < ?
                """, arguments: [cutoff, TaskGrouper.minNewTaskMs]
            ).map { PruneCandidate(id: $0["id"], key: $0["key"], name: $0["name"]) }
            let system = try Row.fetchAll(db, sql: """
                SELECT id, key, name FROM tasks WHERE key LIKE 'app:%'
                """
            ).map { PruneCandidate(id: $0["id"], key: $0["key"], name: $0["name"]) }
                .filter { TaskGrouper.isSystemBundle(String($0.key.dropFirst(4))) }
            var seenIDs: Set<Int64> = []
            return (debris + system)
                .filter { TaskGrouper.isDefaultName($0.name, forKey: $0.key) }
                .map(\.id)
                .filter { seenIDs.insert($0).inserted }
        }
    }

    /// Deletes noise tasks: under TaskGrouper.minNewTaskMs of lifetime
    /// activity, never renamed, never hand-filed under a theme, inactive for
    /// pruneInactiveDays.
    /// That is the debris the substance gate now stops at the source — one-off
    /// subjects minted before the gate existed, and tasks whose activities
    /// were later re-grouped away. System-bundle `app:` tasks (see
    /// `candidates`) are the one exception to the staleness rule: minted
    /// before the grouping denylist existed, they die on sight and never
    /// re-mint. Semantic (`sem:`) tasks are exempt in the query below and
    /// renamed ones fail isDefaultName. Deleting is safe:
    /// the key re-mints the moment it earns real time, and the activities keep
    /// their ledger time, just task-less. Day logs and work notes recompile.
    @discardableResult
    public static func prune(
        database: ShifuDatabase, vault: VaultStore? = nil,
        now: Date = Date(), calendar: Calendar = .current
    ) throws -> Int {
        let doomed = try candidates(database: database, now: now)
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
                DELETE FROM theme_suggestions
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
