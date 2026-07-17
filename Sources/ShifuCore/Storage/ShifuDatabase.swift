import Foundation
import GRDB

/// Single local SQLite database, WAL mode, one write queue (design.md §2.2, §3.5).
public struct ShifuDatabase: Sendable {
    public let queue: DatabaseQueue

    /// Opens (creating if needed) the database at the given URL and runs migrations.
    public init(at url: URL) throws {
        var config = Configuration()
        config.qos = .utility
        config.prepareDatabase { db in
            // WAL (§3.5): kill -9 mid-write loses at most one observation.
            // synchronous=NORMAL is the recommended WAL pairing — durable
            // across app crashes, loses at most the last commit on power loss.
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        queue = try DatabaseQueue(path: url.path, configuration: config)
        try Self.migrator.migrate(queue)
    }

    /// In-memory database for tests.
    public static func inMemory() throws -> ShifuDatabase {
        try ShifuDatabase(queue: DatabaseQueue())
    }

    private init(queue: DatabaseQueue) throws {
        self.queue = queue
        try Self.migrator.migrate(queue)
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "observations") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("started_at", .integer).notNull()
                t.column("last_seen", .integer).notNull()
                t.column("app_bundle", .text).notNull()
                t.column("window_title", .text)
                t.column("url", .text)
                t.column("capture_kind", .text).notNull()
                t.column("text", .text)
                t.column("text_simhash", .integer)
                t.column("session_id", .integer)
            }
            try db.create(index: "idx_observations_started_at", on: "observations", columns: ["started_at"])
            try db.create(index: "idx_observations_session", on: "observations", columns: ["session_id"])

            // User-added exclusions, merged with the hardcoded defaults (§8).
            try db.create(table: "exclusions") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("kind", .text).notNull()   // "bundle" | "domain"
                t.column("value", .text).notNull()
                t.uniqueKey(["kind", "value"])
            }
        }

        migrator.registerMigration("v2") { db in
            // Classified activity blocks — the ledger (design.md §4.1, §9).
            try db.create(table: "activities") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("started_at", .integer).notNull()
                t.column("ended_at", .integer).notNull()
                t.column("app_bundle", .text).notNull()
                t.column("domain", .text)
                t.column("category", .text).notNull()
                t.column("topic", .text)
                t.column("confidence", .double)
                t.column("source", .text).notNull().defaults(to: "rules")
                t.column("ambiguous", .boolean).notNull().defaults(to: false)
            }
            try db.create(index: "idx_activities_started_at", on: "activities", columns: ["started_at"])

            // User classification overrides (design.md §4.2 tier 1, §9).
            try db.create(table: "rules") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("kind", .text).notNull()      // "bundle" | "domain"
                t.column("value", .text).notNull()
                t.column("category", .text).notNull()
                t.column("ambiguous", .boolean).notNull().defaults(to: false)
                t.uniqueKey(["kind", "value"])
            }
        }

        migrator.registerMigration("v3") { db in
            // Key/value settings (design.md §9): analysis backend, digest hour…
            try db.create(table: "settings") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }
            // Work Mode sessions, for adherence stats (design.md §4.4).
            try db.create(table: "work_mode_sessions") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("started_at", .integer).notNull()
                t.column("ended_at", .integer)
            }
        }

        migrator.registerMigration("v4") { db in
            // Review log for later FSRS parameter fitting (design.md §5.2, §9).
            try db.create(table: "srs_reviews") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("note_id", .text).notNull()
                t.column("reviewed_at", .integer).notNull()
                t.column("grade", .integer).notNull()
                t.column("interval_days", .double)
            }
            // High-water mark for knowledge extraction (Phase 4).
            try db.alter(table: "activities") { t in
                t.add(column: "extracted", .boolean).notNull().defaults(to: false)
            }
        }

        migrator.registerMigration("v5") { db in
            // Automation suggestions from the pattern miner (design.md §6, §9).
            try db.create(table: "suggestions") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("created_at", .integer).notNull()
                t.column("pattern_key", .text).notNull().unique()
                t.column("kind", .text).notNull()          // ngram | frequent_visit | alternation
                t.column("evidence", .text).notNull()
                t.column("occurrences", .integer).notNull()
                t.column("avg_minutes", .double).notNull()
                t.column("est_minutes_saved_weekly", .double).notNull()
                t.column("title", .text)
                t.column("suggestion", .text)              // LLM description; nil until described
                t.column("confidence", .double)
                t.column("status", .text).notNull().defaults(to: "new")
                t.column("dismissed_at_occurrences", .integer)
                t.column("snoozed_until", .integer)
            }
        }

        return migrator
    }
}

/// Typed access to the `settings` table.
public enum Settings {
    /// Analysis backend: "auto" (Foundation Models if available, else rules-only),
    /// "claude" (opt-in cloud, analyzer-only), "off" (rules-only).
    public static let analysisBackendKey = "analysis.backend"
    public static let claudeAPIKeyKey = "claude.api_key"
    public static let digestHourKey = "digest.hour"

    public static func get(_ key: String, database: ShifuDatabase) throws -> String? {
        try database.queue.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM settings WHERE key = ?", arguments: [key])
        }
    }

    public static func set(_ key: String, to value: String, database: ShifuDatabase) throws {
        try database.queue.write { db in
            try db.execute(
                sql: "INSERT INTO settings (key, value) VALUES (?, ?) "
                    + "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                arguments: [key, value]
            )
        }
    }
}
