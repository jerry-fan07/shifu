import Foundation
import GRDB
import Testing
@testable import ShifuCore

@Suite struct VaultIndexTests {
    private func tempVault() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shifu-vault-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The bundled SQLCipher must be compiled with FTS5 — the vault search
    /// index (vault-features.md §4) depends on it. A build-flag regression
    /// here should fail loudly, not surface as a runtime migration error.
    @Test func sqlcipherBuildHasFTS5() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: "CREATE VIRTUAL TABLE probe USING fts5(title, body)")
            try db.execute(
                sql: "INSERT INTO probe (title, body) VALUES (?, ?)",
                arguments: ["hello", "screen capture kit single frame"])
            let hits = try Int.fetchOne(
                db, sql: "SELECT count(*) FROM probe WHERE probe MATCH ?",
                arguments: ["capture"])
            #expect(hits == 1)
        }
    }

    // MARK: - Frontmatter groundwork

    @Test func noteRoundTripsTaskKey() throws {
        let note = Note(topic: "GRDB WAL mode", taskKey: "topic:shifu-storage",
                        body: "WAL pairs with synchronous=NORMAL.")
        let parsed = Note.parse(note.serialize())
        #expect(parsed?.taskKey == "topic:shifu-storage")
    }

    @Test func noteParseRejectsOtherKinds() throws {
        let workNote = """
        ---
        id: 01TESTWORK
        kind: work
        topic: not-really-a-topic
        ---
        Xcode — debugging
        """
        #expect(Note.parse(workNote) == nil)
        #expect(FrontMatter.parse(workNote)?.kind == .work)
    }

    @Test func frontMatterKindDefaultsToKnowledge() throws {
        let note = Note(topic: "legacy note", body: "no kind field")
        #expect(FrontMatter.parse(note.serialize())?.kind == .knowledge)
    }

    // MARK: - Write-through

    @Test func saveIndexesAndDiscardRemoves() throws {
        let database = try ShifuDatabase.inMemory()
        let vault = VaultStore(root: try tempVault(), database: database)
        defer { try? FileManager.default.removeItem(at: vault.root) }

        let note = Note(topic: "ScreenCaptureKit single frame",
                        body: "SCScreenshotManager takes one-off screenshots.")
        try vault.save(note)
        var hits = try VaultSearch.search("screenshot", database: database)
        #expect(hits.count == 1)
        #expect(hits.first?.noteID == note.id)
        #expect(hits.first?.kind == .knowledge)

        try vault.discard(note)
        hits = try VaultSearch.search("screenshot", database: database)
        #expect(hits.isEmpty)
        let rows = try database.queue.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM vault_index")
        }
        #expect(rows == 0)
    }

    // MARK: - Reconcile

    @Test func reconcileIndexesExternalAddEditAndDelete() throws {
        let database = try ShifuDatabase.inMemory()
        let root = try tempVault()
        defer { try? FileManager.default.removeItem(at: root) }

        // External add: a file Shifu never wrote (Obsidian-style edit).
        let note = Note(topic: "sqlite wal", body: "write-ahead logging basics")
        let file = root.appendingPathComponent("2026/07/\(note.id.lowercased())-sqlite-wal.md")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try note.serialize().write(to: file, atomically: true, encoding: .utf8)

        var summary = try VaultIndexer.reconcile(root: root, database: database)
        #expect(summary == VaultIndexer.Summary(indexed: 1, removed: 0, unchanged: 0))

        // Unchanged file short-circuits.
        summary = try VaultIndexer.reconcile(root: root, database: database)
        #expect(summary == VaultIndexer.Summary(indexed: 0, removed: 0, unchanged: 1))

        // External edit: content change is picked up (backdate mtime check by
        // rewriting — mtime changes, hash changes).
        var edited = note
        edited.body = "write-ahead logging with checkpoint starvation notes"
        try edited.serialize().write(to: file, atomically: true, encoding: .utf8)
        summary = try VaultIndexer.reconcile(root: root, database: database)
        #expect(summary.indexed == 1)
        let hits = try VaultSearch.search("starvation", database: database)
        #expect(hits.count == 1)

        // External delete.
        try FileManager.default.removeItem(at: file)
        summary = try VaultIndexer.reconcile(root: root, database: database)
        #expect(summary == VaultIndexer.Summary(indexed: 0, removed: 1, unchanged: 0))
        #expect(try VaultSearch.search("logging", database: database).isEmpty)
    }

    @Test func reconcileIgnoresStrayMarkdown() throws {
        let database = try ShifuDatabase.inMemory()
        let root = try tempVault()
        defer { try? FileManager.default.removeItem(at: root) }
        try "# Just a readme\nno frontmatter".write(
            to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        let summary = try VaultIndexer.reconcile(root: root, database: database)
        #expect(summary == VaultIndexer.Summary(indexed: 0, removed: 0, unchanged: 0))
    }

    @Test func contentHashIsExactAndStable() {
        #expect(VaultIndexer.contentHash("abc") == VaultIndexer.contentHash("abc"))
        #expect(VaultIndexer.contentHash("abc") != VaultIndexer.contentHash("abd"))
    }

    // MARK: - task_key resolution

    @Test func taskKeyResolvesToTaskAndProjectAtIndexTime() throws {
        let database = try ShifuDatabase.inMemory()
        let vault = VaultStore(root: try tempVault(), database: database)
        defer { try? FileManager.default.removeItem(at: vault.root) }

        let nowMs = Int64(Date().timeIntervalSince1970 * 1_000)
        let project = try TaskStore.createProject(named: "Shifu", database: database)
        let taskID: Int64 = try database.queue.write { db in
            var task = WorkTask(key: "topic:shifu-storage", name: "shifu storage",
                                projectID: project.id, createdAt: nowMs, lastActiveAt: nowMs)
            try task.insert(db)
            return task.id ?? db.lastInsertedRowID
        }

        let note = Note(topic: "GRDB migrations", taskKey: "topic:shifu-storage",
                        body: "registerMigration runs once per version.")
        try vault.save(note)

        let filtered = try VaultSearch.search(
            "migrations", taskID: taskID, database: database)
        #expect(filtered.count == 1)
        let byProject = try VaultSearch.search(
            "migrations", projectID: project.id, database: database)
        #expect(byProject.count == 1)
        let wrongTask = try VaultSearch.search(
            "migrations", taskID: taskID + 1, database: database)
        #expect(wrongTask.isEmpty)
    }

    // MARK: - Query sanitization

    @Test func searchNeverThrowsOnMalformedQueries() throws {
        let database = try ShifuDatabase.inMemory()
        for query in ["\"unbalanced", "AND OR NOT", "a* b(", "  ", "", "col:val", "\"\"*"] {
            let hits = try VaultSearch.search(query, database: database)
            #expect(hits.isEmpty)
        }
    }

    @Test func ftsQueryQuotesAndPrefixMatches() {
        #expect(VaultSearch.ftsQuery(from: "sqlite WAL") == "\"sqlite\" \"wal\"*")
        #expect(VaultSearch.ftsQuery(from: "don't panic") == "\"don\" \"t\" \"panic\"*")
        #expect(VaultSearch.ftsQuery(from: "!!!") == nil)
    }

    @Test func prefixSearchMatchesPartialLastToken() throws {
        let database = try ShifuDatabase.inMemory()
        let vault = VaultStore(root: try tempVault(), database: database)
        defer { try? FileManager.default.removeItem(at: vault.root) }
        try vault.save(Note(topic: "screencapturekit", body: "single frame capture"))

        let hits = try VaultSearch.search("screencap", database: database)
        #expect(hits.count == 1)
    }
}
