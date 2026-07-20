import Foundation
import GRDB

/// Turns raw observations into ledger rows: sessionize → classify → write.
/// Rebuilds a time window idempotently, so re-runs and rule changes are safe
/// (implementation.md Phase 2 item 3).
public enum LedgerBuilder {
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
    /// ledger, and the ambiguous-retry counter. Everything else is recomputed
    /// from rules.
    private struct CarriedState {
        var category: Category?
        var topic: String?
        var confidence: Double?
        var llmLabeled: Bool
        var extracted: Bool
        var llmAttempts: Int
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
                   confidence, source, extracted, llm_attempts
            FROM activities
            WHERE ended_at > ? AND started_at < ?
              AND (source = 'llm' OR extracted = 1 OR llm_attempts > 0)
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
                llmAttempts: row["llm_attempts"]
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
        // Restore the extraction ledger and the retry counter onto the
        // span-identical row so neither the LLM classifier nor the extractor
        // re-bills a block the rebuild just recreated.
        if let prior, prior.extracted || prior.llmAttempts > 0 {
            try db.execute(
                sql: "UPDATE activities SET extracted = ?, llm_attempts = ? WHERE id = ?",
                arguments: [prior.extracted, prior.llmAttempts, sessionID])
        }
        if !observationIDs.isEmpty {
            let placeholders = databaseQuestionMarks(count: observationIDs.count)
            try db.execute(
                sql: "UPDATE observations SET session_id = ? WHERE id IN (\(placeholders))",
                arguments: StatementArguments([sessionID] + observationIDs)
            )
        }
    }

    /// Category totals (ms) for activities overlapping [from, to) — dashboard fuel.
    public static func totals(
        database: ShifuDatabase, from: Int64, to: Int64
    ) throws -> [Category: Int64] {
        let rows = try database.queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT category, SUM(MIN(ended_at, ?) - MAX(started_at, ?)) AS ms
                FROM activities WHERE ended_at > ? AND started_at < ?
                GROUP BY category
                """, arguments: [to, from, from, to])
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
