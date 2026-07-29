import Foundation
import GRDB

// MARK: - Merge (vault-features.md §5.2)

/// Applying a merge: the write half, which does not care who decided. Who
/// decides lives elsewhere — the user in the Vault tab, or `TaskMerges`
/// (Analysis) for the pairs certain enough to fold automatically.
extension TaskStore {
    /// How a merge came about, as recorded on the suggestion row. `automatic`
    /// is the unambiguous half TaskMerges folds without asking; everything
    /// else the user confirmed.
    public enum MergeResolution: String, Sendable {
        case confirmed = "merged"
        case automatic = "auto"
    }

    /// One fold: `absorbed` disappears into `survivor`.
    public struct MergePair: Sendable, Hashable {
        public var survivor: Int64
        public var absorbed: Int64

        public init(survivor: Int64, absorbed: Int64) {
            self.survivor = survivor
            self.absorbed = absorbed
        }
    }

    /// Folds one task into another: activities repoint to the survivor (which
    /// keeps its user-chosen name), the absorbed task dies (its task_logs
    /// cascade away), and the affected days' logs and work notes recompile —
    /// the absorbed task's note files are removed and its content re-lands
    /// under the survivor. Historical rows outside the affected days are
    /// untouched.
    public static func merge(
        survivorID: Int64, absorbedID: Int64, database: ShifuDatabase,
        vault: VaultStore? = nil, calendar: Calendar = .current,
        resolution: MergeResolution = .confirmed
    ) throws {
        try merge(pairs: [MergePair(survivor: survivorID, absorbed: absorbedID)],
                  database: database, vault: vault, calendar: calendar,
                  resolution: resolution)
    }

    /// The same fold for a whole batch, which is how auto-merge drains a
    /// backlog: the expensive half is not the repointing but rebuilding every
    /// touched day's logs and recompiling its work notes, and a hundred pairs
    /// over a 30-day window touch the same ~30 days. Doing them one at a time
    /// pays that cost a hundred times over; here the days are unioned and
    /// rebuilt once, inside the same transaction as the repointing.
    ///
    /// Pairs must already name a single survivor per group (A→S, B→S), never
    /// a chain (A→B, B→S) — the caller resolves components before calling.
    public static func merge(
        pairs: [MergePair], database: ShifuDatabase, vault: VaultStore? = nil,
        calendar: Calendar = .current, resolution: MergeResolution = .confirmed
    ) throws {
        let folds = pairs.filter { $0.survivor != $0.absorbed }
        guard !folds.isEmpty else { return }
        let absorbed = folds.map(\.absorbed)
        let placeholders = databaseQuestionMarks(count: absorbed.count)

        let spans: [(start: Int64, end: Int64)] = try database.queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT started_at, ended_at FROM activities WHERE task_id IN (\(placeholders))
                """, arguments: StatementArguments(absorbed)
            ).map { ($0["started_at"], $0["ended_at"]) }
        }
        // Read before the fold: `deck_suggestions` is keyed on `task_key`, and
        // the rows below are deleted after the task rows are gone.
        let absorbedKeys: [String] = try database.queue.read { db in
            try String.fetchAll(db, sql: "SELECT key FROM tasks WHERE id IN (\(placeholders))",
                                arguments: StatementArguments(absorbed))
        }
        let days = TaskGrouper.affectedDays(of: spans, calendar: calendar)

        try database.queue.write { db in
            for fold in folds {
                try db.execute(sql: "UPDATE activities SET task_id = ? WHERE task_id = ?",
                               arguments: [fold.survivor, fold.absorbed])
                try db.execute(sql: """
                    UPDATE tasks SET last_active_at = MAX(last_active_at,
                        COALESCE((SELECT last_active_at FROM tasks WHERE id = ?), 0))
                    WHERE id = ?
                    """, arguments: [fold.absorbed, fold.survivor])
                try db.execute(sql: "DELETE FROM tasks WHERE id = ?", arguments: [fold.absorbed])
                // The resolved pair is recorded; other open suggestions naming
                // the dead task are meaningless now and go away.
                try db.execute(sql: """
                    UPDATE task_merge_suggestions SET status = ?
                    WHERE (task_a = ? AND task_b = ?) OR (task_a = ? AND task_b = ?)
                    """, arguments: [resolution.rawValue, fold.survivor, fold.absorbed,
                                     fold.absorbed, fold.survivor])
            }
            try clearOpenSuggestions(db, absorbed: absorbed, keys: absorbedKeys)
            for day in days {
                try TaskGrouper.rebuildLogs(db, dayStart: day.start, dayEnd: day.end)
            }
        }
        if let vault {
            try WorkNoteCompiler.recompile(
                days: days, database: database, vault: vault, calendar: calendar)
        }
    }

    /// Open suggestions that name a task which just disappeared into another
    /// one are meaningless — same policy as prune. For deck proposals it is
    /// more than tidiness: their rows are keyed permanently, so an orphan
    /// would hold one of the suggester's three open slots forever with no UI
    /// able to show or clear it. Resolved rows stay as the audit trail.
    private static func clearOpenSuggestions(
        _ db: Database, absorbed: [Int64], keys: [String]
    ) throws {
        let placeholders = databaseQuestionMarks(count: absorbed.count)
        try db.execute(sql: """
            DELETE FROM task_merge_suggestions
            WHERE status = 'new' AND (task_a IN (\(placeholders))
                                      OR task_b IN (\(placeholders)))
            """, arguments: StatementArguments(absorbed + absorbed))
        guard !keys.isEmpty else { return }
        try db.execute(sql: """
            DELETE FROM deck_suggestions
            WHERE status = 'new' AND task_key IN (\(databaseQuestionMarks(count: keys.count)))
            """, arguments: StatementArguments(keys))
    }
}
