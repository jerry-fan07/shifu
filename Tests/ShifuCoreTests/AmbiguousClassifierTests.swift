import Foundation
import GRDB
import Testing
@testable import ShifuCore

private struct MockBackend: LLMBackend {
    let name = "mock"
    let response: String
    func complete(prompt: String, maxTokens: Int) async throws -> String { response }
}

/// Answers every block mentioned in the prompt and records each call, so
/// tests can assert how run() chunks work across a small context window.
private final class RecordingBackend: LLMBackend, @unchecked Sendable {
    let name = "recording"
    let contextWindowTokens: Int
    private let lock = NSLock()
    private(set) var prompts: [String] = []

    init(contextWindowTokens: Int) { self.contextWindowTokens = contextWindowTokens }

    func complete(prompt: String, maxTokens: Int) async throws -> String {
        lock.withLock { prompts.append(prompt) }
        let ids = prompt.split(separator: "\n").compactMap { line in
            line.hasPrefix("id=") ? Int64(line.dropFirst(3).prefix(while: \.isNumber)) : nil
        }
        let objects = ids.map {
            #"{"id": \#($0), "category": "learning", "confidence": 0.9, "topic": "t"}"#
        }
        return "[\(objects.joined(separator: ","))]"
    }
}

@Suite struct AmbiguousClassifierTests {
    @Test func parsesCleanJSON() {
        let verdicts = AmbiguousClassifier.parseVerdicts(
            #"[{"id": 3, "category": "learning", "confidence": 0.85, "topic": "sqlite wal mode"}]"#
        )
        #expect(verdicts == [.init(id: 3, category: .learning, confidence: 0.85,
                                   topic: "sqlite wal mode")])
    }

    @Test func parsesJSONWrappedInProse() {
        let response = """
        Here are the classifications:
        ```json
        [{"id": 1, "category": "social", "confidence": 0.7, "topic": "twitter timeline"}]
        ```
        """
        let verdicts = AmbiguousClassifier.parseVerdicts(response)
        #expect(verdicts.count == 1)
        #expect(verdicts[0].category == .social)
    }

    @Test func dropsInvalidEntries() {
        let verdicts = AmbiguousClassifier.parseVerdicts(
            #"[{"id": 1, "category": "nonsense", "confidence": 0.9}, {"category": "work"}]"#
        )
        #expect(verdicts.isEmpty)
    }

    @Test func promptListsBlocksAndCategories() {
        let prompt = AmbiguousClassifier.prompt(for: [
            .init(id: 7, appBundle: "com.apple.Safari", domain: "youtube.com",
                  titles: ["WWDC session"], textSample: "swift concurrency deep dive")
        ])
        #expect(prompt.contains("id=7"))
        #expect(prompt.contains("youtube.com"))
        #expect(prompt.contains("work, learning, entertainment"))
        #expect(!prompt.contains("private"))
    }

    @Test func batchesFitTokenBudgetAndPreserveAllSamples() {
        let samples = (1...12).map { id in
            AmbiguousClassifier.BlockSample(
                id: Int64(id), appBundle: "com.app.\(id)", domain: nil, titles: ["title \(id)"],
                textSample: String(repeating: "screen text ", count: 50))
        }
        let budget = 700
        let batches = AmbiguousClassifier.batches(samples, promptTokenBudget: budget)
        #expect(batches.count > 1)
        #expect(batches.flatMap { $0 }.map(\.id) == samples.map(\.id))
        for batch in batches {
            #expect(LLMTokens.estimate(AmbiguousClassifier.prompt(for: batch)) <= budget)
        }
    }

    @Test func oversizedLoneSampleStillGetsABatch() {
        let sample = AmbiguousClassifier.BlockSample(
            id: 1, appBundle: "com.big", domain: nil, titles: [],
            textSample: String(repeating: "x", count: 5_000))
        let batches = AmbiguousClassifier.batches([sample], promptTokenBudget: 100)
        #expect(batches.count == 1 && batches[0].count == 1 && batches[0][0].id == 1)
    }

    @Test func runSplitsAcrossSmallContextWindow() async throws {
        let db = try ShifuDatabase.inMemory()
        try await db.queue.write { sqlite in
            for index in 0..<10 {
                var activity = Activity(
                    startedAt: Int64(index) * 1_000_000, endedAt: Int64(index) * 1_000_000 + 600_000,
                    appBundle: "com.app.\(index)", category: .unclassified, ambiguous: true)
                try activity.insert(sqlite)
                try sqlite.execute(sql: """
                    INSERT INTO observations
                        (started_at, last_seen, app_bundle, window_title, capture_kind, text, session_id)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [Int64(index) * 1_000_000, Int64(index) * 1_000_000, "com.app.\(index)",
                                     "window \(index)", "ax",
                                     String(repeating: "dense ocr text ", count: 40), activity.id])
            }
        }
        // Window small enough that 10 fat samples cannot fit one prompt.
        let backend = RecordingBackend(contextWindowTokens: 2_600)
        let updated = try await AmbiguousClassifier.run(
            database: db, backend: backend, from: 0, to: 100_000_000)
        #expect(backend.prompts.count > 1)
        #expect(updated == 10)
        for prompt in backend.prompts {
            #expect(LLMTokens.estimate(prompt) <= 2_600 - AmbiguousClassifier.responseTokenReserve)
        }
    }

    @Test func runAppliesConfidentVerdictsOnly() async throws {
        let db = try ShifuDatabase.inMemory()
        try await db.queue.write { sqlite in
            var activityA = Activity(startedAt: 0, endedAt: 600_000, appBundle: "com.apple.Safari",
                                     domain: "youtube.com", category: .entertainment, ambiguous: true)
            var activityB = Activity(startedAt: 700_000, endedAt: 900_000, appBundle: "com.random.app",
                                     category: .unclassified, ambiguous: true)
            try activityA.insert(sqlite); try activityB.insert(sqlite)
        }
        let backend = MockBackend(response: """
        [{"id": 1, "category": "learning", "confidence": 0.9, "topic": "wwdc swift talks"},
         {"id": 2, "category": "work", "confidence": 0.3, "topic": "unknown app"}]
        """)
        let updated = try await AmbiguousClassifier.run(
            database: db, backend: backend, from: 0, to: 1_000_000)
        #expect(updated == 1)

        let rows = try await db.queue.read { try Activity.order(Column("started_at")).fetchAll($0) }
        #expect(rows[0].category == .learning)
        #expect(rows[0].source == "llm")
        #expect(rows[0].ambiguous == false)
        #expect(rows[0].topic == "wwdc swift talks")
        // Low confidence: unchanged, still ambiguous for a later retry.
        #expect(rows[1].category == .unclassified)
        #expect(rows[1].ambiguous == true)
    }

    /// A block that never clears the confidence floor is retried at most
    /// `maxAttempts` times, then dropped — bounding LLM re-billing on an
    /// unchanged window (design.md §12).
    @Test func lowConfidenceBlockStopsAfterMaxAttempts() async throws {
        let db = try ShifuDatabase.inMemory()
        try await db.queue.write { sqlite in
            var activity = Activity(startedAt: 0, endedAt: 600_000, appBundle: "com.random.app",
                                    category: .unclassified, ambiguous: true)
            try activity.insert(sqlite)
        }
        // Always answers below the 0.6 floor, and counts every call.
        final class WeakBackend: LLMBackend, @unchecked Sendable {
            let name = "weak"
            private let lock = NSLock()
            private(set) var calls = 0
            func complete(prompt: String, maxTokens: Int) async throws -> String {
                lock.withLock { calls += 1 }
                return #"[{"id": 1, "category": "work", "confidence": 0.2, "topic": "?"}]"#
            }
        }
        let backend = WeakBackend()
        for _ in 0..<(AmbiguousClassifier.maxAttempts + 2) {
            _ = try await AmbiguousClassifier.run(database: db, backend: backend, from: 0, to: 1_000_000)
        }
        // Called exactly maxAttempts times, then the block is skipped.
        #expect(backend.calls == AmbiguousClassifier.maxAttempts)
        let attempts = try await db.queue.read {
            try Int.fetchOne($0, sql: "SELECT llm_attempts FROM activities")
        }
        #expect(attempts == AmbiguousClassifier.maxAttempts)
    }

    /// The retry counter survives LedgerBuilder's rebuild (span-keyed carry),
    /// so an unchanged window doesn't reset the cooldown and re-bill.
    @Test func attemptCounterSurvivesRebuild() async throws {
        let db = try ShifuDatabase.inMemory()
        let base: Int64 = 1_760_000_000_000
        try await db.queue.write { sqlite in
            try sqlite.execute(sql: """
                INSERT INTO observations
                    (started_at, last_seen, app_bundle, window_title, capture_kind, text)
                VALUES (?, ?, 'com.random.app', 'thing', 'ax', ?)
                """, arguments: [base, base + 600_000, String(repeating: "weak signal ", count: 30)])
        }
        let classifier = try RulesClassifier(database: db)
        try LedgerBuilder.rebuild(database: db, classifier: classifier, from: base, to: base + 700_000)

        // Simulate two exhausted attempts on the block.
        try await db.queue.write {
            try $0.execute(sql: "UPDATE activities SET llm_attempts = 2")
        }
        // Rebuild the same window over unchanged observations.
        try LedgerBuilder.rebuild(database: db, classifier: classifier, from: base, to: base + 700_000)

        let attempts = try await db.queue.read {
            try Int.fetchOne($0, sql: "SELECT llm_attempts FROM activities")
        }
        #expect(attempts == 2)
    }
}

@Suite struct DigestGeneratorTests {
    @Test func rendersBreakdownAndAnomaly() {
        let markdown = DigestGenerator.render(.init(
            date: Date(timeIntervalSince1970: 1_752_700_000),
            totals: [.work: 14_400_000, .social: 7_200_000],
            topBlocks: [DigestGenerator.TopBlock(label: "github.com", category: .work, ms: 3_600_000)],
            topics: ["debugging shifu daemon"],
            weekAverages: [.work: 14_400_000, .social: 1_800_000]
        ))
        #expect(markdown.contains("**work**: 4.0 h"))
        #expect(markdown.contains("**social**: 2.0 h"))
        #expect(markdown.contains("4.0× your daily average"))   // 2h vs 30min avg
        #expect(!markdown.contains("work**: 4.0 h  ⚠️"))         // work is at its average
        #expect(markdown.contains("github.com"))
        #expect(markdown.contains("debugging shifu daemon"))
    }

    @Test func generateWritesFileOncePerDay() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("shifu-digest-test-\(UUID().uuidString)")
        setenv("SHIFU_HOME", scratch.path, 1)
        defer {
            unsetenv("SHIFU_HOME")
            try? FileManager.default.removeItem(at: scratch)
        }

        let db = try ShifuDatabase.inMemory()
        let dayStart = Calendar.current.startOfDay(for: Date())
        let base = Int64(dayStart.timeIntervalSince1970 * 1_000)
        try db.queue.write { sqlite in
            var activity = Activity(startedAt: base + 3_600_000, endedAt: base + 7_200_000,
                                    appBundle: "com.apple.dt.Xcode", category: .work, topic: "shifu phase 3")
            try activity.insert(sqlite)
        }

        let first = try DigestGenerator.generate(database: db)
        #expect(first != nil)
        let contents = try String(contentsOf: first!, encoding: .utf8)
        #expect(contents.contains("**work**: 1.0 h"))
        #expect(contents.contains("shifu phase 3"))

        // Second run same day: idempotent, no rewrite.
        let second = try DigestGenerator.generate(database: db)
        #expect(second == nil)
    }
}
