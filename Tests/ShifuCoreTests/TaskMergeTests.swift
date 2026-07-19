import Foundation
import GRDB
import Testing
@testable import ShifuCore

/// Deterministic embedder: any signature containing a key maps to that fixed
/// vector; everything else is nil (which must degrade to a no-op, §5).
private struct StubEmbedder: Embedder {
    var vectors: [String: [Float]]

    func embed(_ text: String) -> [Float]? {
        for (key, vector) in vectors where text.contains(key) {
            return EmbedMath.normalize(vector)
        }
        return nil
    }
}

@Suite struct EmbedMathTests {
    @Test func cosineAndCentroidBehave() {
        let unitX: [Float] = [1, 0]
        let unitY: [Float] = [0, 1]
        #expect(EmbedMath.cosine(unitX, unitX) == 1)
        #expect(EmbedMath.cosine(unitX, unitY) == 0)
        #expect(EmbedMath.normalize([0, 0]) == nil)
        #expect(EmbedMath.centroid([]) == nil)
        let mid = EmbedMath.centroid([unitX, unitY])!
        #expect(abs(EmbedMath.cosine(mid, unitX) - EmbedMath.cosine(mid, unitY)) < 0.0001)
    }
}

@Suite struct TaskMergeTests {
    private let calendar = Calendar.current
    private var day1: Date { calendar.startOfDay(for: Date(timeIntervalSince1970: 1_760_000_000)) }
    private var day2: Date { calendar.date(byAdding: .day, value: 1, to: day1)! }

    private func ms(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1_000) }

    private func makeVault(_ database: ShifuDatabase) throws -> VaultStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shifu-merges-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return VaultStore(root: root, database: database)
    }

    /// Two tasks over the same source that should attract a suggestion, plus
    /// an unrelated third task.
    private func seed(_ database: ShifuDatabase, sharedSource: Bool = true) throws {
        try database.queue.write { db in
            for (topic, app, offset) in [
                ("capture daemon", "com.apple.dt.Xcode", 9.0),
                ("capture daemon leak", sharedSource ? "com.apple.dt.Xcode" : "com.apple.Terminal", 11.0),
                ("cooking pasta", "com.apple.Safari", 14.0)
            ] {
                var activity = Activity(
                    startedAt: ms(day1.addingTimeInterval(offset * 3_600)),
                    endedAt: ms(day1.addingTimeInterval(offset * 3_600)) + 3_600_000,
                    appBundle: app, category: .work, topic: topic)
                try activity.insert(db)
            }
        }
        try TaskGrouper.run(database: database, from: ms(day1), to: ms(day2))
        try TaskMerges.writeSignatures(database: database, from: ms(day1), to: ms(day2))
    }

    private var stub: StubEmbedder {
        StubEmbedder(vectors: [
            "capture daemon": [1, 0, 0],       // both daemon topics match this
            "cooking": [0, 1, 0]
        ])
    }

    @Test func suggestsHighCosinePairsWithSharedSources() throws {
        let database = try ShifuDatabase.inMemory()
        try seed(database)
        let count = try TaskMerges.suggest(database: database, embedder: stub, now: day2)
        #expect(count == 1)
        let pending = try TaskMerges.pending(database: database)
        #expect(pending.count == 1)
        #expect(Set([pending[0].nameA, pending[0].nameB])
            == Set(["capture daemon", "capture daemon leak"]))

        // Re-running upserts nothing new (unique pair).
        #expect(try TaskMerges.suggest(database: database, embedder: stub, now: day2) == 0)
    }

    @Test func noSuggestionWithoutSourceOverlap() throws {
        let database = try ShifuDatabase.inMemory()
        try seed(database, sharedSource: false)
        #expect(try TaskMerges.suggest(database: database, embedder: stub, now: day2) == 0)
    }

    @Test func nilEmbedderIsANoOp() throws {
        let database = try ShifuDatabase.inMemory()
        try seed(database)
        let nilStub = StubEmbedder(vectors: [:])
        #expect(try TaskMerges.suggest(database: database, embedder: nilStub, now: day2) == 0)
        #expect(try TaskMerges.pending(database: database).isEmpty)
    }

    @Test func dismissedPairStaysDismissed() throws {
        let database = try ShifuDatabase.inMemory()
        try seed(database)
        _ = try TaskMerges.suggest(database: database, embedder: stub, now: day2)
        let pending = try TaskMerges.pending(database: database)
        try TaskMerges.dismiss(suggestionID: pending[0].id, database: database)

        #expect(try TaskMerges.suggest(database: database, embedder: stub, now: day2) == 0)
        #expect(try TaskMerges.pending(database: database).isEmpty)
    }

    @Test func mergeRepointsRebuildsAndKeepsSurvivorName() async throws {
        let database = try ShifuDatabase.inMemory()
        let vault = try makeVault(database)
        try seed(database)
        _ = try await WorkNoteCompiler.run(
            database: database, vault: vault, backend: nil, from: ms(day1), to: ms(day2))
        _ = try TaskMerges.suggest(database: database, embedder: stub, now: day2)
        let suggestion = try TaskMerges.pending(database: database)[0]

        // Bigger task ("capture daemon", renamed by the user) must survive.
        let survivorKey = "topic:capture-daemon"
        let absorbedKey = "topic:capture-daemon-leak"
        let survivorID = try await taskID(database, key: survivorKey)
        try await database.queue.write { db in
            try db.execute(sql: """
                UPDATE activities SET ended_at = ended_at + 3600000
                WHERE task_id = ?
                """, arguments: [survivorID])
            try db.execute(sql: "UPDATE tasks SET name = 'My Daemon Work' WHERE id = ?",
                           arguments: [survivorID])
        }

        try TaskMerges.merge(suggestion, database: database, vault: vault, calendar: calendar)

        let survivors = try await database.queue.read { db in
            try String.fetchAll(db, sql: "SELECT key || '|' || name FROM tasks ORDER BY id")
        }
        #expect(survivors.count == 2)  // daemon (merged) + cooking
        #expect(survivors.contains("\(survivorKey)|My Daemon Work"))
        #expect(survivors.allSatisfy { !$0.hasPrefix("\(absorbedKey)|") })

        let orphaned = try await database.queue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM activities a
                LEFT JOIN tasks t ON t.id = a.task_id
                WHERE a.task_id IS NOT NULL AND t.id IS NULL
                """)!
        }
        #expect(orphaned == 0)  // all activities repointed

        // Absorbed task's work note removed; survivor's re-landed the time.
        let dayStr = WorkNoteCompiler.dayString(ms(day1), calendar: calendar)
        #expect(vault.workNote(day: dayStr, taskKey: absorbedKey) == nil)
        let survivorNote = try #require(vault.workNote(day: dayStr, taskKey: survivorKey))
        #expect(survivorNote.durationMs >= 2 * 3_600_000)
        #expect(survivorNote.taskName == "My Daemon Work")

        // Suggestion recorded as merged, not re-offered.
        #expect(try TaskMerges.pending(database: database).isEmpty)
        #expect(try TaskMerges.suggest(database: database, embedder: stub, now: day2) == 0)
    }

    @Test func signaturesAreStableAcrossReanalysis() throws {
        let database = try ShifuDatabase.inMemory()
        try database.queue.write { db in
            var activity = Activity(
                startedAt: ms(day1), endedAt: ms(day1) + 3_600_000,
                appBundle: "com.apple.dt.Xcode", category: .work, topic: "capture daemon")
            try activity.insert(db)
            try db.execute(sql: """
                INSERT INTO observations
                    (started_at, last_seen, app_bundle, capture_kind, window_title, session_id)
                VALUES (?, ?, 'com.apple.dt.Xcode', 'ax', 'ShifuCore.swift', ?)
                """, arguments: [ms(day1), ms(day1), activity.id])
        }
        try TaskMerges.writeSignatures(database: database, from: ms(day1), to: ms(day2))
        let first = try signatures(database)
        #expect(first == ["capture daemon; ShifuCore.swift; com.apple.dt.Xcode"])

        // LedgerBuilder-style rebuild: same span reborn under a fresh id.
        try database.queue.write { db in
            let old = try Int64.fetchOne(db, sql: "SELECT id FROM activities")!
            try db.execute(sql: "DELETE FROM activities")
            var reborn = Activity(
                startedAt: ms(day1), endedAt: ms(day1) + 3_600_000,
                appBundle: "com.apple.dt.Xcode", category: .work, topic: "capture daemon")
            try reborn.insert(db)
            try db.execute(sql: "UPDATE observations SET session_id = ? WHERE session_id = ?",
                           arguments: [reborn.id, old])
        }
        try TaskMerges.writeSignatures(database: database, from: ms(day1), to: ms(day2))
        #expect(try signatures(database) == first)
    }

    private func taskID(_ database: ShifuDatabase, key: String) async throws -> Int64 {
        try await database.queue.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM tasks WHERE key = ?", arguments: [key])!
        }
    }

    private func signatures(_ database: ShifuDatabase) throws -> [String] {
        try database.queue.read { db in
            try String.fetchAll(db, sql: """
                SELECT signature FROM activities WHERE signature IS NOT NULL ORDER BY started_at
                """)
        }
    }
}
