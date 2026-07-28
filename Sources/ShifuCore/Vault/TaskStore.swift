import Foundation
import GRDB

/// Read/write API over tasks, projects, and work logs (design.md §5.3) —
/// the queries the Vault tab and review decks are built from.
public enum TaskStore {
    /// One row of the Vault tab's task list: a task plus the joined facts the
    /// UI shows beside it.
    public struct Overview: Identifiable, Sendable {
        public var task: WorkTask
        /// Nil when the task hasn't been assigned to a project.
        public var projectName: String?
        /// Time spent inside the filter's window — lifetime under the default
        /// (`since: 0`) filter, clipped to `since` otherwise, so the number
        /// beside a row always matches the range the user picked.
        public var totalMs: Int64
        /// The most recent day log's summary line — the "very brief
        /// explanation" of what this task has been. Nil before the analyzer
        /// has compiled a log for it.
        public var latestSummary: String?

        public var id: Int64 { task.id ?? 0 }
    }

    /// A project with its rolled-up task count and time.
    public struct ProjectSummary: Identifiable, Sendable {
        public var project: Project
        public var taskCount: Int
        public var totalMs: Int64

        public var id: Int64 { project.id ?? 0 }
    }

    /// One task's work on one day — a `task_logs` row joined to its task name.
    public struct DayLogEntry: Identifiable, Sendable {
        /// The `task_logs` row id. Regenerated whenever the day is rebuilt,
        /// so it is a list identity, not a durable handle.
        public var id: Int64
        public var taskID: Int64
        public var taskName: String
        public var summary: String
        public var durationMs: Int64
    }

    // MARK: - Tasks

    /// Which project's tasks a `TaskFilter` admits.
    public enum ProjectScope: Sendable, Hashable {
        case any
        case project(id: Int64)
        /// Tasks the user hasn't filed anywhere yet.
        case unassigned
    }

    /// Recency (when it was worked) or time (how much) — the two ways a task
    /// list is worth reading.
    public enum Sort: Sendable, Hashable {
        case mostRecent
        case mostTime
    }

    /// How the Vault tab's Task log narrows and orders its task list
    /// (design.md §5.3). The default is the whole roster, most recently
    /// worked first — the list as it reads with no filter applied.
    public struct TaskFilter: Sendable, Hashable {
        /// Unix ms cutoff: a task appears only if it was worked at or after
        /// this instant. 0 means all time, which is also what makes the
        /// clipped `totalMs` below collapse to the lifetime total.
        public var since: Int64
        /// Drops tasks with less than this much time inside the window. The
        /// grouper mints a task per distinct subject, so a real roster is
        /// mostly one-off minutes; without this the list is unreadable
        /// whatever the range.
        public var minimumMs: Int64
        public var projectScope: ProjectScope
        public var sort: Sort
        public var limit: Int

        public init(since: Int64 = 0, minimumMs: Int64 = 0,
                    projectScope: ProjectScope = .any,
                    sort: Sort = .mostRecent, limit: Int = 12) {
            self.since = since
            self.minimumMs = minimumMs
            self.projectScope = projectScope
            self.sort = sort
            self.limit = limit
        }
    }

    /// Tasks matching `filter`, with their project, time spent inside the
    /// filter's window, and the latest day-log line (the "very brief
    /// explanation").
    ///
    /// `t.last_active_at` is the max `ended_at` across a task's activities, so
    /// filtering on it is exactly "worked since" (the window always ends now)
    /// and it rides `idx_tasks_last_active`. Sorting by it is likewise exact.
    public static func recentTasks(
        database: ShifuDatabase, filter: TaskFilter = TaskFilter()
    ) throws -> [Overview] {
        let matching = matchingTasksSQL(filter)
        // total_ms is an output alias, which SQLite allows ORDER BY to name.
        let order = switch filter.sort {
        case .mostRecent: "last_active_at DESC"
        case .mostTime: "total_ms DESC, last_active_at DESC"
        }

        return try database.queue.read { db in
            try Row.fetchAll(
                db, sql: "SELECT * FROM \(matching.sql) ORDER BY \(order) LIMIT ?",
                arguments: StatementArguments(matching.arguments + [filter.limit])
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

    /// How many tasks the filter admits before `limit` truncates. The Task log
    /// shows this beside the row count: with a few hundred tasks in every
    /// range, an unlabelled capped list looks identical whatever you pick, and
    /// the filters read as broken.
    public static func matchingTaskCount(
        database: ShifuDatabase, filter: TaskFilter
    ) throws -> Int {
        let matching = matchingTasksSQL(filter)
        return try database.queue.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM \(matching.sql)",
                arguments: StatementArguments(matching.arguments)) ?? 0
        }
    }

    /// The filtered set as a subquery, shared by the page and its count so the
    /// two can't drift. Time is summed inside the window (activities that
    /// straddle `since` are clipped to it), which is also what `minimumMs`
    /// measures against.
    private static func matchingTasksSQL(
        _ filter: TaskFilter
    ) -> (sql: String, arguments: [any DatabaseValueConvertible]) {
        var arguments: [any DatabaseValueConvertible] = [
            filter.since, filter.since, filter.since
        ]
        let projectClause: String
        switch filter.projectScope {
        case .any:
            projectClause = ""
        case .project(let projectID):
            projectClause = "AND t.project_id = ?"
            arguments.append(projectID)
        case .unassigned:
            projectClause = "AND t.project_id IS NULL"
        }
        arguments.append(filter.minimumMs)
        let sql = """
            (SELECT t.id, t.key, t.name, t.project_id, t.created_at, t.last_active_at,
                    p.name AS project_name,
                    COALESCE((SELECT SUM(a.ended_at - MAX(a.started_at, ?))
                              FROM activities a
                              WHERE a.task_id = t.id AND a.ended_at > ?), 0) AS total_ms,
                    (SELECT l.summary FROM task_logs l WHERE l.task_id = t.id
                     ORDER BY l.day_start DESC LIMIT 1) AS latest_summary
             FROM tasks t LEFT JOIN projects p ON p.id = t.project_id
             WHERE t.last_active_at >= ? \(projectClause))
            WHERE total_ms >= ?
            """
        return (sql, arguments)
    }

    /// Compiled work log for one local day, most recently worked task first
    /// (ties broken by time spent), so the newest work reads from the top.
    ///
    /// Recency comes from `tasks.last_active_at`, which is the max `ended_at`
    /// across *all* of a task's activities — so the ordering is exactly
    /// recency-of-work when `dayStart` is the current day (the only way the
    /// UI calls this). For an older day it degrades to "task touched most
    /// recently since", not "worked last that day".
    public static func logs(dayStart: Int64, database: ShifuDatabase) throws -> [DayLogEntry] {
        try database.queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT l.id, l.task_id, t.name, l.summary, l.duration_ms
                FROM task_logs l JOIN tasks t ON t.id = l.task_id
                WHERE l.day_start = ?
                ORDER BY t.last_active_at DESC, l.duration_ms DESC
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

    // Prune (design.md §5.3) lives in TaskPrune.swift.

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

// MARK: - Task detail page (design.md §5.3)

extension TaskStore {
    public struct DayRow: Identifiable, Sendable {
        public var dayStart: Int64          // local-midnight unix ms
        public var durationMs: Int64
        public var summary: String

        public var id: Int64 { dayStart }
    }

    public struct SourceShare: Identifiable, Sendable {
        public var source: String           // domain, or app-bundle tail
        public var ms: Int64

        public var id: String { source }
    }

    public struct NoteLink: Identifiable, Sendable {
        public var noteID: String
        public var path: String             // relative to the vault root
        public var title: String
        public var captured: Int64?

        public var id: String { noteID }
    }

    public struct ActivityLine: Identifiable, Sendable {
        public var id: Int64
        public var startedAt: Int64
        public var endedAt: Int64
        public var source: String
        public var topic: String?
        public var category: String
    }

    /// Everything the task detail page shows: the task and its LLM gist,
    /// day-by-day history, where the time went, the knowledge notes captured
    /// under it, and the most recent activity blocks.
    public struct Detail: Sendable {
        public var task: WorkTask
        public var gist: String?
        public var projectName: String?
        public var totalMs: Int64
        public var days: [DayRow]
        public var sources: [SourceShare]
        public var notes: [NoteLink]
        public var recent: [ActivityLine]
    }

    /// One read for the whole page. Nil when the task doesn't exist.
    public static func detail(
        taskID: Int64, database: ShifuDatabase, recentLimit: Int = 40
    ) throws -> Detail? {
        try database.queue.read { db in
            guard let head = try Row.fetchOne(db, sql: """
                SELECT t.id, t.key, t.name, t.project_id, t.created_at, t.last_active_at,
                       t.gist, p.name AS project_name
                FROM tasks t LEFT JOIN projects p ON p.id = t.project_id
                WHERE t.id = ?
                """, arguments: [taskID]) else { return nil }

            let days = try Row.fetchAll(db, sql: """
                SELECT day_start, duration_ms, summary FROM task_logs
                WHERE task_id = ? ORDER BY day_start DESC
                """, arguments: [taskID]
            ).map { row in
                DayRow(dayStart: row["day_start"], durationMs: row["duration_ms"],
                       summary: row["summary"])
            }

            let activity = try activitySummary(db, taskID: taskID, recentLimit: recentLimit)

            let notes = try Row.fetchAll(db, sql: """
                SELECT i.note_id, i.path, i.captured, f.title
                FROM vault_index i JOIN vault_fts f ON f.rowid = i.id
                WHERE i.kind = 'knowledge' AND i.task_id = ?
                ORDER BY i.captured DESC LIMIT 50
                """, arguments: [taskID]
            ).map { row in
                NoteLink(noteID: row["note_id"], path: row["path"],
                         title: row["title"], captured: row["captured"])
            }

            return Detail(
                task: WorkTask(
                    id: head["id"], key: head["key"], name: head["name"],
                    projectID: head["project_id"], createdAt: head["created_at"],
                    lastActiveAt: head["last_active_at"]),
                gist: head["gist"],
                projectName: head["project_name"],
                totalMs: activity.totalMs,
                days: days,
                sources: activity.sources,
                notes: notes,
                recent: activity.recent)
        }
    }

    private struct ActivityRollup {
        var totalMs: Int64 = 0
        var sources: [SourceShare] = []
        var recent: [ActivityLine] = []
    }

    /// One pass over the task's activities: lifetime total, per-source time
    /// (biggest first), and the newest `recentLimit` lines.
    private static func activitySummary(
        _ db: Database, taskID: Int64, recentLimit: Int
    ) throws -> ActivityRollup {
        var rollup = ActivityRollup()
        var shares: [String: Int64] = [:]
        var order: [String] = []
        for row in try Row.fetchAll(db, sql: """
            SELECT id, started_at, ended_at, app_bundle, domain, topic, category
            FROM activities WHERE task_id = ? ORDER BY started_at DESC
            """, arguments: [taskID]) {
            let started: Int64 = row["started_at"]
            let ended: Int64 = row["ended_at"]
            let bundle: String = row["app_bundle"]
            let source = (row["domain"] as String?)
                ?? (bundle.split(separator: ".").last.map(String.init) ?? bundle)
            rollup.totalMs += ended - started
            if shares[source] == nil { order.append(source) }
            shares[source, default: 0] += ended - started
            if rollup.recent.count < recentLimit {
                rollup.recent.append(ActivityLine(
                    id: row["id"], startedAt: started, endedAt: ended,
                    source: source, topic: row["topic"], category: row["category"]))
            }
        }
        rollup.sources = order
            .map { SourceShare(source: $0, ms: shares[$0] ?? 0) }
            .sorted { $0.ms > $1.ms }
        return rollup
    }
}
