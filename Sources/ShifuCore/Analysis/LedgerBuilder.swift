import Foundation
import GRDB

/// Turns raw observations into ledger rows: sessionize → classify → write.
/// Rebuilds a time window idempotently, so re-runs and rule changes are safe
/// (implementation.md Phase 2 item 3).
public enum LedgerBuilder {
    /// What one `rebuild` did. `blocksWritten` counts rows *written*, not rows
    /// newly discovered — a rebuild over an unchanged window rewrites every
    /// block and reports them all.
    public struct Summary: Equatable, Sendable {
        public var blocksWritten: Int
        public var observationsProcessed: Int
    }

    /// Span identity of one activity: the sessionizer reproduces unchanged
    /// blocks byte-identically, so this is what "same block as last run" means
    /// (same notion as WorkNoteCompiler.HashEntry).
    private struct SpanKey: Hashable {
        var startedAt: Int64
        var endedAt: Int64
        var appBundle: String
    }

    /// Derived state that must outlive a rebuild: LLM verdicts, the extraction
    /// ledger, the ambiguous-retry counter, and the semantic task and theme
    /// assignments (design.md §5.3). Everything else is recomputed from rules.
    private struct CarriedState {
        var category: Category?
        var topic: String?
        var confidence: Double?
        var llmLabeled: Bool
        var extracted: Bool
        var llmAttempts: Int
        var semKey: String?
        var semAttempts: Int
        var themeKey: String?
        var themeAttempts: Int
        /// Hand filing (v14). Carried like the rest, and for the same reason:
        /// a rebuild that dropped it would silently un-protect the task from
        /// prune and auto-merge an hour after the user filed it.
        var themeUserSet: Bool
    }

    /// Rebuilds all activities overlapping [from, to). Blocks whose spans are
    /// reproduced unchanged keep their LLM labels and `extracted` flag, so
    /// re-runs never re-bill the LLM tiers. Returns what was done.
    @discardableResult
    public static func rebuild(
        database: ShifuDatabase,
        classifier: RulesClassifier,
        from: Int64,
        to: Int64
    ) throws -> Summary {
        let observations = try database.queue.read { db in
            try Observation
                .filter(Column("last_seen") >= from && Column("started_at") < to)
                .order(Column("started_at"))
                .fetchAll(db)
        }
        let blocks = Sessionizer.sessionize(observations)

        let activities: [(Activity, [Int64])] = blocks.map { block in
            let result = classifier.classify(block: block)
            let activity = Activity(
                startedAt: block.startedAt,
                endedAt: block.endedAt,
                appBundle: block.appBundle,
                domain: block.domain,
                category: result.category,
                source: result.source,
                ambiguous: result.ambiguous
            )
            return (activity, block.observationIDs)
        }

        try database.queue.write { db in
            // Derived state costs LLM tokens to recreate; snapshot it before
            // the delete and restore it onto span-identical re-inserted rows.
            let carried = try carriedDerivedState(db, from: from, to: to)

            // Replace anything overlapping the window (spanning blocks included).
            try db.execute(
                sql: "DELETE FROM activities WHERE ended_at > ? AND started_at < ?",
                arguments: [from, to]
            )
            for (activity, observationIDs) in activities {
                try insert(activity, observationIDs: observationIDs, carried: carried, in: db)
            }
        }
        return Summary(blocksWritten: activities.count, observationsProcessed: observations.count)
    }

    /// The window's LLM verdicts and extraction flags, keyed by span identity.
    private static func carriedDerivedState(
        _ db: Database, from: Int64, to: Int64
    ) throws -> [SpanKey: CarriedState] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT started_at, ended_at, app_bundle, category, topic,
                   confidence, source, extracted, llm_attempts,
                   sem_key, sem_attempts, theme_key, theme_attempts, theme_user_set
            FROM activities
            WHERE ended_at > ? AND started_at < ?
              AND (source = 'llm' OR extracted = 1 OR llm_attempts > 0
                   OR sem_key IS NOT NULL OR sem_attempts > 0
                   OR theme_key IS NOT NULL OR theme_attempts > 0
                   OR theme_user_set = 1)
            """, arguments: [from, to])
        var carried: [SpanKey: CarriedState] = [:]
        for row in rows {
            let key = SpanKey(startedAt: row["started_at"], endedAt: row["ended_at"],
                              appBundle: row["app_bundle"])
            let source: String = row["source"]
            let categoryRaw: String = row["category"]
            carried[key] = CarriedState(
                category: Category(rawValue: categoryRaw),
                topic: row["topic"],
                confidence: row["confidence"],
                llmLabeled: source == "llm",
                extracted: row["extracted"],
                llmAttempts: row["llm_attempts"],
                semKey: row["sem_key"],
                semAttempts: row["sem_attempts"],
                themeKey: row["theme_key"],
                themeAttempts: row["theme_attempts"],
                themeUserSet: row["theme_user_set"]
            )
        }
        return carried
    }

    /// Inserts one freshly classified block, restoring any carried derived
    /// state, and links its observations to the new row.
    private static func insert(
        _ fresh: Activity, observationIDs: [Int64],
        carried: [SpanKey: CarriedState], in db: Database
    ) throws {
        var activity = fresh
        let key = SpanKey(startedAt: activity.startedAt, endedAt: activity.endedAt,
                          appBundle: activity.appBundle)
        let prior = carried[key]
        // An LLM verdict survives only while the rules tier is still
        // ambiguous — a new concrete/user rule outranks it (§4.2).
        if let prior, prior.llmLabeled, activity.ambiguous,
           let priorCategory = prior.category {
            activity.category = priorCategory
            activity.topic = prior.topic
            activity.confidence = prior.confidence
            activity.source = "llm"
            activity.ambiguous = false
        }
        try activity.insert(db)
        guard let sessionID = activity.id else { return }
        // Restore the extraction ledger, the retry counters, and the semantic
        // task assignment onto the span-identical row so no LLM pass re-bills
        // a block the rebuild just recreated.
        if let prior, prior.extracted || prior.llmAttempts > 0 {
            try db.execute(
                sql: "UPDATE activities SET extracted = ?, llm_attempts = ? WHERE id = ?",
                arguments: [prior.extracted, prior.llmAttempts, sessionID])
        }
        if let prior, prior.semKey != nil || prior.semAttempts > 0 {
            try db.execute(
                sql: "UPDATE activities SET sem_key = ?, sem_attempts = ? WHERE id = ?",
                arguments: [prior.semKey, prior.semAttempts, sessionID])
        }
        if let prior, prior.themeKey != nil || prior.themeAttempts > 0 || prior.themeUserSet {
            try db.execute(sql: """
                UPDATE activities
                SET theme_key = ?, theme_attempts = ?, theme_user_set = ? WHERE id = ?
                """, arguments: [prior.themeKey, prior.themeAttempts,
                                 prior.themeUserSet, sessionID])
        }
        if !observationIDs.isEmpty {
            let placeholders = databaseQuestionMarks(count: observationIDs.count)
            try db.execute(
                sql: "UPDATE observations SET session_id = ? WHERE id IN (\(placeholders))",
                arguments: StatementArguments([sessionID] + observationIDs)
            )
        }
    }

    /// One activity with its display labels resolved — Time-tab fuel for the
    /// category/theme/task breakdown lenses (design.md §7). Task and theme
    /// names come from joins, because `Activity` deliberately doesn't mirror
    /// `task_id`/`theme_key`.
    public struct LabeledActivity: Identifiable, Sendable {
        public var id: Int64
        public var startedAt: Int64
        public var endedAt: Int64
        public var category: String
        public var source: String       // domain, or app-bundle tail
        public var taskName: String?
        public var themeName: String?

        public var durationMs: Int64 { endedAt - startedAt }

        public init(
            id: Int64, startedAt: Int64, endedAt: Int64, category: String, source: String,
            taskName: String? = nil, themeName: String? = nil
        ) {
            self.id = id
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.category = category
            self.source = source
            self.taskName = taskName
            self.themeName = themeName
        }
    }

    /// Labeled activities overlapping [from, to), oldest first.
    ///
    /// System shells are left out (`TaskGrouper.isSystemBundle`). They are
    /// barred from task grouping, so counting them here charts hours the Task
    /// log has no row for — and the lock screen is not a group the user can
    /// reach through any lens. It is not a rounding difference: the dogfood
    /// ledger held 849 h of `loginwindow`, enough that opening the Time page on
    /// one of those days showed nothing else at all.
    public static func labeledActivities(
        database: ShifuDatabase, from: Int64, to: Int64
    ) throws -> [LabeledActivity] {
        let denied = TaskGrouper.notSystemBundleSQL(column: "a.app_bundle")
        return try database.queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT a.id, a.started_at, a.ended_at, a.category, a.domain, a.app_bundle,
                       t.name AS task_name, th.name AS theme_name
                FROM activities a
                LEFT JOIN tasks t ON t.id = a.task_id
                LEFT JOIN themes th ON th.key = a.theme_key
                WHERE a.ended_at > ? AND a.started_at < ? AND \(denied.clause)
                ORDER BY a.started_at
                """, arguments: [from, to] + StatementArguments(denied.arguments)
            ).map { row in
                let bundle: String = row["app_bundle"]
                return LabeledActivity(
                    id: row["id"], startedAt: row["started_at"], endedAt: row["ended_at"],
                    category: row["category"],
                    source: (row["domain"] as String?)
                        ?? (bundle.split(separator: ".").last.map(String.init) ?? bundle),
                    taskName: row["task_name"], themeName: row["theme_name"])
            }
        }
    }

    /// Category totals (ms) for activities overlapping [from, to) — dashboard
    /// fuel. Skips system shells for the same reason `labeledActivities` does,
    /// so Today's rings, the menu bar's hours and the digest agree with the
    /// Time page rather than each counting a different day.
    public static func totals(
        database: ShifuDatabase, from: Int64, to: Int64
    ) throws -> [Category: Int64] {
        let denied = TaskGrouper.notSystemBundleSQL()
        let rows = try database.queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT category, SUM(MIN(ended_at, ?) - MAX(started_at, ?)) AS ms
                FROM activities WHERE ended_at > ? AND started_at < ? AND \(denied.clause)
                GROUP BY category
                """, arguments: [to, from, from, to] + StatementArguments(denied.arguments))
        }
        var totals: [Category: Int64] = [:]
        for row in rows {
            if let category = Category(rawValue: row["category"]) {
                totals[category] = row["ms"]
            }
        }
        return totals
    }
}

/// Retention (design.md §3.5, §8): raw text survives a bounded window; the
/// derived ledger survives indefinitely.
public enum Retention {
    public static let defaultDays = 14

    /// Scrubs text from observations older than the window. Returns rows scrubbed.
    @discardableResult
    public static func scrubExpiredText(
        database: ShifuDatabase, olderThanDays days: Int = defaultDays, now: Date = Date()
    ) throws -> Int {
        let cutoff = Int64(now.timeIntervalSince1970 * 1_000) - Int64(days) * 86_400_000
        return try database.queue.write { db in
            try db.execute(
                sql: """
                UPDATE observations SET text = NULL, text_simhash = NULL
                WHERE last_seen < ? AND text IS NOT NULL
                """,
                arguments: [cutoff]
            )
            return db.changesCount
        }
    }
}
