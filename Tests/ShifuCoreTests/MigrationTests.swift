import Foundation
import GRDB
import Testing
@testable import ShifuCore

/// The schema (ARCHITECTURE.md §4, §7). Migrations are append-only and have
/// run on real machines, so the properties worth pinning are the ones that
/// break silently: an edited old migration, a migration that only works on a
/// fresh database, and a table whose hot query has no index behind it.
@Suite struct MigrationTests {
    private static let migrationNames = ShifuDatabase.migrator.migrations

    @Test func everyMigrationRunsOnAFreshDatabase() throws {
        let database = try ShifuDatabase.inMemory()
        let applied = try database.queue.read { try ShifuDatabase.migrator.appliedMigrations($0) }
        #expect(applied == Self.migrationNames)
    }

    /// "v<n>" or "v<n>-<name>". The optional name is what keeps two branches
    /// that both pick the next number from silently skipping each other's
    /// migration — GRDB keys `grdb_migrations` on the whole string, so "v19"
    /// and "v19-llm-usage" coexist while two bare "v19"s do not. The number
    /// still has to be the next one, so the sequence stays readable.
    @Test func migrationsAreNamedInVersionOrderWithNoGapsOrRepeats() throws {
        let versions = Self.migrationNames.map { name -> Int in
            Int(name.dropFirst().prefix { $0.isNumber }) ?? -1
        }
        #expect(Self.migrationNames.allSatisfy { $0.hasPrefix("v") })
        #expect(versions == Array(1...versions.count))
    }

    /// Migrating one version at a time has to reach the same schema as
    /// migrating in one go — the difference is what a "works on my fresh DB"
    /// migration looks like from a real upgrade.
    @Test func steppingThroughVersionsLandsOnTheSameSchemaAsMigratingAtOnce() throws {
        let stepwise = try DatabaseQueue()
        for name in Self.migrationNames {
            try ShifuDatabase.migrator.migrate(stepwise, upTo: name)
        }

        #expect(try Self.schema(of: stepwise)
            == Self.schema(of: ShifuDatabase.inMemory().queue))
    }

    @Test func rerunningTheMigratorChangesNothing() throws {
        let database = try ShifuDatabase.inMemory()
        let before = try Self.schema(of: database.queue)
        try ShifuDatabase.migrator.migrate(database.queue)
        #expect(try Self.schema(of: database.queue) == before)
    }

    /// Projects were removed in v14 (ARCHITECTURE.md §4). A leftover column or
    /// table means a later migration is still carrying dead weight.
    @Test func projectsAreGoneFromEverySurvivingTable() throws {
        let database = try ShifuDatabase.inMemory()
        try database.queue.read { db in
            let hasProjects = try db.tableExists("projects")
            let hasSuggestions = try db.tableExists("project_suggestions")
            let taskColumns = try db.columns(in: "tasks").map(\.name)
            let indexColumns = try db.columns(in: "vault_index").map(\.name)
            #expect(!hasProjects)
            #expect(!hasSuggestions)
            #expect(!taskColumns.contains("project_id"))
            #expect(!indexColumns.contains("project_id"))
        }
    }

    @Test func theTablesTheArchitectureDocumentsAllExist() throws {
        let expected = [
            "observations", "activities", "tasks", "task_logs", "themes",
            "theme_proposals", "theme_proposal_blocks", "theme_suggestions",
            "rules", "exclusions", "settings", "suggestions", "srs_reviews",
            "focus_mode_sessions", "task_merge_suggestions",
            "vault_index", "vault_fts", "vault_vectors"
        ]
        let database = try ShifuDatabase.inMemory()
        try database.queue.read { db in
            for table in expected {
                let exists = try db.tableExists(table)
                #expect(exists, "\(table) is missing")
            }
        }
    }

    /// v25 renamed Focus Mode's two stored names. Both hold data the user
    /// owns and nothing derives — adherence history, and a list they typed
    /// themselves — so the upgrade has to carry them, not start them over.
    /// A fresh database says nothing about that; only an upgrade from a
    /// database that already has rows under the old names does.
    @Test func theFocusModeRenameCarriesSessionsAndTheSiteListOver() throws {
        let queue = try DatabaseQueue()
        try ShifuDatabase.migrator.migrate(queue, upTo: "v24-vault-library")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO work_mode_sessions (started_at, ended_at) VALUES (100, 200)
                """)
            try db.execute(sql: """
                INSERT INTO work_mode_sessions (started_at) VALUES (300)
                """)
            try db.execute(sql: """
                INSERT INTO settings (key, value)
                VALUES ('workmode.distracting_domains', 'reddit.com,news.test')
                """)
        }

        try ShifuDatabase.migrator.migrate(queue)

        try queue.read { db in
            let sessions = try Row.fetchAll(
                db, sql: "SELECT started_at, ended_at FROM focus_mode_sessions ORDER BY started_at")
            #expect(sessions.count == 2)
            #expect(sessions.map { $0["started_at"] as Int64? } == [100, 300])
            // The open session is still open — a rename must not close it.
            #expect(sessions[1]["ended_at"] as Int64? == nil)

            let sites = try String.fetchOne(
                db, sql: "SELECT value FROM settings WHERE key = 'focusmode.distracting_domains'")
            #expect(sites == "reddit.com,news.test")

            // And the old names are gone rather than left as a second copy.
            #expect(try !db.tableExists("work_mode_sessions"))
            let stale = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM settings WHERE key LIKE 'workmode.%'")
            #expect(stale == 0)
        }
    }

    /// Uniqueness is what keeps dismissals dismissed and stops the queues
    /// piling up duplicates (ARCHITECTURE.md §4).
    @Test func theKeysThatMakeDismissalsStickAreUnique() throws {
        let database = try ShifuDatabase.inMemory()
        try database.queue.write { db in
            try db.execute(sql: """
                INSERT INTO themes (key, name, created_at, last_active_at)
                VALUES ('thm:x', 'X', 0, 0)
                """)
            #expect(throws: (any Error).self) {
                try db.execute(sql: """
                    INSERT INTO themes (key, name, created_at, last_active_at)
                    VALUES ('thm:x', 'Other', 0, 0)
                    """)
            }
        }
        try Self.expectUniqueViolation(
            database,
            insert: "INSERT INTO theme_proposals (key, name, created_at) VALUES ('thm:p', 'P', 0)")
        try Self.expectUniqueViolation(
            database,
            insert: "INSERT INTO tasks (key, name, created_at, last_active_at) "
                + "VALUES ('topic:x', 'X', 0, 0)")
        try Self.expectUniqueViolation(
            database,
            insert: "INSERT INTO exclusions (kind, value) VALUES ('domain', 'bank.test')")
    }

    @Test func taskLogsAreUniquePerTaskAndDay() throws {
        let database = try ShifuDatabase.inMemory()
        try database.queue.write { db in
            try db.execute(sql: """
                INSERT INTO tasks (id, key, name, created_at, last_active_at)
                VALUES (1, 'topic:x', 'X', 0, 0)
                """)
            try db.execute(sql: """
                INSERT INTO task_logs (task_id, day_start, duration_ms, summary)
                VALUES (1, 0, 10, 's')
                """)
            #expect(throws: (any Error).self) {
                try db.execute(sql: """
                    INSERT INTO task_logs (task_id, day_start, duration_ms, summary)
                    VALUES (1, 0, 20, 's')
                    """)
            }
        }
    }

    /// Deleting a task takes its day logs with it; deleting a proposal takes
    /// the blocks behind it. Neither should leave orphans the UI can read.
    @Test func cascadesRemoveTheRowsThatCannotOutliveTheirParent() throws {
        let database = try ShifuDatabase.inMemory()
        try database.queue.write { db in
            try db.execute(sql: """
                INSERT INTO tasks (id, key, name, created_at, last_active_at)
                VALUES (1, 'topic:x', 'X', 0, 0)
                """)
            try db.execute(sql: """
                INSERT INTO task_logs (task_id, day_start, duration_ms, summary)
                VALUES (1, 0, 10, 's')
                """)
            try db.execute(sql: "DELETE FROM tasks WHERE id = 1")
            let orphanLogs = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM task_logs")
            #expect(orphanLogs == 0)

            try db.execute(sql: """
                INSERT INTO theme_proposals (id, key, name, created_at)
                VALUES (7, 'thm:p', 'P', 0)
                """)
            try db.execute(sql: """
                INSERT INTO theme_proposal_blocks (proposal_id, activity_id) VALUES (7, 99)
                """)
            try db.execute(sql: "DELETE FROM theme_proposals WHERE id = 7")
            let orphanBlocks = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM theme_proposal_blocks")
            #expect(orphanBlocks == 0)
        }
    }

    /// Every query in the hot path filters or joins on these; without the
    /// index a dogfood-sized ledger turns each one into a table scan.
    @Test func theColumnsTheHotQueriesFilterOnAreIndexed() throws {
        let database = try ShifuDatabase.inMemory()
        let indexed: [(String, String)] = [
            ("observations", "started_at"), ("observations", "session_id"),
            ("activities", "started_at"), ("activities", "task_id"),
            ("activities", "theme_key"), ("tasks", "last_active_at"),
            ("themes", "last_active_at"), ("vault_index", "kind"), ("vault_index", "task_id")
        ]
        try database.queue.read { db in
            for (table, column) in indexed {
                let indexes = try db.indexes(on: table)
                #expect(indexes.contains { $0.columns.first == column },
                        "\(table).\(column) has no index")
            }
        }
    }

    /// Timestamps are unix milliseconds as Int64 end to end (ARCHITECTURE.md
    /// §8); a column typed TEXT or REAL would silently break every comparison.
    @Test func everyTimestampColumnIsAnInteger() throws {
        let database = try ShifuDatabase.inMemory()
        let timeColumns = ["started_at", "ended_at", "last_seen", "created_at",
                           "last_active_at", "day_start", "reviewed_at", "captured",
                           "mtime", "snoozed_until"]
        try database.queue.read { db in
            for table in ["observations", "activities", "tasks", "task_logs", "themes",
                          "srs_reviews", "suggestions", "vault_index"] {
                for column in try db.columns(in: table) where timeColumns.contains(column.name) {
                    #expect(column.type.uppercased() == "INTEGER",
                            "\(table).\(column.name) is \(column.type)")
                }
            }
        }
    }

    // MARK: - Helpers

    private static func schema(of queue: DatabaseQueue) throws -> [String] {
        try queue.read { db in
            try String.fetchAll(db, sql: """
                SELECT type || ' ' || name || ' ' || COALESCE(sql, '')
                FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'
                ORDER BY type, name
                """)
        }
    }

    private static func expectUniqueViolation(
        _ database: ShifuDatabase, insert sql: String
    ) throws {
        try database.queue.write { db in
            try db.execute(sql: sql)
            #expect(throws: (any Error).self) { try db.execute(sql: sql) }
        }
    }
}
