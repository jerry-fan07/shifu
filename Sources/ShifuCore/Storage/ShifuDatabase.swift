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

        return migrator
    }
}
