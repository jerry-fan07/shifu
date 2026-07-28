import Foundation
import GRDB

/// Read/write API over themes (design.md §5.3) — the queries the Vault tab's
/// Themes mode and the theme detail page are built from. Day entries are
/// computed on read from `activities.theme_key`, so there is no parallel log
/// table to keep consistent with the task layer.
public enum ThemeStore {
    /// One row of the Themes list: the theme plus its rolled-up time.
    public struct Overview: Identifiable, Sendable {
        public var id: Int64
        public var key: String
        public var name: String
        public var gist: String?
        public var summary: String?
        public var lastActiveAt: Int64
        public var totalMs: Int64
        public var weekMs: Int64        // last 7 days, for the list's context
    }

    /// One local day of a theme, summarized "where — what".
    public struct DayEntry: Identifiable, Sendable {
        public var dayStart: Int64
        public var durationMs: Int64
        public var summary: String

        public var id: Int64 { dayStart }
    }

    /// A task whose blocks overlap this theme — the drill-down link.
    public struct RelatedTask: Identifiable, Sendable {
        public var taskID: Int64
        public var name: String
        public var ms: Int64

        public var id: Int64 { taskID }
    }

    /// Everything the theme detail page shows.
    public struct Detail: Sendable {
        public var overview: Overview
        public var days: [DayEntry]
        public var tasks: [RelatedTask]
        public var recent: [TaskStore.ActivityLine]
    }

    // MARK: - Queries

    /// Themes, most recently active first.
    public static func overviews(
        database: ShifuDatabase, now: Date = Date(), limit: Int = 30
    ) throws -> [Overview] {
        let weekCutoff = Int64(now.timeIntervalSince1970 * 1_000) - 7 * 86_400_000
        return try database.queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT t.id, t.key, t.name, t.gist, t.summary, t.last_active_at,
                       COALESCE((SELECT SUM(a.ended_at - a.started_at)
                                 FROM activities a WHERE a.theme_key = t.key), 0) AS total_ms,
                       COALESCE((SELECT SUM(a.ended_at - a.started_at)
                                 FROM activities a WHERE a.theme_key = t.key
                                   AND a.ended_at > ?), 0) AS week_ms
                FROM themes t
                ORDER BY t.last_active_at DESC LIMIT ?
                """, arguments: [weekCutoff, limit]
            ).map(overview(from:))
        }
    }

    /// One read for the whole detail page. Nil when the theme doesn't exist.
    public static func detail(
        themeID: Int64, database: ShifuDatabase, calendar: Calendar = .current,
        recentLimit: Int = 40
    ) throws -> Detail? {
        try database.queue.read { db in
            guard let head = try Row.fetchOne(db, sql: """
                SELECT t.id, t.key, t.name, t.gist, t.summary, t.last_active_at,
                       0 AS total_ms, 0 AS week_ms
                FROM themes t WHERE t.id = ?
                """, arguments: [themeID]) else { return nil }
            var over = overview(from: head)

            let rows = try Row.fetchAll(db, sql: """
                SELECT a.id, a.started_at, a.ended_at, a.app_bundle, a.domain,
                       a.topic, a.category, a.task_id, tk.name AS task_name
                FROM activities a LEFT JOIN tasks tk ON tk.id = a.task_id
                WHERE a.theme_key = ? ORDER BY a.started_at DESC
                """, arguments: [over.key])
            let folded = fold(rows, calendar: calendar, recentLimit: recentLimit)
            over.totalMs = folded.totalMs
            return Detail(overview: over, days: folded.days, tasks: folded.tasks,
                          recent: folded.recent)
        }
    }

    private struct DayAgg {
        var ms: Int64 = 0
        var sources: [String] = []
        var topics: [String] = []
    }

    private struct Folded {
        var totalMs: Int64 = 0
        var days: [DayEntry] = []
        var tasks: [RelatedTask] = []
        var recent: [TaskStore.ActivityLine] = []
    }

    /// Folds a theme's activity rows (newest first) into the page's shapes.
    private static func fold(
        _ rows: [Row], calendar: Calendar, recentLimit: Int
    ) -> Folded {
        var out = Folded()
        var dayAggs: [Int64: DayAgg] = [:]
        var dayOrder: [Int64] = []
        var taskNames: [Int64: String] = [:]
        var taskTotals: [Int64: Int64] = [:]
        for row in rows {
            let started: Int64 = row["started_at"]
            let ended: Int64 = row["ended_at"]
            let bundle: String = row["app_bundle"]
            let source = (row["domain"] as String?)
                ?? (bundle.split(separator: ".").last.map(String.init) ?? bundle)
            out.totalMs += ended - started

            let day = calendar.startOfDay(
                for: Date(timeIntervalSince1970: Double(started) / 1_000))
            let dayMs = Int64(day.timeIntervalSince1970 * 1_000)
            if dayAggs[dayMs] == nil { dayOrder.append(dayMs) }
            var agg = dayAggs[dayMs] ?? DayAgg()
            agg.ms += ended - started
            if !agg.sources.contains(source) { agg.sources.append(source) }
            if let topic = row["topic"] as String?, !agg.topics.contains(topic) {
                agg.topics.append(topic)
            }
            dayAggs[dayMs] = agg

            if let taskID = row["task_id"] as Int64?, let name = row["task_name"] as String? {
                taskNames[taskID] = name
                taskTotals[taskID, default: 0] += ended - started
            }
            if out.recent.count < recentLimit {
                out.recent.append(TaskStore.ActivityLine(
                    id: row["id"], startedAt: started, endedAt: ended,
                    source: source, topic: row["topic"], category: row["category"]))
            }
        }
        out.days = dayOrder.compactMap { dayMs -> DayEntry? in
            guard let agg = dayAggs[dayMs] else { return nil }
            return DayEntry(
                dayStart: dayMs, durationMs: agg.ms,
                summary: TaskGrouper.summaryLine(sources: agg.sources, topics: agg.topics))
        }
        out.tasks = taskTotals
            .compactMap { taskID, ms -> RelatedTask? in
                guard let name = taskNames[taskID] else { return nil }
                return RelatedTask(taskID: taskID, name: name, ms: ms)
            }
            .sorted { $0.ms > $1.ms }
        return out
    }

    /// Grouping keys of the tasks whose blocks sit in a theme — a theme review
    /// deck is the union of its tasks' decks.
    public static func taskKeys(themeKey: String, database: ShifuDatabase) throws -> [String] {
        try database.queue.read { db in
            try String.fetchAll(db, sql: """
                SELECT DISTINCT t.key FROM tasks t
                JOIN activities a ON a.task_id = t.id
                WHERE a.theme_key = ?
                """, arguments: [themeKey])
        }
    }

    // MARK: - Writes

    /// Mints a theme by hand (or returns the one already under that name), so
    /// the user isn't limited to the initiatives the clusterer happened to
    /// find. Keyed like a clustered one — `thm:<slug>` — so the two are
    /// indistinguishable everywhere downstream, and reusable by the clusterer's
    /// roster on the next run.
    @discardableResult
    public static func create(
        named name: String, database: ShifuDatabase, now: Date = Date()
    ) throws -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let key = ThemeClusterer.keyPrefix + TaskGrouper.slug(trimmed)
        let nowMs = Int64(now.timeIntervalSince1970 * 1_000)
        try database.queue.write { db in
            try db.execute(sql: """
                INSERT INTO themes (key, name, created_at, last_active_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(key) DO NOTHING
                """, arguments: [key, trimmed, nowMs, nowMs])
        }
        return key
    }

    public static func rename(themeID: Int64, to name: String, database: ShifuDatabase) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try database.queue.write { db in
            try db.execute(sql: "UPDATE themes SET name = ? WHERE id = ?",
                           arguments: [trimmed, themeID])
        }
    }

    private static func overview(from row: Row) -> Overview {
        Overview(id: row["id"], key: row["key"], name: row["name"], gist: row["gist"],
                 summary: row["summary"], lastActiveAt: row["last_active_at"],
                 totalMs: row["total_ms"], weekMs: row["week_ms"])
    }
}
