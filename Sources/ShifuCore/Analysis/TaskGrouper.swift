import CoreServices
import Foundation
import GRDB

/// Groups classified activities into ongoing tasks and compiles per-day work
/// logs (design.md §5.3). Runs after classification so LLM topics exist.
/// Idempotent over a window, like LedgerBuilder: tasks are keyed stably, day
/// logs are recomputed from scratch for every day the window touches.
public enum TaskGrouper {
    /// A mechanical key never seen before earns a task row only once the
    /// window shows this much time behind it. Passing subjects — a glanced-at
    /// domain, a topic worded once — stay unassigned instead of minting a
    /// permanent task; the idempotent window re-runs grouping, so a key that
    /// keeps accruing time mints and picks up its earlier blocks
    /// retroactively. Keys with an existing task always attach, however small
    /// the block, and `sem:` keys are exempt — SemanticTaskGrouper already
    /// gates them by block length and model confidence.
    public static let minNewTaskMs: Int64 = 5 * 60_000

    /// macOS shell surfaces that are never the user's own work: the lock
    /// screen, the Dock, one-shot system dialogs. They carry no topic and no
    /// domain, so without this list they bottom out at the `app:` key and
    /// mint nonsense tasks ("loginwindow") — ones that accrue time daily and
    /// so stay forever above the prune threshold. Checked through
    /// `isSystemBundle`, which adds two prefix families a set can't
    /// enumerate. Grounded in the dogfood ledger rather than exhaustive: a
    /// missed bundle just means one more junk task until it's added here.
    public static let systemBundles: Set<String> = [
        "com.apple.loginwindow",              // lock/login screen
        "com.apple.dock",
        "com.apple.systemuiserver",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.usernotificationcenter",   // one-shot alert dialogs
        "com.apple.securityagent",            // auth prompts
        "com.apple.screensaverengine",
        "com.apple.coreservices.uiagent",     // quarantine/open-with dialogs
        "com.apple.captivenetworkassistant",  // captive Wi-Fi portal popup
        "com.apple.problemreporter",          // crash-report dialog
        "com.apple.accessibility.universalaccessauthwarn",
        "com.apple.windowmanager",            // Stage Manager shell
        "com.apple.windowmanager.stagemanageronboarding",
        "com.apple.inputmethod.ironwood"      // dictation UI
    ]

    /// True for bundles barred from task grouping entirely — mechanical and
    /// semantic alike (`SemanticTaskGrouper.pendingSamples` mirrors this in
    /// SQL): their blocks keep their ledger time but never mint or join a
    /// task. Covers the `systemBundles` set, CaptureEngine's `unknown.<pid>`
    /// placeholder for processes without a bundle id, and Shifu's own UI
    /// (`com.shifu.*`) — watching the dashboard isn't work to track.
    public static func isSystemBundle(_ bundle: String) -> Bool {
        let normalized = bundle.lowercased()
        if normalized.hasPrefix("unknown.") || normalized.hasPrefix("com.shifu.") { return true }
        return systemBundles.contains(normalized)
    }

    /// True for hosts that name a browser surface rather than a site — no
    /// dot ("new-tab-page", "contextual-tasks", "chromewebdata", extension
    /// ids) or Chrome's WebUI suffix. `Sessionizer.domain(of:)` no longer
    /// derives domains from non-web schemes, so new blocks can't carry
    /// these; the predicate exists for `TaskStore.prune` to reap `domain:`
    /// tasks minted before that gate, the way system-bundle `app:` tasks
    /// are reaped.
    public static func isBrowserInternalHost(_ host: String) -> Bool {
        !host.contains(".") || host.hasSuffix(".top-chrome")
    }

    /// `isSystemBundle` as a SQL predicate, with the values it binds in order.
    ///
    /// Four queries have to agree with the Swift check — the Time page's two
    /// reads (`LedgerBuilder`), the semantic candidate sweep, the radar dossier
    /// — and a hand-copied `NOT LIKE`/`NOT IN` trio silently drifts the first
    /// time a prefix family is added here. `column` is interpolated into SQL, so
    /// it takes a literal column name from a caller in this package, never
    /// user input.
    public static func notSystemBundleSQL(
        column: String = "app_bundle"
    ) -> (clause: String, arguments: [String]) {
        let denied = systemBundles.sorted()
        let clause = """
            LOWER(\(column)) NOT LIKE 'unknown.%'
              AND LOWER(\(column)) NOT LIKE 'com.shifu.%'
              AND LOWER(\(column)) NOT IN (\(databaseQuestionMarks(count: denied.count)))
            """
        return (clause, denied)
    }

    /// What one `run` did: distinct task keys assigned in the window, and
    /// day-log rows rewritten across every local day those activities touched.
    public struct Summary: Equatable, Sendable {
        public var tasksTouched: Int
        public var logsWritten: Int
    }

    // MARK: - Keys (pure, testable)

    /// Stable grouping key for an activity: the topic when classification
    /// produced one (tasks span days because the topic recurs), else the
    /// domain, else the app. Prefixed so the three namespaces never collide.
    /// A semantic assignment (`activities.sem_key`, design.md §5.3) outranks
    /// all three — see `run`, which checks it before calling this.
    public static func key(topic: String?, domain: String?, appBundle: String) -> String {
        if let topic {
            let slug = Self.slug(topic)
            if !slug.isEmpty { return "topic:\(slug)" }
        }
        if let domain, !domain.isEmpty { return "domain:\(domain.lowercased())" }
        return "app:\(appBundle.lowercased())"
    }

    /// Initial display name for a new task; the user can rename it later.
    /// An `app:` fallback asks Launch Services for the installed app's own
    /// name first: the bundle tail is right for `com.apple.dt.xcode` ("xcode")
    /// but wrong exactly when it is generic — `com.conductor.app` minted a
    /// task literally named "app" in the dogfood ledger.
    static func displayName(topic: String?, domain: String?, appBundle: String) -> String {
        topic ?? domain ?? installedAppName(bundleID: appBundle)
            ?? (appBundle.split(separator: ".").last.map(String.init) ?? appBundle)
    }

    /// The user-facing name of the installed app for a bundle id, or nil when
    /// Launch Services knows no such app (tests, uninstalled apps — callers
    /// fall back to the bundle tail). CoreServices, deliberately not
    /// NSWorkspace: ShifuCore links into shifud, which should not pull AppKit.
    static func installedAppName(bundleID: String) -> String? {
        guard let urls = LSCopyApplicationURLsForBundleIdentifier(
                bundleID as CFString, nil)?.takeRetainedValue() as? [URL],
              let appURL = urls.first else { return nil }
        return Bundle(url: appURL).flatMap { bundle in
            bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
        } ?? FileManager.default.displayName(atPath: appURL.path)
    }

    /// True while a task still wears the name the machine gave it — i.e. the
    /// user never renamed it. Every key namespace derives its display name
    /// from the key (or the key from the name, for `sem:`: the LLM's title
    /// slugged), so the question is answerable without storing a flag.
    /// The two callers that must never touch a user's own words rely on it:
    /// `TaskStore.prune` only deletes default-named tasks, and `TaskMerges`
    /// only auto-merges default-named ones.
    public static func isDefaultName(_ name: String, forKey key: String) -> Bool {
        // "sem:booking-flights" ← slug of the LLM title that named the task
        // (SemanticTaskGrouper.resolve), so a rename breaks the equality.
        if key.hasPrefix(SemanticTaskGrouper.keyPrefix) {
            return slug(name) == String(key.dropFirst(SemanticTaskGrouper.keyPrefix.count))
        }
        if key.hasPrefix("topic:") { return slug(name) == String(key.dropFirst(6)) }
        if key.hasPrefix("domain:") { return name.lowercased() == String(key.dropFirst(7)) }
        if key.hasPrefix("app:") {
            let bundle = String(key.dropFirst(4))
            let lastComponent = bundle.split(separator: ".").last.map(String.init) ?? bundle
            if name.lowercased() == lastComponent { return true }
            // The Launch Services name `displayName` now mints with. If the
            // app is gone the lookup is nil and the task reads as user-named —
            // spared from prune/auto-merge, which err on keeping.
            return name == installedAppName(bundleID: bundle)
        }
        return false
    }

    public static func slug(_ text: String) -> String {
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
        var semKey: String?
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
                SELECT id, started_at, ended_at, app_bundle, domain, topic, sem_key
                FROM activities
                WHERE ended_at > ? AND started_at < ? AND category != 'private'
                ORDER BY started_at
                """, arguments: [from, to]
            ).map { row in
                Item(id: row["id"], startedAt: row["started_at"], endedAt: row["ended_at"],
                     appBundle: row["app_bundle"], domain: row["domain"], topic: row["topic"],
                     semKey: row["sem_key"])
            }
        }
        var groups: [String: [Item]] = [:]
        var keyOrder: [String] = []
        for item in items where !isSystemBundle(item.appBundle) {
            let itemKey = item.semKey
                ?? key(topic: item.topic, domain: item.domain, appBundle: item.appBundle)
            if groups[itemKey] == nil { keyOrder.append(itemKey) }
            groups[itemKey, default: []].append(item)
        }
        return GroupedItems(groups: groups, order: keyOrder, items: items)
    }

    /// Assigns `activities.task_id` for the window, creating tasks as needed
    /// (existing names are never overwritten — renames stick; new keys must
    /// clear the minNewTaskMs substance gate), then rebuilds task logs for
    /// every local day the window's activities touch.
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
            var tasksTouched = 0
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
                    // Substance gate for mechanical keys only: a vanished
                    // semantic task is re-minted regardless, since its blocks
                    // already cleared SemanticTaskGrouper's own floor.
                    if !itemKey.hasPrefix(SemanticTaskGrouper.keyPrefix) {
                        let groupMs = group.reduce(Int64(0)) { $0 + ($1.endedAt - $1.startedAt) }
                        guard groupMs >= minNewTaskMs else { continue }
                    }
                    let first = group[0]
                    // Semantic tasks are pre-created (with their LLM title) by
                    // SemanticTaskGrouper; this branch only fires for them if
                    // that row vanished, so fall back to a humanized slug.
                    let name = itemKey.hasPrefix(SemanticTaskGrouper.keyPrefix)
                        ? SemanticTaskGrouper.humanize(key: itemKey)
                        : displayName(topic: first.topic, domain: first.domain,
                                      appBundle: first.appBundle)
                    var task = WorkTask(
                        key: itemKey, name: name,
                        createdAt: nowMs, lastActiveAt: lastActive)
                    try task.insert(db)
                    taskID = task.id ?? db.lastInsertedRowID
                }
                let ids = group.map(\.id)
                let placeholders = databaseQuestionMarks(count: ids.count)
                try db.execute(
                    sql: "UPDATE activities SET task_id = ? WHERE id IN (\(placeholders))",
                    arguments: StatementArguments([taskID] + ids))
                tasksTouched += 1
            }

            var logsWritten = 0
            for day in days {
                logsWritten += try rebuildLogs(db, dayStart: day.start, dayEnd: day.end)
            }
            return Summary(tasksTouched: tasksTouched, logsWritten: logsWritten)
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
    /// The delete is ranged, not `day_start = dayStart`: rows written under a
    /// different timezone sit at a different midnight inside the same day, and
    /// an equality delete would strand them to double-count the day forever.
    @discardableResult
    static func rebuildLogs(_ db: Database, dayStart: Int64, dayEnd: Int64) throws -> Int {
        try db.execute(sql: "DELETE FROM task_logs WHERE day_start >= ? AND day_start < ?",
                       arguments: [dayStart, dayEnd])
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
