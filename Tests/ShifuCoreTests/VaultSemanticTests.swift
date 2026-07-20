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

    // MARK: - Project notes (§2.2)

    private func seedProject(_ database: ShifuDatabase) throws -> Int64 {
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
        let project = try TaskStore.createProject(named: "Shifu", database: database)
        let taskID = try database.queue.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM tasks LIMIT 1")!
        }
        try TaskStore.assign(taskID: taskID, projectID: project.id, database: database)
        return project.id!
    }

    @Test func projectNoteIsDeterministicAndHashGated() async throws {
        let database = try ShifuDatabase.inMemory()
        let vault = try makeVault(database)
        let projectID = try seedProject(database)
        let backend = CountingBackend()

        _ = try await ProjectNoteCompiler.run(database: database, vault: vault,
                                              backend: backend, now: day2)
        #expect(backend.calls == 1)
        let url = vault.projectNoteURL(slug: "shifu")
        let first = try String(contentsOf: url, encoding: .utf8)
        #expect(first.contains("## Tasks"))
        #expect(first.contains("## Status"))
        #expect(first.contains("h all time"))

        // Unchanged logs ⇒ status carried, zero further LLM calls, same bytes.
        _ = try await ProjectNoteCompiler.run(database: database, vault: vault,
                                              backend: backend, now: day2)
        #expect(backend.calls == 1)
        #expect(try String(contentsOf: url, encoding: .utf8) == first)

        // Deterministic compile keeps the carried status too.
        try ProjectNoteCompiler.compileDeterministic(
            projectID: projectID, database: database, vault: vault, now: day2)
        #expect(try String(contentsOf: url, encoding: .utf8) == first)
    }

    // MARK: - Task → project suggestions (§5.3)

    @Test func projectSuggestionAcceptAndDismissPersist() throws {
        let database = try ShifuDatabase.inMemory()
        let vault = try makeVault(database)
        let projectID = try seedProject(database)
        // A second, unassigned task semantically near the project.
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
        #expect(try TaskMerges.suggestProjects(
            database: database, embedder: embedder, now: day2) == 1)
        let pending = try TaskMerges.pendingProjects(database: database)
        #expect(pending.count == 1)
        #expect(pending[0].projectName == "Shifu")
        #expect(pending[0].taskName == "capture daemon leak")

        // Dismiss is remembered (unique task_id).
        try TaskMerges.dismissProject(suggestionID: pending[0].id, database: database)
        #expect(try TaskMerges.suggestProjects(
            database: database, embedder: embedder, now: day2) == 0)
        #expect(try TaskMerges.pendingProjects(database: database).isEmpty)

        // Reset to test accept: flip the row back to new.
        try database.queue.write { db in
            try db.execute(sql: "UPDATE project_suggestions SET status = 'new'")
        }
        let reopened = try TaskMerges.pendingProjects(database: database)[0]
        try TaskMerges.acceptProject(reopened, database: database, vault: vault)

        let assigned = try database.queue.read { db in
            try Int64.fetchOne(db, sql: """
                SELECT project_id FROM tasks WHERE key = 'topic:capture-daemon-leak'
                """)
        }
        #expect(assigned == projectID)
        // Accept recompiled the project note with both tasks listed.
        let text = try String(contentsOf: vault.projectNoteURL(slug: "shifu"), encoding: .utf8)
        #expect(text.contains("capture daemon leak"))
    }
}
