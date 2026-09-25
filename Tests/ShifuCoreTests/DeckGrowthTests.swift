import Foundation
import GRDB
import Testing
@testable import ShifuCore

/// Counts calls, like DeckBuilderTests' backend — its own copy because both
/// are file-private by design.
private final class GrowthBackend: LLMBackend, @unchecked Sendable {
    let name = "deck-growth"
    let contextWindowTokens = 60_000
    private let response: String
    private let lock = NSLock()
    private(set) var prompts: [String] = []

    init(response: String = "[]") {
        self.response = response
    }

    var calls: Int { lock.withLock { prompts.count } }

    func complete(prompt: String, maxTokens: Int) async throws -> String {
        lock.withLock { prompts.append(prompt) }
        return response
    }
}

/// How a deck is customized and how it grows (§5.2): the topic narrowing on
/// a build, and the "Add cards" request that turns one deck into chapters.
@Suite struct DeckGrowthTests {
    private let now = Date(timeIntervalSince1970: 1_760_000_000)
    private var nowMs: Int64 { Int64(now.timeIntervalSince1970 * 1_000) }

    private func scratch() throws -> (ShifuDatabase, VaultStore) {
        let database = try ShifuDatabase.inMemory()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shifu-growth-test-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (database, VaultStore(root: dir, database: database))
    }

    private func cardsResponse(_ topics: [String]) -> String {
        "[" + topics.map { topic in
            """
            {"topic": "\(topic)", "note": "An explanation of \(topic).",
             "question": "What is \(topic) in biology?", "answer": "The \(topic) answer.",
             "confidence": 0.9}
            """
        }.joined(separator: ", ") + "]"
    }

    private func sample(_ topic: String) -> DeckStore.SampleCard {
        DeckStore.SampleCard(
            topic: topic, note: "Reference paragraph about \(topic).",
            question: "What does \(topic) do?", answer: "It does the \(topic) thing.")
    }

    /// A task with `blocks` learning blocks, block 0 the most recent.
    /// `blockTopics` cycles over them; an empty string seeds that block
    /// topicless, like every rules-classified block is.
    private func seedTask(
        _ database: ShifuDatabase, key: String, name: String, blocks: Int,
        blockTopics: [String] = []
    ) throws {
        try database.queue.write { db in
            var task = WorkTask(key: key, name: name, createdAt: nowMs, lastActiveAt: nowMs)
            try task.insert(db)
            for index in 0..<blocks {
                let endedAt = nowMs - Int64(index) * 3_600_000
                let topic = blockTopics.isEmpty
                    ? nil : blockTopics[index % blockTopics.count]
                var activity = Activity(
                    startedAt: endedAt - 900_000, endedAt: endedAt,
                    appBundle: "com.apple.Safari", category: .learning,
                    topic: topic?.isEmpty == true ? nil : topic)
                try activity.insert(db)
                try db.execute(sql: "UPDATE activities SET task_id = ? WHERE id = ?",
                               arguments: [task.id, activity.id])
                var observation = Observation(
                    startedAt: activity.startedAt, lastSeen: endedAt,
                    appBundle: "com.apple.Safari", captureKind: .ocr,
                    text: String(repeating: "block \(index) screen text. ", count: 9),
                    sessionId: activity.id)
                try observation.insert(db)
            }
        }
    }

    // MARK: - Topics

    @Test func createStoresTopicsAndTheClaimCarriesThem() throws {
        let (database, _) = try scratch()
        try seedTask(database, key: "sem:biology", name: "Studying biology", blocks: 0)

        let deckKey = try #require(try DeckStore.create(
            title: "Biology", taskKey: "sem:biology",
            topics: ["Cell structure", "Genetics"], database: database))
        let deck = try #require(try DeckStore.deck(taskKey: "sem:biology",
                                                   database: database))
        #expect(deck.topics == ["Cell structure", "Genetics"])
        #expect(deck.section == nil)
        #expect(!deck.everBuilt)

        // The narrowing rides the claim — a drain retry in another process
        // must still build the chapter the user picked.
        let claim = try #require(try DeckStore.claimForBuild(key: deckKey,
                                                             database: database))
        #expect(claim.topics == ["Cell structure", "Genetics"])
        #expect(claim.builtAt == nil)
    }

    /// Empty and nil both store NULL and read back as "all topics" — an
    /// empty narrowing would build a deck from nothing, which no form allows.
    @Test func emptyTopicsReadBackAsAutomatic() throws {
        #expect(DeckStore.encodeTopics(nil) == nil)
        #expect(DeckStore.encodeTopics([]) == nil)
        #expect(DeckStore.decodeTopics(nil) == nil)
        #expect(DeckStore.decodeTopics("[]") == nil)
        #expect(DeckStore.decodeTopics(DeckStore.encodeTopics(["a", "b"])) == ["a", "b"])
    }

    /// A topic narrowing filters the blocks *and* aims the prompt: the model
    /// sees only the picked topics' screen text, plus the line naming them.
    @Test func topicNarrowingFiltersBlocksAndReachesThePrompt() async throws {
        let (database, vault) = try scratch()
        defer { try? FileManager.default.removeItem(at: vault.root) }
        try seedTask(database, key: "sem:biology", name: "Studying biology", blocks: 4,
                     blockTopics: ["Genetics", "Cell structure"])
        let deckKey = try #require(try DeckStore.create(
            title: "Biology", taskKey: "sem:biology", topics: ["Genetics"],
            database: database, now: now))
        let backend = GrowthBackend(response: cardsResponse(["meiosis"]))

        #expect(try await DeckBuilder.build(deckKey: deckKey, database: database,
                                            vault: vault, backend: backend, now: now) == 1)
        #expect(backend.calls == 1)
        #expect(backend.prompts[0].contains("Only cover these topics"))
        #expect(backend.prompts[0].contains("Genetics"))
        // Blocks 0 and 2 carry the picked topic; 1 and 3 don't, and stay out.
        #expect(backend.prompts[0].contains("block 0 screen text"))
        #expect(backend.prompts[0].contains("block 2 screen text"))
        #expect(!backend.prompts[0].contains("block 1 screen text"))

        // No narrowing: no topics line at all.
        let plain = DeckBuilder.prompt(
            title: "Biology", taskName: "Studying biology", instructions: nil,
            blocks: [DeckBuilder.BlockText(id: 1, text: "screen text")])
        #expect(!plain.contains("Only cover these topics"))
    }

    /// The checklist offers the distinct topics of exactly the blocks the
    /// unnarrowed build would read, most recent first; topicless
    /// (rules-classified) blocks and repeats stay out.
    @Test func taskTopicsAreDistinctRecentFirstAndSkipTopicless() throws {
        let (database, _) = try scratch()
        try seedTask(database, key: "sem:biology", name: "Studying biology", blocks: 6,
                     blockTopics: ["Genetics", "", "Cell structure"])
        #expect(try DeckBuilder.taskTopics(taskKey: "sem:biology", database: database)
            == ["Genetics", "Cell structure"])
        #expect(try DeckBuilder.taskTopics(taskKey: "sem:absent", database: database)
            .isEmpty)
    }

    /// The checklist's window is the *build's* window — all recent blocks,
    /// topicless ones included. A topic whose blocks were all displaced past
    /// `maxBlocks` by newer material must not be offered: the all-on default
    /// build would never read it, and a checklist that names it advertises
    /// coverage the deck won't have.
    @Test func taskTopicsStopAtTheBuildWindow() throws {
        let (database, _) = try scratch()
        // One topic per block (the cycle is the block count): the newest 40
        // alternate a live topic with topicless blocks, and the only
        // "Genetics" blocks sit just past the window.
        let pattern = (0..<DeckBuilder.maxBlocks).map {
            $0.isMultiple(of: 2) ? "Cell structure" : ""
        } + ["Genetics", "Genetics"]
        try seedTask(database, key: "sem:history", name: "Long history",
                     blocks: pattern.count, blockTopics: pattern)
        #expect(try DeckBuilder.taskTopics(taskKey: "sem:history", database: database)
            == ["Cell structure"])
    }

    // MARK: - Add cards

    /// "Add cards" fires only from `ready`: the request columns belong to
    /// whatever build is in flight, and a pending or claimed deck keeps what
    /// it was asked. From `ready` it overwrites the request and re-enters
    /// `pending` — with `built_at` surviving, which is what keeps the deck
    /// reviewable mid-addition.
    @Test func requestMoreCardsIsACompareAndSetFromReady() throws {
        let (database, _) = try scratch()
        try seedTask(database, key: "sem:biology", name: "Studying biology", blocks: 0)
        let deckKey = try #require(try DeckStore.create(
            title: "Biology", taskKey: "sem:biology",
            instructions: "The broad pass.", database: database))

        // Pending, then claimed: nothing to add to yet, both no-ops.
        #expect(try DeckStore.requestMoreCards(key: deckKey, section: "Genetics",
                                               database: database) == false)
        _ = try DeckStore.claimForBuild(key: deckKey, database: database)
        #expect(try DeckStore.requestMoreCards(key: deckKey, section: "Genetics",
                                               database: database) == false)

        try DeckStore.markReady(key: deckKey, database: database)
        #expect(try DeckStore.requestMoreCards(
            key: deckKey, instructions: "Only heredity.", topics: ["Genetics"],
            cardRange: DeckStore.CardRange(lower: 5, upper: 10),
            section: "  Genetics  ", database: database))

        let deck = try #require(try DeckStore.deck(taskKey: "sem:biology",
                                                   database: database))
        #expect(deck.status == .pending)
        #expect(deck.everBuilt)
        #expect(deck.instructions == "Only heredity.")
        #expect(deck.topics == ["Genetics"])
        #expect(deck.cardRange == DeckStore.CardRange(lower: 5, upper: 10))
        #expect(deck.section == "Genetics")

        // The re-opened deck is claimable again, and the claim knows it is
        // an addition.
        let claim = try #require(try DeckStore.claimForBuild(key: deckKey,
                                                             database: database))
        #expect(claim.builtAt != nil)
        #expect(claim.section == "Genetics")
        #expect(claim.topics == ["Genetics"])
    }

    @Test func writeStampsTheSectionAndItSurvivesTheFile() throws {
        let (database, vault) = try scratch()
        defer { try? FileManager.default.removeItem(at: vault.root) }
        try seedTask(database, key: "sem:biology", name: "Studying biology", blocks: 0)
        let deckKey = try #require(try DeckStore.create(
            title: "Biology", taskKey: "sem:biology", database: database))

        #expect(try DeckStore.write(sample("meiosis"), deckKey: deckKey,
                                    taskKey: "sem:biology", vault: vault,
                                    section: "Genetics"))
        let card = try #require(try vault.deckNotes(deckKey: deckKey).first)
        #expect(card.section == "Genetics")
        // Round-trips the Markdown, not just the struct — the vault file is
        // the source of truth the index is rebuilt from.
        let reparsed = try #require(Note.parse(card.serialize()))
        #expect(reparsed.section == "Genetics")
    }

    /// An addition — "Add cards" on a built deck — tells the model what the
    /// deck already holds, budgets *new* cards rather than a deck total, and
    /// stamps its chapter into everything it writes.
    @Test func additionsKnowTheDeckAndStampTheirChapter() async throws {
        let (database, vault) = try scratch()
        defer { try? FileManager.default.removeItem(at: vault.root) }
        try seedTask(database, key: "sem:biology", name: "Studying biology", blocks: 2)
        let deckKey = try #require(try DeckStore.create(
            title: "Biology", taskKey: "sem:biology", database: database, now: now))
        let first = GrowthBackend(response: cardsResponse(["mitosis", "osmosis"]))
        _ = try await DeckBuilder.build(deckKey: deckKey, database: database,
                                        vault: vault, backend: first, now: now)
        #expect(!first.prompts[0].contains("already holds"))

        #expect(try DeckStore.requestMoreCards(
            key: deckKey, cardRange: DeckStore.CardRange(lower: 3, upper: 5),
            section: "Genetics", database: database, now: now))
        let second = GrowthBackend(response: cardsResponse(["meiosis"]))
        #expect(try await DeckBuilder.build(deckKey: deckKey, database: database,
                                            vault: vault, backend: second, now: now) == 1)
        let prompt = second.prompts[0]
        #expect(prompt.contains("This deck already holds 2 cards"))
        #expect(prompt.contains("mitosis"))
        #expect(prompt.contains("new cards in this addition"))
        #expect(!prompt.contains("in total for this deck"))

        let cards = try vault.deckNotes(deckKey: deckKey)
        #expect(cards.count == 3)
        #expect(cards.filter { $0.section == "Genetics" }.map(\.topic) == ["meiosis"])
        // The first build's cards stay unlabelled — chapters are per build.
        #expect(cards.filter { $0.section == nil }.count == 2)
        #expect(try DeckStore.decks(database: database)[0].status == .ready)
    }
}
