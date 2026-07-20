import Foundation
import GRDB
import Testing
@testable import ShifuCore

@Suite struct LedgerBuilderTests {
    private func seedObservations(_ db: ShifuDatabase) throws {
        let recorder = ObservationRecorder(database: db)
        try recorder.record(.init(timestamp: 1_000, appBundle: "com.apple.dt.Xcode",
                                  windowTitle: "shifu", captureKind: .ax, text: "swift code editing"))
        try recorder.record(.init(timestamp: 500_000, appBundle: "com.apple.Safari",
                                  windowTitle: "YT", url: "https://youtube.com/w",
                                  captureKind: .ax, text: "video comments feed"))
    }

    @Test func rebuildWritesClassifiedActivities() throws {
        let db = try ShifuDatabase.inMemory()
        try seedObservations(db)
        let summary = try LedgerBuilder.rebuild(
            database: db, classifier: RulesClassifier(), from: 0, to: 1_000_000)
        #expect(summary.blocksWritten == 2)

        let activities = try db.queue.read {
            try Activity.order(Column("started_at")).fetchAll($0)
        }
        #expect(activities.count == 2)
        #expect(activities[0].category == .work)
        #expect(activities[1].category == .entertainment)
        #expect(activities[1].ambiguous)

        // Observations got linked back to their session.
        let linked = try db.queue.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM observations WHERE session_id IS NOT NULL")
        }
        #expect(linked == 2)
    }

    @Test func rebuildIsIdempotent() throws {
        let db = try ShifuDatabase.inMemory()
        try seedObservations(db)
        try LedgerBuilder.rebuild(database: db, classifier: RulesClassifier(), from: 0, to: 1_000_000)
        try LedgerBuilder.rebuild(database: db, classifier: RulesClassifier(), from: 0, to: 1_000_000)
        let count = try db.queue.read { try Activity.fetchCount($0) }
        #expect(count == 2)
    }

    @Test func ruleChangeRelabelsOnRebuild() throws {
        let db = try ShifuDatabase.inMemory()
        try seedObservations(db)
        try LedgerBuilder.rebuild(database: db, classifier: RulesClassifier(), from: 0, to: 1_000_000)

        try db.queue.write { sqlite in
            try sqlite.execute(sql: """
                INSERT INTO rules (kind, value, category, ambiguous)
                VALUES ('domain', 'youtube.com', 'learning', 0)
                """)
        }
        try LedgerBuilder.rebuild(
            database: db, classifier: RulesClassifier(database: db), from: 0, to: 1_000_000)

        let categories = try db.queue.read {
            try String.fetchAll($0, sql: "SELECT category FROM activities ORDER BY started_at")
        }
        #expect(categories == ["work", "learning"])
    }

    @Test func totalsSumByCategory() throws {
        let db = try ShifuDatabase.inMemory()
        try db.queue.write { sqlite in
            var activityA = Activity(startedAt: 0, endedAt: 60_000, appBundle: "x", category: .work)
            var activityB = Activity(startedAt: 60_000, endedAt: 90_000, appBundle: "x", category: .work)
            var activityC = Activity(startedAt: 90_000, endedAt: 100_000, appBundle: "y", category: .social)
            try activityA.insert(sqlite); try activityB.insert(sqlite); try activityC.insert(sqlite)
        }
        let totals = try LedgerBuilder.totals(database: db, from: 0, to: 200_000)
        #expect(totals[.work] == 90_000)
        #expect(totals[.social] == 10_000)
    }
}

/// Derived state must survive the delete-and-reinsert rebuild: LLM verdicts
/// and the `extracted` flag carry across span-identical rows, so hourly
/// analyzer runs over unchanged observations make zero new LLM calls.
@Suite struct LedgerRebuildCarryTests {
    private final class CountingBackend: LLMBackend, @unchecked Sendable {
        let name = "counting-stub"
        private let response: String
        private let lock = NSLock()
        private var callCount = 0

        var calls: Int { lock.withLock { callCount } }

        init(response: String = "[]") { self.response = response }

        func complete(prompt: String, maxTokens: Int) async throws -> String {
            lock.withLock { callCount += 1 }
            return response
        }
    }

    /// A short Xcode block plus an ambiguous YouTube block long enough
    /// (≥3 min) and texty enough (≥200 chars) to qualify for extraction
    /// once the LLM relabels it as learning.
    private func seed(_ db: ShifuDatabase) throws {
        try db.queue.write { sqlite in
            var xcode = Observation(startedAt: 1_000, appBundle: "com.apple.dt.Xcode",
                                    windowTitle: "shifu", captureKind: .ax,
                                    text: "swift code editing")
            let article = String(repeating: "Swift actors serialize access to their state. ",
                                 count: 6)
            var video = Observation(startedAt: 500_000, lastSeen: 700_000,
                                    appBundle: "com.apple.Safari", windowTitle: "Actors — YT",
                                    url: "https://youtube.com/watch?v=1",
                                    captureKind: .ax, text: article)
            try xcode.insert(sqlite)
            try video.insert(sqlite)
        }
    }

    private func videoActivity(_ db: ShifuDatabase) throws -> Activity {
        try #require(try db.queue.read { sqlite in
            try Activity.filter(sql: "domain = 'youtube.com'").fetchOne(sqlite)
        })
    }

    @Test func rebuildCarriesLLMStateAndSkipsRework() async throws {
        let db = try ShifuDatabase.inMemory()
        try seed(db)
        try LedgerBuilder.rebuild(database: db, classifier: RulesClassifier(), from: 0, to: 1_000_000)

        let videoID = try #require(try videoActivity(db).id)
        let classifier = CountingBackend(response: #"""
            [{"id": \#(videoID), "category": "learning", "confidence": 0.9,
              "topic": "swift actors tutorial"}]
            """#)
        let relabeled = try await AmbiguousClassifier.run(
            database: db, backend: classifier, from: 0, to: 1_000_000)
        #expect(relabeled == 1)

        try TaskGrouper.run(database: db, from: 0, to: 1_000_000)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shifu-ledger-carry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let vault = VaultStore(root: root, database: db)
        let extractor = CountingBackend(response: #"""
            [{"topic": "swift actors", "note": "Actors serialize access to state.",
              "confidence": 0.9}]
            """#)
        let written = try await KnowledgeExtractor.run(
            database: db, vault: vault, backend: extractor, from: 0, to: 1_000_000)
        #expect(written == 1)
        #expect(classifier.calls == 1)
        #expect(extractor.calls == 1)

        // Second analyzer pass over unchanged observations.
        try LedgerBuilder.rebuild(database: db, classifier: RulesClassifier(), from: 0, to: 1_000_000)

        let video = try videoActivity(db)
        #expect(video.category == .learning)
        #expect(video.topic == "swift actors tutorial")
        #expect(video.source == "llm")
        #expect(video.confidence == 0.9)
        #expect(!video.ambiguous)
        let extracted = try await db.queue.read { sqlite in
            try Bool.fetchOne(sqlite, sql: "SELECT extracted FROM activities WHERE domain = 'youtube.com'")
        }
        #expect(extracted == true)

        // Nothing is pending for either LLM tier: zero new calls.
        let relabeledAgain = try await AmbiguousClassifier.run(
            database: db, backend: classifier, from: 0, to: 1_000_000)
        let writtenAgain = try await KnowledgeExtractor.run(
            database: db, vault: vault, backend: extractor, from: 0, to: 1_000_000)
        #expect(relabeledAgain == 0)
        #expect(writtenAgain == 0)
        #expect(classifier.calls == 1)
        #expect(extractor.calls == 1)
    }

    @Test func concreteRuleOutranksCarriedLLMLabel() async throws {
        let db = try ShifuDatabase.inMemory()
        try seed(db)
        try LedgerBuilder.rebuild(database: db, classifier: RulesClassifier(), from: 0, to: 1_000_000)

        let videoID = try #require(try videoActivity(db).id)
        let classifier = CountingBackend(response: #"""
            [{"id": \#(videoID), "category": "learning", "confidence": 0.9,
              "topic": "swift actors tutorial"}]
            """#)
        _ = try await AmbiguousClassifier.run(
            database: db, backend: classifier, from: 0, to: 1_000_000)

        // The user later pins youtube.com — the rule outranks the carried verdict.
        try await db.queue.write { sqlite in
            try sqlite.execute(sql: """
                INSERT INTO rules (kind, value, category, ambiguous)
                VALUES ('domain', 'youtube.com', 'entertainment', 0)
                """)
        }
        try LedgerBuilder.rebuild(
            database: db, classifier: RulesClassifier(database: db), from: 0, to: 1_000_000)

        let video = try videoActivity(db)
        #expect(video.category == .entertainment)
        #expect(video.source == "user")
        #expect(video.topic == nil)
        #expect(!video.ambiguous)
    }
}

@Suite struct RetentionTests {
    @Test func scrubsOnlyExpiredText() throws {
        let db = try ShifuDatabase.inMemory()
        let now = Date(timeIntervalSince1970: 100 * 86_400)
        let nowMs = Int64(now.timeIntervalSince1970 * 1_000)
        try db.queue.write { sqlite in
            var old = Observation(startedAt: nowMs - 20 * 86_400_000, appBundle: "a",
                                  captureKind: .ax, text: "old secret-ish text", textSimhash: 42)
            var fresh = Observation(startedAt: nowMs - 86_400_000, appBundle: "b",
                                    captureKind: .ax, text: "fresh text", textSimhash: 7)
            try old.insert(sqlite); try fresh.insert(sqlite)
        }
        let scrubbed = try Retention.scrubExpiredText(database: db, olderThanDays: 14, now: now)
        #expect(scrubbed == 1)
        let rows = try db.queue.read { try Observation.order(Column("started_at")).fetchAll($0) }
        #expect(rows[0].text == nil)
        #expect(rows[0].textSimhash == nil)
        #expect(rows[1].text == "fresh text")
    }
}
