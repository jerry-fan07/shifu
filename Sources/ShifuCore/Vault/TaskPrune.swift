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
    /// keyed, and still wearing the name the grouper gave them — plus
    /// `domain:` tasks for browser-internal hosts
    /// (TaskGrouper.isBrowserInternalHost), which accrue time daily and so
    /// never meet the staleness or substance conditions; those die on sight,
    /// only a rename sparing one.
    ///
    /// Under `.lastResort`, container tasks join the die-on-sight family by
    /// the mint gate's own test (TaskGrouper.run): a `domain:`/`app:` task
    /// whose lifetime *semantically-declined* time is under the mint floor
    /// exists only because the gate didn't yet — months of pre-gate
    /// `task_id`s keep it active daily, so the staleness rule alone can never
    /// reach it. Same flag as the gate, so reap and mint cannot disagree; a
    /// rename spares one here exactly as it always has, and so does an
    /// explicit `sem_key` pointing at the key — the trace of a merge into the
    /// task, which the gate honours for the same reason.
    ///
    /// System-bundle `app:` tasks used to need the same die-on-sight clause,
    /// exempt from the staleness rule. They cannot exist any more:
    /// `LedgerBuilder` writes no block for a system shell, so nothing mints
    /// the key, and the `v26-system-shell-purge` migration deleted the ones
    /// already on disk.
    private static func candidates(
        database: ShifuDatabase, now: Date, minting: TaskGrouper.MechanicalMinting
    ) throws -> [PruneCandidate] {
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
            // Die-on-sight rule for `domain:` tasks minted from
            // browser-internal pages (chrome://new-tab-page and kin) before
            // Sessionizer stopped deriving domains from non-web schemes —
            // that gate starves them of new blocks, so staleness can't reach
            // them either.
            let browser = try Row.fetchAll(db, sql: """
                SELECT id, key, name FROM tasks WHERE key LIKE 'domain:%'
                """
            ).map { PruneCandidate(id: $0["id"], key: $0["key"], name: $0["name"]) }
                .filter { TaskGrouper.isBrowserInternalHost(String($0.key.dropFirst(7))) }
            var containers: [PruneCandidate] = []
            if minting == .lastResort {
                containers = try Row.fetchAll(db, sql: """
                    SELECT id, key, name FROM tasks
                    WHERE (key LIKE 'domain:%' OR key LIKE 'app:%')
                      AND NOT EXISTS (SELECT 1 FROM activities a
                                      WHERE a.sem_key = tasks.key)
                      AND COALESCE((SELECT SUM(a.ended_at - a.started_at)
                                    FROM activities a
                                    WHERE a.task_id = tasks.id
                                      AND a.sem_attempts >= ?), 0) < ?
                    """, arguments: [SemanticTaskGrouper.maxAttempts,
                                     TaskGrouper.minNewTaskMs]
                ).map { PruneCandidate(id: $0["id"], key: $0["key"], name: $0["name"]) }
            }
            var seenIDs: Set<Int64> = []
            return (debris + browser + containers)
                .filter { TaskGrouper.isDefaultName($0.name, forKey: $0.key) }
                .filter { seenIDs.insert($0.id).inserted }
        }
    }

    /// Deletes noise tasks: under TaskGrouper.minNewTaskMs of lifetime
    /// activity, never renamed, never hand-filed under a theme, inactive for
    /// pruneInactiveDays.
    /// That is the debris the substance gate now stops at the source — one-off
    /// subjects minted before the gate existed, and tasks whose activities
    /// were later re-grouped away. Semantic (`sem:`) tasks are exempt in the
    /// query below and renamed ones fail isDefaultName. Deleting is safe:
    /// the key re-mints the moment it earns real time, and the activities keep
    /// their ledger time, just task-less. Day logs and work notes recompile.
    @discardableResult
    public static func prune(
        database: ShifuDatabase, vault: VaultStore? = nil,
        now: Date = Date(), calendar: Calendar = .current,
        minting: TaskGrouper.MechanicalMinting = .always
    ) throws -> Int {
        let dying = try candidates(database: database, now: now, minting: minting)
        guard !dying.isEmpty else { return 0 }
        let doomed = dying.map(\.id)
        let doomedKeys = dying.map(\.key)

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
            // Same policy for open deck proposals — and here it is not just
            // tidiness: `deck_suggestions` rows are keyed permanently, and an
            // orphaned `new` row would consume one of the suggester's three
            // open slots forever, with no UI able to show or clear it.
            // Resolved rows stay: a dismissal is meant to be permanent, and a
            // re-minted key is the same intent.
            try db.execute(sql: """
                DELETE FROM deck_suggestions
                WHERE status = 'new' AND task_key IN (\(placeholders))
                """, arguments: StatementArguments(doomedKeys))
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
