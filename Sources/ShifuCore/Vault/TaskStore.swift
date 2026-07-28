import Foundation
import GRDB

/// Read/write API over tasks, themes-of-tasks, and work logs (design.md §5.3)
/// — the queries the Vault tab and review decks are built from.
///
/// A task belongs to a theme *derivatively*: themes are filed per block
/// (`activities.theme_key`), and a task's blocks may straddle several, so a
/// task's theme is the one its time mostly sits in — see `dominantThemeSQL`.
public enum TaskStore {
    /// One row of the Vault tab's task list: a task plus the joined facts the
    /// UI shows beside it.
    public struct Overview: Identifiable, Sendable {
        public var task: WorkTask
        /// The task's dominant theme. Nil while none of its blocks are filed —
        /// the clusterer hasn't reached them, or the user emptied it.
        public var themeKey: String?
        public var themeName: String?
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

    /// One task's work on one day — a `task_logs` row joined to its task name.
    public struct DayLogEntry: Identifiable, Sendable {
        /// The `task_logs` row id. Regenerated whenever the day is rebuilt,
        /// so it is a list identity, not a durable handle.
        public var id: Int64
        public var taskID: Int64
        public var taskName: String
        public var summary: String
        public var durationMs: Int64
        /// The task's dominant theme, derived live from its blocks (not frozen
        /// into the log row), so the Vault tab's theme filter can scope the
        /// day log.
        public var themeKey: String?
    }

    // MARK: - Tasks

    /// Which theme's tasks a `TaskFilter` admits.
    public enum ThemeScope: Sendable, Hashable {
        case any
        case theme(key: String)
        /// Tasks no block of which is filed under a theme yet.
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
        public var themeScope: ThemeScope
        public var sort: Sort
        public var limit: Int

        public init(since: Int64 = 0, minimumMs: Int64 = 0,
                    themeScope: ThemeScope = .any,
                    sort: Sort = .mostRecent, limit: Int = 12) {
            self.since = since
            self.minimumMs = minimumMs
            self.themeScope = themeScope
            self.sort = sort
            self.limit = limit
        }
    }

    /// Tasks matching `filter`, with their theme, time spent inside the
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
                        createdAt: row["created_at"], lastActiveAt: row["last_active_at"]),
                    themeKey: row["theme_key"],
                    themeName: row["theme_name"],
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

    /// One row per task: the theme its time mostly sits in. Blocks are filed
    /// per theme and a task's may straddle several, so "the task's theme" is a
    /// ranking, not a column — biggest share wins, key breaks ties so the
    /// answer is stable across runs. Joined rather than repeated as a
    /// correlated subquery so the name comes along in the same pass and the
    /// scope clause below can filter on it.
    static let dominantThemeSQL = """
        (SELECT task_id, theme_key,
                ROW_NUMBER() OVER (
                    PARTITION BY task_id
                    ORDER BY SUM(ended_at - started_at) DESC, theme_key) AS rank
         FROM activities
         WHERE task_id IS NOT NULL AND theme_key IS NOT NULL
         GROUP BY task_id, theme_key)
        """

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
        let themeClause: String
        switch filter.themeScope {
        case .any:
            themeClause = ""
        case .theme(let key):
            themeClause = "AND dt.theme_key = ?"
            arguments.append(key)
        case .unassigned:
            themeClause = "AND dt.theme_key IS NULL"
        }
        arguments.append(filter.minimumMs)
        let sql = """
            (SELECT t.id, t.key, t.name, t.created_at, t.last_active_at,
                    dt.theme_key AS theme_key, th.name AS theme_name,
                    COALESCE((SELECT SUM(a.ended_at - MAX(a.started_at, ?))
                              FROM activities a
                              WHERE a.task_id = t.id AND a.ended_at > ?), 0) AS total_ms,
                    (SELECT l.summary FROM task_logs l WHERE l.task_id = t.id
                     ORDER BY l.day_start DESC LIMIT 1) AS latest_summary
             FROM tasks t
             LEFT JOIN \(dominantThemeSQL) dt ON dt.task_id = t.id AND dt.rank = 1
             LEFT JOIN themes th ON th.key = dt.theme_key
             WHERE t.last_active_at >= ? \(themeClause))
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
                SELECT l.id, l.task_id, t.name, dt.theme_key, l.summary, l.duration_ms
                FROM task_logs l JOIN tasks t ON t.id = l.task_id
                LEFT JOIN \(dominantThemeSQL) dt ON dt.task_id = t.id AND dt.rank = 1
                WHERE l.day_start = ?
                ORDER BY t.last_active_at DESC, l.duration_ms DESC
                """, arguments: [dayStart]
            ).map { row in
                DayLogEntry(id: row["id"], taskID: row["task_id"], taskName: row["name"],
                            summary: row["summary"], durationMs: row["duration_ms"],
                            themeKey: row["theme_key"])
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

    /// Files a whole task under a theme by hand. Themes live on blocks, so
    /// this writes every one of the task's blocks — anything less and the
    /// dominant-theme ranking above could still land somewhere else, making
    /// the menu look like it didn't take.
    ///
    /// Clearing burns each block's `theme_attempts` instead of just nulling
    /// the key: the clusterer's queue is "blocks with no theme and attempts
    /// left", so without this the next analyzer run would quietly re-file what
    /// the user just emptied. Same mechanism that stops it re-billing blocks
    /// it keeps declining to place. Only blocks that *were* filed are burnt —
    /// "No theme" on a task the clusterer simply hasn't reached yet is a
    /// no-op, not a permanent opt-out.
    public static func assignTheme(
        taskID: Int64, themeKey: String?, database: ShifuDatabase
    ) throws {
        try database.queue.write { db in
            guard let themeKey else {
                try db.execute(sql: """
                    UPDATE activities
                    SET theme_key = NULL, theme_attempts = ?, theme_user_set = 0
                    WHERE task_id = ? AND theme_key IS NOT NULL
                    """, arguments: [ThemeClusterer.maxAttempts, taskID])
                return
            }
            // `theme_user_set` is the hand-filed bit the prune and auto-merge
            // gates read (migration v14). Only this path sets it; the
            // clusterer's own writes leave it 0.
            try db.execute(sql: """
                UPDATE activities SET theme_key = ?, theme_user_set = 1 WHERE task_id = ?
                """, arguments: [themeKey, taskID])
            // The Themes list orders by recency; adopting a task's blocks can
            // only make a theme more recently active, never less.
            try db.execute(sql: """
                UPDATE themes SET last_active_at = MAX(last_active_at, COALESCE(
                    (SELECT MAX(ended_at) FROM activities WHERE task_id = ?), 0))
                WHERE key = ?
                """, arguments: [taskID, themeKey])
        }
    }

    // Merge (vault-features.md §5.2) lives in TaskMerging.swift.
    // Prune (design.md §5.3) lives in TaskPrune.swift.

    // MARK: - Review decks (design.md §5.2: pull cards per task/theme)

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
        /// The task's dominant theme — see `Overview.themeKey`.
        public var themeKey: String?
        public var themeName: String?
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
                SELECT t.id, t.key, t.name, t.created_at, t.last_active_at,
                       t.gist, dt.theme_key, th.name AS theme_name
                FROM tasks t
                LEFT JOIN \(dominantThemeSQL) dt ON dt.task_id = t.id AND dt.rank = 1
                LEFT JOIN themes th ON th.key = dt.theme_key
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
                    createdAt: head["created_at"], lastActiveAt: head["last_active_at"]),
                gist: head["gist"],
                themeKey: head["theme_key"],
                themeName: head["theme_name"],
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
