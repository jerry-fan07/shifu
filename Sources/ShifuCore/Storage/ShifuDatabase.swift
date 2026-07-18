import Foundation
import GRDB

/// Single local SQLite database, WAL mode, one write queue (design.md §2.2, §3.5).
public struct ShifuDatabase: Sendable {
    public let queue: DatabaseQueue

    public enum OpenError: Error, CustomStringConvertible {
        /// The file is SQLCipher-encrypted but no key is available. This is a
        /// configuration problem, not corruption — never rotate on it.
        case encryptedButNoKey

        public var description: String {
            "database is encrypted but no key was found (Keychain item missing "
                + "and \(DatabaseKey.envVar) unset)"
        }
    }

    /// Opens (creating if needed) the database at the given URL and runs
    /// migrations. Pass a passphrase to open/create SQLCipher-encrypted (§8).
    public init(at url: URL, passphrase: String? = nil) throws {
        var config = Configuration()
        config.qos = .utility
        config.prepareDatabase { db in
            // The key must be applied before any other statement touches the file.
            if let passphrase {
                try db.usePassphrase(passphrase)
            }
            // WAL (§3.5): kill -9 mid-write loses at most one observation.
            // synchronous=NORMAL is the recommended WAL pairing — durable
            // across app crashes, loses at most the last commit on power loss.
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        queue = try DatabaseQueue(path: url.path, configuration: config)
        try Self.migrator.migrate(queue)
    }

    /// True when the file exists and does not start with the plaintext SQLite
    /// magic — i.e. it is SQLCipher-encrypted (or garbage).
    public static func isEncrypted(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let header = try? handle.read(upToCount: 16) else { return false }
        return header != Data("SQLite format 3\0".utf8)
    }

    /// The standard opener: resolves the key (env override or Keychain) and
    /// picks plaintext vs encrypted based on the file and key state.
    ///
    /// - plaintext file → open plaintext (even if a key exists; migration to
    ///   encrypted is explicit, via `shifu encrypt`)
    /// - encrypted file → key required, else `OpenError.encryptedButNoKey`
    /// - no file → encrypted when a key exists, plaintext otherwise
    public static func open(at url: URL = ShifuPaths.database) throws -> ShifuDatabase {
        let key = try DatabaseKey.existing()
        if FileManager.default.fileExists(atPath: url.path) {
            if isEncrypted(at: url) {
                guard let key else { throw OpenError.encryptedButNoKey }
                return try ShifuDatabase(at: url, passphrase: key)
            }
            return try ShifuDatabase(at: url)
        }
        return try ShifuDatabase(at: url, passphrase: key)
    }

    /// In-memory database for tests.
    public static func inMemory() throws -> ShifuDatabase {
        try ShifuDatabase(queue: DatabaseQueue())
    }

    /// Opens the database; on corruption, rotates the damaged files aside and
    /// starts fresh rather than silently dropping capture (design.md §10).
    /// Returns the rotated-aside URL when rotation happened.
    ///
    /// A Keychain *error* (locked, access denied) is rethrown — the key may
    /// exist, so rotating could orphan good data. A confirmed missing key
    /// rotates: the file is unreadable forever either way, and rotation
    /// renames rather than deletes.
    public static func openRotatingOnCorruption(at url: URL) throws -> (ShifuDatabase, rotatedTo: URL?) {
        do {
            return (try open(at: url), nil)
        } catch let error as DatabaseKey.KeyError {
            throw error
        } catch {
            let stamp = Int(Date().timeIntervalSince1970)
            let aside = url.deletingLastPathComponent()
                .appendingPathComponent("\(url.lastPathComponent).corrupt-\(stamp)")
            for suffix in ["", "-wal", "-shm"] {
                let source = URL(fileURLWithPath: url.path + suffix)
                if FileManager.default.fileExists(atPath: source.path) {
                    try? FileManager.default.moveItem(
                        at: source, to: URL(fileURLWithPath: aside.path + suffix))
                }
            }
            return (try open(at: url), aside)
        }
    }

    private init(queue: DatabaseQueue) throws {
        self.queue = queue
        try Self.migrator.migrate(queue)
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "observations") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("started_at", .integer).notNull()
                table.column("last_seen", .integer).notNull()
                table.column("app_bundle", .text).notNull()
                table.column("window_title", .text)
                table.column("url", .text)
                table.column("capture_kind", .text).notNull()
                table.column("text", .text)
                table.column("text_simhash", .integer)
                table.column("session_id", .integer)
            }
            try db.create(index: "idx_observations_started_at", on: "observations", columns: ["started_at"])
            try db.create(index: "idx_observations_session", on: "observations", columns: ["session_id"])

            // User-added exclusions, merged with the hardcoded defaults (§8).
            try db.create(table: "exclusions") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("kind", .text).notNull()   // "bundle" | "domain"
                table.column("value", .text).notNull()
                table.uniqueKey(["kind", "value"])
            }
        }

        migrator.registerMigration("v2") { db in
            // Classified activity blocks — the ledger (design.md §4.1, §9).
            try db.create(table: "activities") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("started_at", .integer).notNull()
                table.column("ended_at", .integer).notNull()
                table.column("app_bundle", .text).notNull()
                table.column("domain", .text)
                table.column("category", .text).notNull()
                table.column("topic", .text)
                table.column("confidence", .double)
                table.column("source", .text).notNull().defaults(to: "rules")
                table.column("ambiguous", .boolean).notNull().defaults(to: false)
            }
            try db.create(index: "idx_activities_started_at", on: "activities", columns: ["started_at"])

            // User classification overrides (design.md §4.2 tier 1, §9).
            try db.create(table: "rules") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("kind", .text).notNull()      // "bundle" | "domain"
                table.column("value", .text).notNull()
                table.column("category", .text).notNull()
                table.column("ambiguous", .boolean).notNull().defaults(to: false)
                table.uniqueKey(["kind", "value"])
            }
        }

        migrator.registerMigration("v3") { db in
            // Key/value settings (design.md §9): analysis backend, digest hour…
            try db.create(table: "settings") { table in
                table.primaryKey("key", .text)
                table.column("value", .text).notNull()
            }
            // Work Mode sessions, for adherence stats (design.md §4.4).
            try db.create(table: "work_mode_sessions") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("started_at", .integer).notNull()
                table.column("ended_at", .integer)
            }
        }

        migrator.registerMigration("v4") { db in
            // Review log for later FSRS parameter fitting (design.md §5.2, §9).
            try db.create(table: "srs_reviews") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("note_id", .text).notNull()
                table.column("reviewed_at", .integer).notNull()
                table.column("grade", .integer).notNull()
                table.column("interval_days", .double)
            }
            // High-water mark for knowledge extraction (Phase 4).
            try db.alter(table: "activities") { table in
                table.add(column: "extracted", .boolean).notNull().defaults(to: false)
            }
        }

        migrator.registerMigration("v5") { db in
            // Automation suggestions from the pattern miner (design.md §6, §9).
            try db.create(table: "suggestions") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("created_at", .integer).notNull()
                table.column("pattern_key", .text).notNull().unique()
                table.column("kind", .text).notNull()          // ngram | frequent_visit | alternation
                table.column("evidence", .text).notNull()
                table.column("occurrences", .integer).notNull()
                table.column("avg_minutes", .double).notNull()
                table.column("est_minutes_saved_weekly", .double).notNull()
                table.column("title", .text)
                table.column("suggestion", .text)              // LLM description; nil until described
                table.column("confidence", .double)
                table.column("status", .text).notNull().defaults(to: "new")
                table.column("dismissed_at_occurrences", .integer)
                table.column("snoozed_until", .integer)
            }
        }

        migrator.registerMigration("v6") { db in
            // Tasks & projects (design.md §5.3): activities group into tasks,
            // tasks group into user-created projects, per-day work logs.
            try db.create(table: "projects") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("name", .text).notNull().unique()
                table.column("created_at", .integer).notNull()
            }
            try db.create(table: "tasks") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("key", .text).notNull().unique()   // TaskGrouper.key
                table.column("name", .text).notNull()           // user-renameable
                table.column("project_id", .integer).references("projects", onDelete: .setNull)
                table.column("created_at", .integer).notNull()
                table.column("last_active_at", .integer).notNull()
            }
            try db.create(index: "idx_tasks_last_active", on: "tasks", columns: ["last_active_at"])
            try db.create(table: "task_logs") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("task_id", .integer).notNull().references("tasks", onDelete: .cascade)
                table.column("day_start", .integer).notNull()   // local-midnight unix ms
                table.column("duration_ms", .integer).notNull()
                table.column("summary", .text).notNull()
                table.uniqueKey(["task_id", "day_start"])
            }
            try db.alter(table: "activities") { table in
                table.add(column: "task_id", .integer)
            }
            try db.create(index: "idx_activities_task", on: "activities", columns: ["task_id"])
        }

        migrator.registerMigration("v7") { db in
            // Vault search index (vault-features.md §4). The Markdown tree is
            // the source of truth; these tables are disposable and fully
            // rebuildable from the files (`shifu vault reindex`).
            try db.create(table: "vault_index") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("note_id", .text).notNull().unique()
                table.column("path", .text).notNull()       // relative to vault root
                table.column("kind", .text).notNull()       // FrontMatter.Kind
                table.column("task_id", .integer)
                table.column("project_id", .integer)
                table.column("captured", .integer)          // unix ms
                table.column("content_hash", .integer).notNull()
                table.column("mtime", .integer).notNull()   // unix ms, for reconcile
            }
            try db.create(index: "idx_vault_index_kind", on: "vault_index", columns: ["kind"])
            try db.create(index: "idx_vault_index_task", on: "vault_index", columns: ["task_id"])
            try db.create(index: "idx_vault_index_project", on: "vault_index", columns: ["project_id"])
            // Full-text side, rowid tied to vault_index.id. Plain FTS5 (not
            // external-content): the duplicated text is disposable by design.
            try db.execute(sql: "CREATE VIRTUAL TABLE vault_fts USING fts5(title, body)")
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
