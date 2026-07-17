import Foundation
import GRDB
import Testing
@testable import ShifuCore

private struct MockBackend: LLMBackend {
    let name = "mock"
    let response: String
    func complete(prompt: String, maxTokens: Int) async throws -> String { response }
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
                  titles: ["WWDC session"], textSample: "swift concurrency deep dive"),
        ])
        #expect(prompt.contains("id=7"))
        #expect(prompt.contains("youtube.com"))
        #expect(prompt.contains("work, learning, entertainment"))
        #expect(!prompt.contains("private"))
    }

    @Test func runAppliesConfidentVerdictsOnly() async throws {
        let db = try ShifuDatabase.inMemory()
        try await db.queue.write { sqlite in
            var a = Activity(startedAt: 0, endedAt: 600_000, appBundle: "com.apple.Safari",
                             domain: "youtube.com", category: .entertainment, ambiguous: true)
            var b = Activity(startedAt: 700_000, endedAt: 900_000, appBundle: "com.random.app",
                             category: .unclassified, ambiguous: true)
            try a.insert(sqlite); try b.insert(sqlite)
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
}

@Suite struct DigestGeneratorTests {
    @Test func rendersBreakdownAndAnomaly() {
        let markdown = DigestGenerator.render(.init(
            date: Date(timeIntervalSince1970: 1_752_700_000),
            totals: [.work: 14_400_000, .social: 7_200_000],
            topBlocks: [(label: "github.com", category: .work, ms: 3_600_000)],
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
            var a = Activity(startedAt: base + 3_600_000, endedAt: base + 7_200_000,
                             appBundle: "com.apple.dt.Xcode", category: .work, topic: "shifu phase 3")
            try a.insert(sqlite)
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
