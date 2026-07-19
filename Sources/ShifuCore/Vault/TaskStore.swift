import Foundation
import GRDB

/// Read/write API over tasks, projects, and work logs (design.md §5.3) —
/// the queries the Vault tab and review decks are built from.
public enum TaskStore {
    public struct Overview: Identifiable, Sendable {
        public var task: WorkTask
        public var projectName: String?
        public var totalMs: Int64
        public var latestSummary: String?

        public var id: Int64 { task.id ?? 0 }
    }

    public struct ProjectSummary: Identifiable, Sendable {
        public var project: Project
        public var taskCount: Int
        public var totalMs: Int64

        public var id: Int64 { project.id ?? 0 }
    }

    public struct DayLogEntry: Identifiable, Sendable {
        public var id: Int64
        public var taskID: Int64
        public var taskName: String
        public var summary: String
        public var durationMs: Int64
    }

    // MARK: - Tasks

    /// Most recently active tasks with their project, lifetime time spent,
    /// and the latest day-log line (the "very brief explanation").
    public static func recentTasks(database: ShifuDatabase, limit: Int = 12) throws -> [Overview] {
        try database.queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT t.id, t.key, t.name, t.project_id, t.created_at, t.last_active_at,
                       p.name AS project_name,
                       COALESCE((SELECT SUM(a.ended_at - a.started_at)
                                 FROM activities a WHERE a.task_id = t.id), 0) AS total_ms,
                       (SELECT l.summary FROM task_logs l WHERE l.task_id = t.id
                        ORDER BY l.day_start DESC LIMIT 1) AS latest_summary
                FROM tasks t LEFT JOIN projects p ON p.id = t.project_id
                ORDER BY t.last_active_at DESC LIMIT ?
                """, arguments: [limit]
            ).map { row in
                Overview(
                    task: WorkTask(
                        id: row["id"], key: row["key"], name: row["name"],
                        projectID: row["project_id"], createdAt: row["created_at"],
                        lastActiveAt: row["last_active_at"]),
                    projectName: row["project_name"],
                    totalMs: row["total_ms"],
                    latestSummary: row["latest_summary"])
            }
        }
    }

    /// Compiled work log for one local day, biggest tasks first.
    public static func logs(dayStart: Int64, database: ShifuDatabase) throws -> [DayLogEntry] {
        try database.queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT l.id, l.task_id, t.name, l.summary, l.duration_ms
                FROM task_logs l JOIN tasks t ON t.id = l.task_id
                WHERE l.day_start = ?
                ORDER BY l.duration_ms DESC
                """, arguments: [dayStart]
            ).map { row in
                DayLogEntry(id: row["id"], taskID: row["task_id"], taskName: row["name"],
                            summary: row["summary"], durationMs: row["duration_ms"])
            }
        }
    }

    public static func rename(taskID: Int64, to name: String, database: ShifuDatabase) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try database.queue.write { db in
            try db.execute(sql: "UPDATE tasks SET name = ? WHERE id = ?",
                           arguments: [trimmed, taskID])
        }
    }

    public static func assign(taskID: Int64, projectID: Int64?, database: ShifuDatabase) throws {
        try database.queue.write { db in
            try db.execute(sql: "UPDATE tasks SET project_id = ? WHERE id = ?",
                           arguments: [projectID, taskID])
        }
    }

    // MARK: - Merge (vault-features.md §5.2 — always user-confirmed)

    /// Folds one task into another: activities repoint to the survivor (which
    /// keeps its user-chosen name), the absorbed task dies (its task_logs
    /// cascade away), and the affected days' logs and work notes recompile —
    /// the absorbed task's note files are removed and its content re-lands
    /// under the survivor. Historical rows outside the affected days are
    /// untouched.
    public static func merge(
        survivorID: Int64, absorbedID: Int64, database: ShifuDatabase,
        vault: VaultStore? = nil, calendar: Calendar = .current
    ) throws {
        guard survivorID != absorbedID else { return }
        let spans: [(start: Int64, end: Int64)] = try database.queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT started_at, ended_at FROM activities WHERE task_id = ?
                """, arguments: [absorbedID]
            ).map { ($0["started_at"], $0["ended_at"]) }
        }
        let days = TaskGrouper.affectedDays(of: spans, calendar: calendar)

        try database.queue.write { db in
            try db.execute(sql: "UPDATE activities SET task_id = ? WHERE task_id = ?",
                           arguments: [survivorID, absorbedID])
            try db.execute(sql: """
                UPDATE tasks SET last_active_at = MAX(last_active_at,
                    COALESCE((SELECT last_active_at FROM tasks WHERE id = ?), 0))
                WHERE id = ?
                """, arguments: [absorbedID, survivorID])
            try db.execute(sql: "DELETE FROM tasks WHERE id = ?", arguments: [absorbedID])
            // The accepted pair is recorded; other open suggestions naming the
            // dead task are meaningless now and go away.
            try db.execute(sql: """
                UPDATE task_merge_suggestions SET status = 'merged'
                WHERE (task_a = ? AND task_b = ?) OR (task_a = ? AND task_b = ?)
                """, arguments: [survivorID, absorbedID, absorbedID, survivorID])
            try db.execute(sql: """
                DELETE FROM task_merge_suggestions
                WHERE status = 'new' AND (task_a = ? OR task_b = ?)
                """, arguments: [absorbedID, absorbedID])
            for day in days {
                try TaskGrouper.rebuildLogs(db, dayStart: day.start, dayEnd: day.end)
            }
        }
        if let vault {
            try WorkNoteCompiler.recompile(
                days: days, database: database, vault: vault, calendar: calendar)
        }
    }

    // MARK: - Projects

    /// Creates a project (or returns the existing one with the same name).
    @discardableResult
    public static func createProject(named name: String, database: ShifuDatabase) throws -> Project {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return try database.queue.write { db in
            if let existing = try Project
                .filter(sql: "name = ?", arguments: [trimmed]).fetchOne(db) {
                return existing
            }
            var project = Project(
                name: trimmed, createdAt: Int64(Date().timeIntervalSince1970 * 1_000))
            try project.insert(db)
            return project
        }
    }

    /// All projects with task counts and total time spent across their tasks.
    public static func projects(database: ShifuDatabase) throws -> [ProjectSummary] {
        try database.queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT p.id, p.name, p.created_at,
                       (SELECT COUNT(*) FROM tasks t WHERE t.project_id = p.id) AS task_count,
                       COALESCE((SELECT SUM(a.ended_at - a.started_at)
                                 FROM activities a JOIN tasks t ON a.task_id = t.id
                                 WHERE t.project_id = p.id), 0) AS total_ms
                FROM projects p ORDER BY p.name
                """
            ).map { row in
                ProjectSummary(
                    project: Project(id: row["id"], name: row["name"], createdAt: row["created_at"]),
                    taskCount: row["task_count"],
                    totalMs: row["total_ms"])
            }
        }
    }

    /// Grouping keys of a project's tasks — a project review deck is the
    /// union of its task decks.
    public static func taskKeys(projectID: Int64, database: ShifuDatabase) throws -> [String] {
        try database.queue.read { db in
            try String.fetchAll(db, sql: "SELECT key FROM tasks WHERE project_id = ?",
                                arguments: [projectID])
        }
    }

    // MARK: - Review decks (design.md §5.2: pull cards per task/project)

    /// The grouping key a vault note would fall under, mirroring how the
    /// note's source activity was grouped.
    public static func noteKey(_ note: Note) -> String {
        TaskGrouper.key(
            topic: note.topic,
            domain: note.sourceURL.flatMap { URL(string: $0)?.host },
            appBundle: note.sourceApp ?? "")
    }

    /// Whether a note belongs to a task's deck. Notes stamped with an explicit
    /// `task_key` at extraction time (vault-features.md §2.3) match exactly;
    /// the slug heuristic below survives only for pre-existing notes: exact
    /// key match, or containment between topic slugs (extractor and
    /// classifier word the same subject slightly differently).
    public static func matches(note: Note, taskKey: String) -> Bool {
        if let stamped = note.taskKey { return stamped == taskKey }
        let noteKey = Self.noteKey(note)
        if noteKey == taskKey { return true }
        guard noteKey.hasPrefix("topic:"), taskKey.hasPrefix("topic:") else { return false }
        let noteSlug = noteKey.dropFirst(6)
        let taskSlug = taskKey.dropFirst(6)
        return noteSlug.contains(taskSlug) || taskSlug.contains(noteSlug)
    }
}
