import Foundation
import GRDB

/// Groups classified activities into ongoing tasks and compiles per-day work
/// logs (design.md §5.3). Runs after classification so LLM topics exist.
/// Idempotent over a window, like LedgerBuilder: tasks are keyed stably, day
/// logs are recomputed from scratch for every day the window touches.
public enum TaskGrouper {
    public struct Summary: Equatable, Sendable {
        public var tasksTouched: Int
        public var logsWritten: Int
    }

    // MARK: - Keys (pure, testable)

    /// Stable grouping key for an activity: the topic when classification
    /// produced one (tasks span days because the topic recurs), else the
    /// domain, else the app. Prefixed so the three namespaces never collide.
    public static func key(topic: String?, domain: String?, appBundle: String) -> String {
        if let topic {
            let slug = Self.slug(topic)
            if !slug.isEmpty { return "topic:\(slug)" }
        }
        if let domain, !domain.isEmpty { return "domain:\(domain.lowercased())" }
        return "app:\(appBundle.lowercased())"
    }

    /// Initial display name for a new task; the user can rename it later.
    static func displayName(topic: String?, domain: String?, appBundle: String) -> String {
        topic ?? domain ?? (appBundle.split(separator: ".").last.map(String.init) ?? appBundle)
    }

    static func slug(_ text: String) -> String {
        text.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { acc, ch in
                if ch != "-" || acc.last != "-" { acc.append(ch) }
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// One log line: where the time went, then what it was about.
    /// "Xcode, github.com — debugging capture daemon; reading GRDB docs"
    static func summaryLine(sources: [String], topics: [String]) -> String {
        let whereText = sources.prefix(3).joined(separator: ", ")
        let whatText = topics.prefix(3).joined(separator: "; ")
        if whatText.isEmpty { return whereText }
        if whereText.isEmpty { return whatText }
        return "\(whereText) — \(whatText)"
    }

    // MARK: - Pipeline

    private struct Item {
        var id: Int64
        var startedAt: Int64
        var endedAt: Int64
        var appBundle: String
        var domain: String?
        var topic: String?
    }

    private struct GroupedItems {
        var groups: [String: [Item]]
        var order: [String]
        var items: [Item]
    }

    private static func fetchAndGroupItems(
        database: ShifuDatabase, from: Int64, to: Int64
    ) throws -> GroupedItems {
        let items: [Item] = try database.queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, started_at, ended_at, app_bundle, domain, topic
                FROM activities
                WHERE ended_at > ? AND started_at < ? AND category != 'private'
                ORDER BY started_at
                """, arguments: [from, to]
            ).map { row in
                Item(id: row["id"], startedAt: row["started_at"], endedAt: row["ended_at"],
                     appBundle: row["app_bundle"], domain: row["domain"], topic: row["topic"])
            }
        }
        var groups: [String: [Item]] = [:]
        var keyOrder: [String] = []
        for item in items {
            let itemKey = key(topic: item.topic, domain: item.domain, appBundle: item.appBundle)
            if groups[itemKey] == nil { keyOrder.append(itemKey) }
            groups[itemKey, default: []].append(item)
        }
        return GroupedItems(groups: groups, order: keyOrder, items: items)
    }

    /// Assigns `activities.task_id` for the window, creating tasks as needed
    /// (existing names are never overwritten — renames stick), then rebuilds
    /// task logs for every local day the window's activities touch.
    @discardableResult
    public static func run(
        database: ShifuDatabase, from: Int64, to: Int64,
        now: Date = Date(), calendar: Calendar = .current
    ) throws -> Summary {
        let res = try fetchAndGroupItems(database: database, from: from, to: to)
        guard !res.items.isEmpty else { return Summary(tasksTouched: 0, logsWritten: 0) }

        let days = affectedDays(of: res.items.map { ($0.startedAt, $0.endedAt) },
                                calendar: calendar)
        let nowMs = Int64(now.timeIntervalSince1970 * 1_000)

        return try database.queue.write { db in
            for itemKey in res.order {
                guard let group = res.groups[itemKey] else { continue }
                let lastActive = group.map(\.endedAt).max() ?? nowMs
                let taskID: Int64
                if let existing = try Int64.fetchOne(
                    db, sql: "SELECT id FROM tasks WHERE key = ?", arguments: [itemKey]) {
                    taskID = existing
                    try db.execute(
                        sql: "UPDATE tasks SET last_active_at = MAX(last_active_at, ?) WHERE id = ?",
                        arguments: [lastActive, taskID])
                } else {
                    let first = group[0]
                    var task = WorkTask(
                        key: itemKey,
                        name: displayName(topic: first.topic, domain: first.domain,
                                          appBundle: first.appBundle),
                        createdAt: nowMs, lastActiveAt: lastActive)
                    try task.insert(db)
                    taskID = task.id ?? db.lastInsertedRowID
                }
                let ids = group.map(\.id)
                let placeholders = databaseQuestionMarks(count: ids.count)
                try db.execute(
                    sql: "UPDATE activities SET task_id = ? WHERE id IN (\(placeholders))",
                    arguments: StatementArguments([taskID] + ids))
            }

            var logsWritten = 0
            for day in days {
                logsWritten += try rebuildLogs(db, dayStart: day.start, dayEnd: day.end)
            }
            return Summary(tasksTouched: res.groups.count, logsWritten: logsWritten)
        }
    }

    /// Local days ([start, end) in unix ms) covered by the given spans.
    /// Shared with WorkNoteCompiler and DeletionTools (vault-features.md §2.1).
    static func affectedDays(
        of spans: [(start: Int64, end: Int64)], calendar: Calendar
    ) -> [(start: Int64, end: Int64)] {
        var starts: Set<Int64> = []
        var days: [(Int64, Int64)] = []
        for span in spans {
            var day = calendar.startOfDay(for: Date(timeIntervalSince1970: Double(span.start) / 1_000))
            let end = Date(timeIntervalSince1970: Double(span.end) / 1_000)
            while day < end {
                let next = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
                let startMs = Int64(day.timeIntervalSince1970 * 1_000)
                if starts.insert(startMs).inserted {
                    days.append((startMs, Int64(next.timeIntervalSince1970 * 1_000)))
                }
                day = next
            }
        }
        return days.sorted { $0.0 < $1.0 }
    }

    /// Recomputes one day's logs from all task-assigned activities that touch
    /// it (not just the window's), so partial windows can't undercount a day.
    /// Also called by DeletionTools so a forgotten range leaves no stale logs.
    @discardableResult
    static func rebuildLogs(_ db: Database, dayStart: Int64, dayEnd: Int64) throws -> Int {
        try db.execute(sql: "DELETE FROM task_logs WHERE day_start = ?", arguments: [dayStart])
        let rows = try Row.fetchAll(db, sql: """
            SELECT task_id, started_at, ended_at, app_bundle, domain, topic
            FROM activities
            WHERE task_id IS NOT NULL AND ended_at > ? AND started_at < ?
            ORDER BY started_at
            """, arguments: [dayStart, dayEnd])

        struct DayAgg {
            var durationMs: Int64 = 0
            var sources: [String] = []
            var topics: [String] = []
        }
        var perTask: [Int64: DayAgg] = [:]
        var taskOrder: [Int64] = []
        for row in rows {
            let taskID: Int64 = row["task_id"]
            if perTask[taskID] == nil { taskOrder.append(taskID) }
            var agg = perTask[taskID] ?? DayAgg()
            let started: Int64 = row["started_at"]
            let ended: Int64 = row["ended_at"]
            agg.durationMs += min(ended, dayEnd) - max(started, dayStart)
            let bundle: String = row["app_bundle"]
            let source = (row["domain"] as String?)
                ?? (bundle.split(separator: ".").last.map(String.init) ?? bundle)
            if !agg.sources.contains(source) { agg.sources.append(source) }
            if let topic = row["topic"] as String?, !agg.topics.contains(topic) {
                agg.topics.append(topic)
            }
            perTask[taskID] = agg
        }

        for taskID in taskOrder {
            guard let agg = perTask[taskID] else { continue }
            var log = TaskLog(
                taskID: taskID, dayStart: dayStart, durationMs: agg.durationMs,
                summary: summaryLine(sources: agg.sources, topics: agg.topics))
            try log.insert(db)
        }
        return taskOrder.count
    }
}
