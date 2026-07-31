import Foundation
import GRDB
import Testing
@testable import ShifuCore

/// Keyword → fixed vector; unknown text embeds to nil.
private struct StubEmbedder: Embedder {
    var vectors: [String: [Float]]

    func embed(_ text: String) -> [Float]? {
        for (key, vector) in vectors where text.lowercased().contains(key) {
            return EmbedMath.normalize(vector)
        }
        return nil
    }
}

private final class CountingBackend: LLMBackend, @unchecked Sendable {
    let name = "counting"
    private let lock = NSLock()
    private var callCount = 0

    var calls: Int { lock.withLock { callCount } }

    func complete(prompt: String, maxTokens: Int) async throws -> String {
        lock.withLock { callCount += 1 }
        return "The effort is moving: daemon fixes landed and docs were read."
    }
}

@Suite struct VaultSemanticTests {
    private let calendar = Calendar.current
    private var day1: Date { calendar.startOfDay(for: Date(timeIntervalSince1970: 1_760_000_000)) }
    private var day2: Date { calendar.date(byAdding: .day, value: 1, to: day1)! }

    private func ms(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1_000) }

    private func makeVault(_ database: ShifuDatabase) throws -> VaultStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shifu-semantic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return VaultStore(root: root, database: database)
    }

    private func vectorCount(_ database: ShifuDatabase) throws -> Int {
        try database.queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM vault_vectors")!
        }
    }

    // MARK: - Vector lifecycle (§4)

    @Test func vectorsFollowTheIndexLifecycle() throws {
        let database = try ShifuDatabase.inMemory()
        let vault = try makeVault(database)
        let embedder = StubEmbedder(vectors: ["screenshot": [1, 0], "wal": [0, 1]])

        // Write-through has no embedder: indexed, but no vector yet.
        let note = Note(topic: "screenshot capture", body: "One frame, no stream.")
        try vault.save(note)
        #expect(try vectorCount(database) == 0)

        // Analyzer reconcile backfills the missing vector.
        try VaultIndexer.reconcile(root: vault.root, database: database, embedder: embedder)
        #expect(try vectorCount(database) == 1)

        // Discard removes index row and vector together.
        try vault.discard(note)
        #expect(try vectorCount(database) == 0)
    }

    /// An edit picked up by an embedder-less reconcile — the app's launch pass
    /// (`LedgerStore.syncLibrary`), or write-through — must not leave the old
    /// vector behind. That pass refreshes mtime and content hash, so the
    /// analyzer's next reconcile short-circuits and never re-reads the file;
    /// a surviving vector would describe the note's previous text for good,
    /// and `backfillVectors` only fills vectors that are *missing*.
    @Test func anEmbedderlessReindexDropsTheVectorItCannotRefresh() throws {
        let database = try ShifuDatabase.inMemory()
        let vault = try makeVault(database)
        let embedder = StubEmbedder(vectors: ["screenshot": [1, 0], "wal": [0, 1]])

        let note = Note(topic: "screenshot capture", body: "One frame, no stream.")
        let file = try vault.save(note)
        try VaultIndexer.reconcile(root: vault.root, database: database, embedder: embedder)
        #expect(try #require(try storedVector(note.id, database)) == [1, 0])

        // The same note, rewritten in Obsidian to be about something else.
        var edited = note
        edited.topic = "wal journal"
        edited.body = "Write-ahead journal notes."
        try edited.serialize().write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: file.path)

        // The app gets there first, without an embedder.
        try VaultIndexer.reconcile(root: vault.root, database: database)
        #expect(try vectorCount(database) == 0)

        // So the analyzer's backfill still owns the note, and re-embeds it
        // from the text it now holds rather than the text it used to.
        try VaultIndexer.reconcile(root: vault.root, database: database, embedder: embedder)
        #expect(try #require(try storedVector(note.id, database)) == [0, 1])
    }

    private func storedVector(_ noteID: String, _ database: ShifuDatabase) throws -> [Float]? {
        try database.queue.read { db in
            try Data.fetchOne(
                db, sql: "SELECT embedding FROM vault_vectors WHERE note_id = ?",
                arguments: [noteID])
        }.map(EmbedMath.vector(from:))
    }

    // MARK: - Hybrid search (§4)

    @Test func hybridFindsParaphraseThatBM25Misses() throws {
        let database = try ShifuDatabase.inMemory()
        let vault = try makeVault(database)
        let target = Note(topic: "sck capture", body: "Single screenshot without a stream.")
        let decoyA = Note(topic: "sqlite wal", body: "Write-ahead journal notes.")
        let decoyB = Note(topic: "fsrs tuning", body: "Review scheduling parameters.")
        for note in [target, decoyA, decoyB] { try vault.save(note) }

        // Paraphrase and target embed alike; decoys sit orthogonal.
        let embedder = StubEmbedder(vectors: [
            "one frame grab": [1, 0, 0],
            "screenshot": [0.98, 0.2, 0],
            "wal": [0, 1, 0],
            "fsrs": [0, 0, 1]
        ])
        try VaultIndexer.reconcile(root: vault.root, database: database, embedder: embedder)

        // No shared tokens with the target: bm25 alone comes up empty.
        let exact = try VaultSearch.search("one frame grab", database: database)
        #expect(!exact.contains { $0.noteID == target.id })

        let hybrid = try VaultSearch.search("one frame grab", database: database,
                                            embedder: embedder)
        #expect(hybrid.first?.noteID == target.id)
    }

    @Test func nilEmbedderMatchesExactSearch() throws {
        let database = try ShifuDatabase.inMemory()
        let vault = try makeVault(database)
        for serial in 0..<5 {
            try vault.save(Note(topic: "daemon note \(serial)",
                                body: "capture daemon observation \(serial)"))
        }
        let embedder = StubEmbedder(vectors: ["daemon": [1, 0]])
        try VaultIndexer.reconcile(root: vault.root, database: database, embedder: embedder)

        let plain = try VaultSearch.search("capture daemon", database: database)
        let nilEmbedder = try VaultSearch.search("capture daemon", database: database,
                                                 embedder: nil)
        #expect(plain.map(\.noteID) == nilEmbedder.map(\.noteID))
        #expect(!plain.isEmpty)
    }

    /// The same two blocks, filed under a theme instead — the shape the theme
    /// suggester learns a centroid from.
    private func seedTheme(_ database: ShifuDatabase) throws -> String {
        try database.queue.write { db in
            for (topic, hour) in [("capture daemon", 9.0), ("capture daemon", 14.0)] {
                var activity = Activity(
                    startedAt: ms(day1.addingTimeInterval(hour * 3_600)),
                    endedAt: ms(day1.addingTimeInterval(hour * 3_600)) + 3_600_000,
                    appBundle: "com.apple.dt.Xcode", category: .work, topic: topic)
                try activity.insert(db)
            }
        }
        try TaskGrouper.run(database: database, from: ms(day1), to: ms(day2))
        let key = try #require(try ThemeStore.create(named: "Shifu development",
                                                     database: database))
        let taskID = try database.queue.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM tasks LIMIT 1")!
        }
        try TaskStore.assignTheme(taskID: taskID, themeKey: key, database: database)
        return key
    }

    // MARK: - Task → theme suggestions (§5.3)

    @Test func themeSuggestionAcceptAndDismissPersist() throws {
        let database = try ShifuDatabase.inMemory()
        let themeKey = try seedTheme(database)
        // A second, unthemed task semantically near the theme.
        try database.queue.write { db in
            var activity = Activity(
                startedAt: ms(day1.addingTimeInterval(16 * 3_600)),
                endedAt: ms(day1.addingTimeInterval(16 * 3_600)) + 3_600_000,
                appBundle: "com.apple.dt.Xcode", category: .work, topic: "capture daemon leak")
            try activity.insert(db)
        }
        try TaskGrouper.run(database: database, from: ms(day1), to: ms(day2))
        try TaskMerges.writeSignatures(database: database, from: ms(day1), to: ms(day2))

        let embedder = StubEmbedder(vectors: ["capture daemon": [1, 0]])
        #expect(try TaskMerges.suggestThemes(
            database: database, embedder: embedder, now: day2) == 1)
        let pending = try TaskMerges.pendingThemes(database: database)
        #expect(pending.count == 1)
        #expect(pending[0].themeName == "Shifu development")
        #expect(pending[0].taskName == "capture daemon leak")

        // Dismiss is remembered (unique task_id).
        try TaskMerges.dismissTheme(suggestionID: pending[0].id, database: database)
        #expect(try TaskMerges.suggestThemes(
            database: database, embedder: embedder, now: day2) == 0)
        #expect(try TaskMerges.pendingThemes(database: database).isEmpty)

        // Reset to test accept: flip the row back to new.
        try database.queue.write { db in
            try db.execute(sql: "UPDATE theme_suggestions SET status = 'new'")
        }
        let reopened = try TaskMerges.pendingThemes(database: database)[0]
        try TaskMerges.acceptTheme(reopened, database: database)

        // Accepting files the task's blocks, which is what the list reads.
        let filed = try TaskStore.recentTasks(
            database: database, filter: .init(themeScope: .theme(key: themeKey)))
        #expect(filed.map(\.task.name).sorted() == ["capture daemon", "capture daemon leak"])
        // Accepted, so it stops being offered.
        #expect(try TaskMerges.pendingThemes(database: database).isEmpty)
    }
}
