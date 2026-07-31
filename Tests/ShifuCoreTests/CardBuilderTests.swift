import Foundation
import GRDB
import Testing
@testable import ShifuCore

private struct MockBackend: LLMBackend {
    let name = "mock"
    let response: String
    func complete(prompt: String, maxTokens: Int) async throws -> String { response }
}

/// Cards every block mentioned in the prompt and records each call, so tests
/// can assert how run() chunks work across a small context window.
private final class RecordingBackend: LLMBackend, @unchecked Sendable {
    static let topic = "synthetic anchor topic"

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
            #"{"id": \#($0), "cat": "learning", "conf": 0.9, "#
                + #""topic": "\#(Self.topic)", "entities": [], "gist": "reading the thing"}"#
        }
        return "[\(objects.joined(separator: ","))]"
    }
}

@Suite struct CardBuilderTests {
    /// One closed, evidence-bearing block, eligible for a card.
    @discardableResult
    private func seedBlock(
        _ db: ShifuDatabase, startedAt: Int64 = 0, minutes: Int64 = 10,
        bundle: String = "com.apple.Safari", domain: String? = "youtube.com",
        ambiguous: Bool = true, source: String = "rules",
        text: String? = "some screen text"
    ) throws -> Int64 {
        try db.queue.write { sqlite in
            var activity = Activity(
                startedAt: startedAt, endedAt: startedAt + minutes * 60_000,
                appBundle: bundle, domain: domain, category: .unclassified,
                source: source, ambiguous: ambiguous)
            try activity.insert(sqlite)
            if let text {
                try sqlite.execute(sql: """
                    INSERT INTO observations
                        (started_at, last_seen, app_bundle, window_title, capture_kind,
                         text, session_id)
                    VALUES (?, ?, ?, 'some window', 'ax', ?, ?)
                    """, arguments: [startedAt, startedAt + minutes * 60_000, bundle,
                                     text, activity.id])
            }
            return activity.id!
        }
    }

    @Test func blockCardRoundTripsThroughJSONAndRendersItsFacts() throws {
        let card = BlockCard(category: .work, topic: "shifu llm cost accounting",
                             entities: ["repo:shifu", "file:LLMUsage.swift"],
                             gist: "wiring per-call token usage into sqlite")
        let json = try #require(card.json)
        #expect(BlockCard.parse(json) == card)
        #expect(card.promptFacts
            == "wiring per-call token usage into sqlite | topic=shifu llm cost accounting"
            + " | repo:shifu, file:LLMUsage.swift")
    }

    @Test func parsesCleanJSONAndProseWrappedJSON() throws {
        let clean = CardBuilder.parseVerdicts(#"""
            [{"id": 3, "cat": "learning", "conf": 0.85, "topic": "sqlite wal mode",
              "entities": ["doc:sqlite wal"], "gist": "reading the wal docs"}]
            """#)
        #expect(clean == [.init(
            id: 3,
            card: BlockCard(category: .learning, topic: "sqlite wal mode",
                            entities: ["doc:sqlite wal"], gist: "reading the wal docs"),
            confidence: 0.85)])

        let wrapped = CardBuilder.parseVerdicts("""
        Here are the cards:
        ```json
        [{"id": 1, "cat": "social", "conf": 0.7, "topic": "twitter timeline",
          "entities": [], "gist": "scrolling the feed"}]
        ```
        """)
        #expect(wrapped.count == 1)
        #expect(wrapped[0].card.category == .social)
    }

    /// A half-card would poison every prompt that later renders it, so
    /// anything without a valid category, topic, and gist is dropped whole.
    @Test func dropsCardsMissingAnyRequiredField() {
        let verdicts = CardBuilder.parseVerdicts(#"""
            [{"id": 1, "cat": "nonsense", "conf": 0.9, "topic": "t", "gist": "g"},
             {"id": 2, "cat": "work", "conf": 0.9, "gist": "no topic"},
             {"id": 3, "cat": "work", "conf": 0.9, "topic": "no gist"},
             {"cat": "work", "conf": 0.9, "topic": "t", "gist": "no id"}]
            """#)
        #expect(verdicts.isEmpty)
    }

    @Test func entitiesAreCappedAndCleaned() {
        let verdicts = CardBuilder.parseVerdicts(#"""
            [{"id": 1, "cat": "work", "conf": 0.9, "topic": "t",
              "entities": ["a:1", " ", "b:2", "c:3", "d:4", "e:5"], "gist": "g"}]
            """#)
        #expect(verdicts[0].card.entities == ["a:1", "b:2", "c:3", "d:4"])
    }

    @Test func promptListsBlocksCategoriesAndFields() {
        let prompt = CardBuilder.prompt(for: [
            .init(id: 7, appBundle: "com.apple.Safari", domain: "youtube.com",
                  ambiguous: true, titles: ["WWDC session"],
                  textSample: "swift concurrency deep dive")
        ])
        #expect(prompt.contains("id=7"))
        #expect(prompt.contains("youtube.com"))
        #expect(prompt.contains("work, learning, entertainment"))
        #expect(!prompt.contains("private"))
        #expect(prompt.contains("entities"))
        #expect(prompt.contains("gist"))
    }

    @Test func promptAnchorsOngoingTopicsVerbatim() {
        let sample = CardBuilder.BlockSample(
            id: 1, appBundle: "com.apple.Safari", domain: "united.com",
            ambiguous: false, titles: [], textSample: "seat selection")
        let anchored = CardBuilder.prompt(
            for: [sample], ongoingTopics: ["booking flights to tokyo"])
        #expect(anchored.contains("- booking flights to tokyo"))
        #expect(anchored.contains("verbatim"))
        #expect(!CardBuilder.prompt(for: [sample]).contains("Ongoing tasks"))
    }

    /// Repeated wording collapses to one entry, and the spelling kept is the
    /// most recent one — that is what a later block has to match verbatim.
    @Test func ongoingTopicsDedupeBySlugKeepingTheNewestSpelling() throws {
        let db = try ShifuDatabase.inMemory()
        try db.queue.write { sqlite in
            for (topic, endedAt) in [("Debugging Capture Daemon", Int64(1_000_000)),
                                     ("debugging capture daemon", Int64(2_000_000)),
                                     ("booking flights", Int64(3_000_000))] {
                var activity = Activity(startedAt: endedAt - 600_000, endedAt: endedAt,
                                        appBundle: "com.app", category: .work, topic: topic)
                try activity.insert(sqlite)
            }
        }
        let topics = try CardBuilder.ongoingTopics(database: db, before: 4_000_000)
        #expect(topics == ["booking flights", "debugging capture daemon"])
    }

    /// `activeRoster` renders in key order for a reason: a recency-ordered
    /// list renders differently on every pass, which moves the bytes of the
    /// prompt and costs the provider's context-cache prefix. This list rides
    /// in the same prompt and had the same bug — recency is the right way to
    /// *choose* the topics, but it must not also be the order they are
    /// *printed* in, or an hour of ordinary work reshuffles the header.
    @Test func ongoingTopicsRenderInAStableOrderAsRecencyMoves() throws {
        func topics(newest: String) throws -> [String] {
            let db = try ShifuDatabase.inMemory()
            try db.queue.write { sqlite in
                for topic in ["zebra migration", "alpha rollout"] {
                    let endedAt: Int64 = topic == newest ? 3_000_000 : 1_000_000
                    var activity = Activity(
                        startedAt: endedAt - 600_000, endedAt: endedAt,
                        appBundle: "com.app", category: .work, topic: topic)
                    try activity.insert(sqlite)
                }
            }
            return try CardBuilder.ongoingTopics(database: db, before: 4_000_000)
        }
        let alphaWorkedLast = try topics(newest: "alpha rollout")
        let zebraWorkedLast = try topics(newest: "zebra migration")
        #expect(alphaWorkedLast == zebraWorkedLast)
        #expect(alphaWorkedLast == ["alpha rollout", "zebra migration"])
    }

    /// Choosing by recency still has to survive the reordering: the window's
    /// most recent topics are the ones that make the cut, they just print in
    /// a stable order once chosen.
    @Test func theMostRecentTopicsAreStillTheOnesKept() throws {
        let db = try ShifuDatabase.inMemory()
        try db.queue.write { sqlite in
            for (topic, endedAt) in [("aaa stale", Int64(1_000_000)),
                                     ("mmm recent", Int64(2_000_000)),
                                     ("zzz recent", Int64(3_000_000))] {
                var activity = Activity(startedAt: endedAt - 600_000, endedAt: endedAt,
                                        appBundle: "com.app", category: .work, topic: topic)
                try activity.insert(sqlite)
            }
        }
        // The stalest topic loses the cut even though it sorts first.
        let topics = try CardBuilder.ongoingTopics(database: db, before: 4_000_000, limit: 2)
        #expect(topics == ["mmm recent", "zzz recent"])
    }

    @Test func batchesFitTokenBudgetAndPreserveAllSamples() {
        let samples = (1...12).map { id in
            CardBuilder.BlockSample(
                id: Int64(id), appBundle: "com.app.\(id)", domain: nil, ambiguous: false,
                titles: ["title \(id)"],
                textSample: String(repeating: "screen text ", count: 50))
        }
        let budget = 700
        let batches = CardBuilder.batches(samples, promptTokenBudget: budget)
        #expect(batches.count > 1)
        #expect(batches.flatMap { $0 }.map(\.id) == samples.map(\.id))
        for batch in batches {
            #expect(LLMTokens.estimate(CardBuilder.prompt(for: batch)) <= budget)
        }
    }

    @Test func oversizedLoneSampleStillGetsABatch() {
        let sample = CardBuilder.BlockSample(
            id: 1, appBundle: "com.big", domain: nil, ambiguous: false, titles: [],
            textSample: String(repeating: "x", count: 5_000))
        let batches = CardBuilder.batches([sample], promptTokenBudget: 100)
        #expect(batches.count == 1 && batches[0].count == 1 && batches[0][0].id == 1)
    }

    @Test func runSplitsAcrossSmallContextWindowAndAnchorsCoinedTopics() async throws {
        let db = try ShifuDatabase.inMemory()
        for index in 0..<10 {
            try seedBlock(db, startedAt: Int64(index) * 1_000_000, bundle: "com.app.\(index)",
                          domain: nil,
                          text: String(repeating: "dense ocr text ", count: 40))
        }
        // Window small enough that 10 fat samples cannot fit one prompt, but
        // still larger than the response reserve. Expressed against the
        // reserve so that raising one cannot silently invert the other — a
        // fixed 4_000 here went negative the moment the reserve grew.
        let window = CardBuilder.responseTokenReserve + 1_000
        let backend = RecordingBackend(contextWindowTokens: window)
        let summary = try await CardBuilder.run(
            database: db, backend: backend, from: 0, to: 100_000_000)
        #expect(backend.prompts.count > 1)
        #expect(summary.built == 10)
        #expect(summary.relabeled == 10)
        for prompt in backend.prompts {
            #expect(LLMTokens.estimate(prompt) <= window - CardBuilder.responseTokenReserve)
        }
        // A topic coined in the first batch anchors every later one, so one
        // effort split across batches cannot come back with two wordings.
        #expect(!backend.prompts[0].contains("- \(RecordingBackend.topic)"))
        for prompt in backend.prompts.dropFirst() {
            #expect(prompt.contains("- \(RecordingBackend.topic)"))
        }
    }

    @Test func cardsLandButOnlyConfidentAmbiguousBlocksRelabel() async throws {
        let db = try ShifuDatabase.inMemory()
        let sureID = try seedBlock(db, startedAt: 0)
        let unsureID = try seedBlock(db, startedAt: 3_600_000, bundle: "com.random.app",
                                     domain: nil)
        let backend = MockBackend(response: #"""
            [{"id": \#(sureID), "cat": "learning", "conf": 0.9,
              "topic": "wwdc swift talks", "entities": [], "gist": "watching a session"},
             {"id": \#(unsureID), "cat": "work", "conf": 0.3,
              "topic": "unknown app", "entities": [], "gist": "unclear activity"}]
            """#)
        let summary = try await CardBuilder.run(
            database: db, backend: backend, from: 0, to: 10_000_000)
        #expect(summary == .init(built: 2, relabeled: 1))

        let rows = try await db.queue.read { try Activity.order(Column("started_at")).fetchAll($0) }
        #expect(rows[0].category == .learning)
        #expect(rows[0].source == "llm")
        #expect(rows[0].ambiguous == false)
        #expect(rows[0].topic == "wwdc swift talks")
        // Low confidence: the card exists for downstream prompts, but the
        // ledger stays as the rules tier left it.
        #expect(rows[1].category == .unclassified)
        #expect(rows[1].ambiguous == true)
        let cards = try await db.queue.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM activities WHERE card IS NOT NULL")
        }
        #expect(cards == 2)
    }

    @Test func userRuledBlockGetsACardButKeepsItsCategory() async throws {
        let db = try ShifuDatabase.inMemory()
        let id = try seedBlock(db, source: "user")
        let backend = MockBackend(response: #"""
            [{"id": \#(id), "cat": "learning", "conf": 0.95,
              "topic": "wwdc swift talks", "entities": [], "gist": "watching a session"}]
            """#)
        let summary = try await CardBuilder.run(
            database: db, backend: backend, from: 0, to: 10_000_000)
        #expect(summary == .init(built: 1, relabeled: 0))
        let row = try await db.queue.read { try Activity.fetchOne($0) }
        #expect(row?.source == "user")
        #expect(row?.category == .unclassified)
        let card = try await db.queue.read {
            try String.fetchOne($0, sql: "SELECT card FROM activities")
        }
        #expect(BlockCard.parse(card)?.gist == "watching a session")
    }

    /// A card is one shot per closed block — the evidence can't improve — but
    /// the *failure* paths retry up to the cap: a garbage answer burns an
    /// attempt rather than either looping forever or giving up at once.
    @Test func garbageAnswersBurnAttemptsAndStopAtTheCap() async throws {
        let db = try ShifuDatabase.inMemory()
        try seedBlock(db)
        final class GarbageBackend: LLMBackend, @unchecked Sendable {
            let name = "garbage"
            private let lock = NSLock()
            private(set) var calls = 0
            func complete(prompt: String, maxTokens: Int) async throws -> String {
                lock.withLock { calls += 1 }
                return "I could not produce JSON, sorry."
            }
        }
        let backend = GarbageBackend()
        for _ in 0..<(CardBuilder.maxAttempts + 2) {
            _ = try await CardBuilder.run(database: db, backend: backend, from: 0, to: 10_000_000)
        }
        #expect(backend.calls == CardBuilder.maxAttempts)
        let attempts = try await db.queue.read {
            try Int.fetchOne($0, sql: "SELECT card_attempts FROM activities")
        }
        #expect(attempts == CardBuilder.maxAttempts)
    }

    /// A block ending within a sessionizer gap of `to` may still be growing;
    /// its card would die with the next rebuild's span change — pay once, on
    /// the closed block.
    @Test func aBlockStillInsideTheSessionGapIsNeverSent() throws {
        let db = try ShifuDatabase.inMemory()
        let closedID = try seedBlock(db, startedAt: 0)
        try seedBlock(db, startedAt: 9_400_000)   // ends exactly at `to`
        let samples = try CardBuilder.pendingSamples(database: db, from: 0, to: 10_000_000)
        #expect(samples.map(\.id) == [closedID])
    }
}

/// Answers each batch with cards for the ids it was actually shown, plus one
/// card for an id that was never in any batch — a model inventing an id.
private final class PhantomIDBackend: LLMBackend, @unchecked Sendable {
    static let phantomTopic = "phantom topic never stored"
    static let phantomID: Int64 = 999_999

    let name = "phantom"
    let contextWindowTokens: Int
    private let lock = NSLock()
    private(set) var prompts: [String] = []

    init(contextWindowTokens: Int) { self.contextWindowTokens = contextWindowTokens }

    func complete(prompt: String, maxTokens: Int) async throws -> String {
        lock.withLock { prompts.append(prompt) }
        let ids = prompt.split(separator: "\n").compactMap { line in
            line.hasPrefix("id=") ? Int64(line.dropFirst(3).prefix(while: \.isNumber)) : nil
        }
        var objects = ids.map {
            #"{"id": \#($0), "cat": "learning", "conf": 0.9, "topic": "a real topic", "#
                + #""entities": [], "gist": "reading the thing"}"#
        }
        objects.append(
            #"{"id": \#(Self.phantomID), "cat": "work", "conf": 0.9, "#
                + #""topic": "\#(Self.phantomTopic)", "entities": [], "gist": "invented"}"#)
        return "[\(objects.joined(separator: ","))]"
    }
}

// Extension keeps the suite's type body inside the lint budget.
extension CardBuilderTests {
    /// A card whose id wasn't in the batch is already kept out of the database
    /// by `apply`. It must stay out of the *anchor* list too: anchors are shown
    /// to later batches as wording to repeat verbatim, and topic wording is
    /// what `TaskGrouper.key` slugs into a task key — so an invented topic that
    /// catches on becomes a task named after a block that never existed.
    @Test func aCardForABlockOutsideTheBatchNeverAnchorsLaterBatches() async throws {
        let db = try ShifuDatabase.inMemory()
        for index in 0..<10 {
            try seedBlock(db, startedAt: Int64(index) * 1_000_000, bundle: "com.app.\(index)",
                          domain: nil,
                          text: String(repeating: "dense ocr text ", count: 40))
        }
        let backend = PhantomIDBackend(contextWindowTokens: 4_000)
        let summary = try await CardBuilder.run(
            database: db, backend: backend, from: 0, to: 100_000_000)

        // Sanity: the window is small enough that there *are* later batches.
        #expect(backend.prompts.count > 1)
        #expect(summary.built == 10)
        for prompt in backend.prompts.dropFirst() {
            #expect(!prompt.contains("- \(PhantomIDBackend.phantomTopic)"))
        }
        let stored = try await db.queue.read { sqlite in
            try Int.fetchOne(sqlite, sql: """
                SELECT COUNT(*) FROM activities WHERE card LIKE ?
                """, arguments: ["%\(PhantomIDBackend.phantomTopic)%"])
        }
        #expect(stored == 0)
    }
}
