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

    /// Rebuilds all activities overlapping [from, to). Returns what was done.
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

        var activities: [(Activity, [Int64])] = blocks.map { block in
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
            // Replace anything overlapping the window (spanning blocks included).
            try db.execute(
                sql: "DELETE FROM activities WHERE ended_at > ? AND started_at < ?",
                arguments: [from, to]
            )
            for index in activities.indices {
                try activities[index].0.insert(db)
                guard let sessionID = activities[index].0.id else { continue }
                let ids = activities[index].1
                if !ids.isEmpty {
                    let placeholders = databaseQuestionMarks(count: ids.count)
                    try db.execute(
                        sql: "UPDATE observations SET session_id = ? WHERE id IN (\(placeholders))",
                        arguments: StatementArguments([sessionID] + ids)
                    )
                }
            }
        }
        return Summary(blocksWritten: activities.count, observationsProcessed: observations.count)
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
