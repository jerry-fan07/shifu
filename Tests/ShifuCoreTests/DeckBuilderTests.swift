import Foundation
import GRDB
import Testing
@testable import ShifuCore

/// Counts calls and can be told to fail — the claim lifecycle is a
/// call-count and failure-path claim.
private final class DeckBackend: LLMBackend, @unchecked Sendable {
    let name = "deck"
    let contextWindowTokens: Int
    private let response: String
    private let failing: Bool
    private let lock = NSLock()
    private(set) var prompts: [String] = []

    init(response: String = "[]", failing: Bool = false, window: Int = 60_000) {
        self.response = response
        self.failing = failing
        self.contextWindowTokens = window
    }

    var calls: Int { lock.withLock { prompts.count } }

    func complete(prompt: String, maxTokens: Int) async throws -> String {
        lock.withLock { prompts.append(prompt) }
        if failing { throw LLMError.unavailable("scripted failure") }
        return response
    }
}

@Suite struct DeckBuilderTests {
    private let now = Date(timeIntervalSince1970: 1_760_000_000)
    private var nowMs: Int64 { Int64(now.timeIntervalSince1970 * 1_000) }

    private func scratch() throws -> (ShifuDatabase, VaultStore) {
        let database = try ShifuDatabase.inMemory()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shifu-build-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (database, VaultStore(root: dir, database: database))
    }

    private func cardsResponse(_ topics: [String]) -> String {
        "[" + topics.map { topic in
            """
            {"topic": "\(topic)", "note": "An explanation of \(topic).",
             "question": "What is \(topic) in FSRS?", "answer": "The \(topic) answer.",
             "confidence": 0.9}
            """
        }.joined(separator: ", ") + "]"
    }

    /// A task with `blocks` learning blocks, each carrying screen text.
    private func seedTask(
        _ database: ShifuDatabase, key: String, name: String, blocks: Int,
        textChars: Int = 200
    ) throws {
        try database.queue.write { db in
            var task = WorkTask(key: key, name: name, createdAt: nowMs, lastActiveAt: nowMs)
            try task.insert(db)
            for index in 0..<blocks {
                let endedAt = nowMs - Int64(index) * 3_600_000
                var activity = Activity(
                    startedAt: endedAt - 900_000, endedAt: endedAt,
                    appBundle: "com.apple.Safari", category: .learning)
                try activity.insert(db)
                try db.execute(sql: "UPDATE activities SET task_id = ? WHERE id = ?",
                               arguments: [task.id, activity.id])
                var observation = Observation(
                    startedAt: activity.startedAt, lastSeen: endedAt,
                    appBundle: "com.apple.Safari", captureKind: .ocr,
                    text: String(repeating: "block \(index) screen text. ",
                                 count: max(1, textChars / 24)),
                    sessionId: activity.id)
                try observation.insert(db)
            }
        }
    }

    @discardableResult
    private func seedDeck(_ database: ShifuDatabase, taskKey: String) throws -> String {
        try #require(try DeckStore.create(title: "FSRS internals", taskKey: taskKey,
                                          database: database, now: now))
    }

    // MARK: - Happy path

    @Test func builtCardsAreKeptSeededAndStamped() async throws {
        let (database, vault) = try scratch()
        defer { try? FileManager.default.removeItem(at: vault.root) }
        try seedTask(database, key: "sem:fsrs", name: "FSRS internals", blocks: 3)
        let deckKey = try seedDeck(database, taskKey: "sem:fsrs")
        let backend = DeckBackend(response: cardsResponse(["stability", "difficulty"]))

        let written = try await DeckBuilder.build(
            deckKey: deckKey, database: database, vault: vault, backend: backend, now: now)
        #expect(written == 2)
        #expect(backend.calls == 1)
        // The deck's own framing, and the task's screen text, reach the model.
        #expect(backend.prompts[0].contains("FSRS internals"))
        #expect(backend.prompts[0].contains("block 0 screen text"))
        #expect(backend.prompts[0].contains("cards that teach, not clippings"))

        let cards = try vault.deckNotes(deckKey: deckKey)
        #expect(cards.count == 2)
        #expect(cards.allSatisfy { $0.state == .kept })       // the request was the confirmation
        #expect(cards.allSatisfy { $0.srs != nil })
        #expect(cards.allSatisfy { $0.deck == deckKey })
        #expect(cards.allSatisfy { $0.taskKey == "sem:fsrs" })
        #expect(cards.allSatisfy { $0.questionAnswer != nil })
        #expect(try vault.inbox().isEmpty)
        #expect(try vault.due(asOf: now).count == 2)

        let deck = try #require(try DeckStore.decks(database: database).first)
        #expect(deck.status == .ready)
        #expect(deck.cardCount == 2)
        // Nothing was consumed from the extractor's high-water mark.
        let extracted = try await database.queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM activities WHERE extracted = 1")
        }
        #expect(extracted == 0)
    }

    @Test func lowConfidenceAndQAlessCandidatesAreDropped() async throws {
        let (database, vault) = try scratch()
        defer { try? FileManager.default.removeItem(at: vault.root) }
        try seedTask(database, key: "sem:fsrs", name: "FSRS internals", blocks: 1)
        let deckKey = try seedDeck(database, taskKey: "sem:fsrs")
        let backend = DeckBackend(response: """
            [{"topic": "keeper", "note": "n", "question": "What is keeper?",
              "answer": "a", "confidence": 0.9},
             {"topic": "unsure", "note": "n", "question": "q", "answer": "a",
              "confidence": 0.2},
             {"topic": "reference only", "note": "n", "confidence": 0.9}]
            """)

        #expect(try await DeckBuilder.build(deckKey: deckKey, database: database,
                                            vault: vault, backend: backend, now: now) == 1)
        #expect(try vault.deckNotes(deckKey: deckKey).map(\.topic) == ["keeper"])
    }

    // MARK: - Claim lifecycle

    /// The compare-and-set is the only guard between the app's `--build-deck`
    /// launch and the hourly drain, so a loser must cost nothing at all.
    @Test func secondBuilderNoOpsWithoutACall() async throws {
        let (database, vault) = try scratch()
        defer { try? FileManager.default.removeItem(at: vault.root) }
        try seedTask(database, key: "sem:fsrs", name: "FSRS internals", blocks: 2)
        let deckKey = try seedDeck(database, taskKey: "sem:fsrs")

        _ = try DeckStore.claimForBuild(key: deckKey, database: database, now: now)
        let backend = DeckBackend(response: cardsResponse(["stability"]))
        #expect(try await DeckBuilder.build(deckKey: deckKey, database: database,
                                            vault: vault, backend: backend, now: now) == nil)
        #expect(backend.calls == 0)
        #expect(try vault.deckNotes(deckKey: deckKey).isEmpty)
    }

    @Test func failureHandsTheDeckBackToPending() async throws {
        let (database, vault) = try scratch()
        defer { try? FileManager.default.removeItem(at: vault.root) }
        try seedTask(database, key: "sem:fsrs", name: "FSRS internals", blocks: 2)
        let deckKey = try seedDeck(database, taskKey: "sem:fsrs")
        let backend = DeckBackend(failing: true)

        await #expect(throws: LLMError.self) {
            try await DeckBuilder.build(deckKey: deckKey, database: database,
                                        vault: vault, backend: backend, now: now)
        }
        #expect(try DeckStore.decks(database: database)[0].status == .pending)
        #expect(try DeckStore.pendingDeckKeys(database: database) == [deckKey])
    }

    /// A deck whose task was pruned still has to reach `ready`, or the drain
    /// retries it every hour forever.
    @Test func deckWithNoBlocksStillGoesReady() async throws {
        let (database, vault) = try scratch()
        defer { try? FileManager.default.removeItem(at: vault.root) }
        try seedTask(database, key: "sem:fsrs", name: "FSRS internals", blocks: 2)
        let deckKey = try seedDeck(database, taskKey: "sem:fsrs")
        try await database.queue.write { db in try db.execute(sql: "DELETE FROM tasks") }
        let backend = DeckBackend(response: cardsResponse(["stability"]))

        #expect(try await DeckBuilder.build(deckKey: deckKey, database: database,
                                            vault: vault, backend: backend, now: now) == 0)
        #expect(backend.calls == 0)
        #expect(try DeckStore.pendingDeckKeys(database: database).isEmpty)
    }

    @Test func drainBuildsEveryWaitingDeck() async throws {
        let (database, vault) = try scratch()
        defer { try? FileManager.default.removeItem(at: vault.root) }
        for index in 0..<2 {
            try seedTask(database, key: "sem:subject-\(index)", name: "Subject \(index)",
                         blocks: 1)
            try DeckStore.create(title: "Deck \(index)", taskKey: "sem:subject-\(index)",
                                 database: database, now: now)
        }
        let backend = DeckBackend(response: cardsResponse(["stability"]))

        #expect(try await DeckBuilder.drainPending(
            database: database, vault: vault, backend: backend, now: now) == 2)
        #expect(try DeckStore.pendingDeckKeys(database: database).isEmpty)
        #expect(try DeckStore.decks(database: database).allSatisfy { $0.status == .ready })
    }

    // MARK: - Budget

    /// Batching is sized by the rendered prompt, never by block count
    /// (invariant 7) — a block is up to 6k chars of OCR text.
    @Test func batchesSplitUnderATinyWindow() async throws {
        let (database, vault) = try scratch()
        defer { try? FileManager.default.removeItem(at: vault.root) }
        try seedTask(database, key: "sem:fsrs", name: "FSRS internals", blocks: 6,
                     textChars: 2_000)
        let deckKey = try seedDeck(database, taskKey: "sem:fsrs")
        let backend = DeckBackend(response: "[]", window: DeckBuilder.responseTokens + 1_200)

        _ = try await DeckBuilder.build(deckKey: deckKey, database: database,
                                        vault: vault, backend: backend, now: now)
        #expect(backend.calls > 1)
        #expect(backend.prompts.allSatisfy {
            LLMTokens.estimate($0) <= backend.contextWindowTokens
        })
    }

    /// A second batch that repeats the first one's card must not double-file
    /// it — and the bump lands on the deck's own card, not somewhere else.
    @Test func repeatedCardBumpsSeenCountWithinTheDeck() async throws {
        let (database, vault) = try scratch()
        defer { try? FileManager.default.removeItem(at: vault.root) }
        try seedTask(database, key: "sem:fsrs", name: "FSRS internals", blocks: 1)
        let deckKey = try seedDeck(database, taskKey: "sem:fsrs")
        let backend = DeckBackend(response: cardsResponse(["stability", "stability"]))

        #expect(try await DeckBuilder.build(deckKey: deckKey, database: database,
                                            vault: vault, backend: backend, now: now) == 1)
        let cards = try vault.deckNotes(deckKey: deckKey)
        #expect(cards.count == 1)
        #expect(cards[0].seenCount == 2)
    }
}
