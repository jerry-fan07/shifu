import Foundation
import Testing
@testable import ShifuCore

/// Drafting (voice.md §4): the claim lifecycle the desk depends on, the
/// token budget (invariant 7), and the prompt's ordering — which is what makes
/// the preamble cacheable and the numbers the model's last word.
private final class VoiceBackend: LLMBackend, @unchecked Sendable {
    let name = "voice"
    let contextWindowTokens: Int
    let responseHeadroomTokens: Int
    private let response: String
    private let failing: Bool
    private let lock = NSLock()
    private(set) var prompts: [String] = []

    init(
        response: String = "Drafted in their voice.", failing: Bool = false,
        window: Int = 60_000, headroom: Int = 0
    ) {
        self.response = response
        self.failing = failing
        self.contextWindowTokens = window
        self.responseHeadroomTokens = headroom
    }

    var calls: Int { lock.withLock { prompts.count } }
    var lastPrompt: String { lock.withLock { prompts.last ?? "" } }

    func complete(prompt: String, maxTokens: Int) async throws -> String {
        lock.withLock { prompts.append(prompt) }
        if failing { throw LLMError.unavailable("scripted failure") }
        return response
    }
}

@Suite struct VoiceDrafterTests {
    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    private func scratch() throws -> (ShifuDatabase, VoiceStore) {
        let database = try ShifuDatabase.inMemory()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shifu-draft-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (database, VoiceStore(root: dir))
    }

    /// A sample of roughly `words` words, distinguishable from its neighbours.
    @discardableResult
    private func seed(_ store: VoiceStore, _ index: Int, words: Int = 120) throws
        -> VoiceSample {
        let body = (0..<words).map { "sample\(index)word\($0 % 30)" }.joined(separator: " ")
        // Distinct `added` stamps: the excerpt order is newest-first, and two
        // samples born in the same millisecond would sort arbitrarily.
        return try store.add(
            title: "Sample \(index)", text: body + ".",
            now: now.addingTimeInterval(Double(index)))
    }

    // MARK: - Lifecycle (voice.md §4.1)

    @Test func draftsARequestAndStoresTheResult() async throws {
        let (database, store) = try scratch()
        try seed(store, 1)
        let id = try VoiceDrafts.request(prompt: "Decline the Thursday call",
                                         database: database, now: now)
        let backend = VoiceBackend()
        let written = try await VoiceDrafter.draft(
            id: id, database: database, store: store, backend: backend, now: now)
        #expect(written == "Drafted in their voice.")
        let draft = try #require(try VoiceDrafts.draft(id: id, database: database))
        #expect(draft.status == .ready)
        #expect(draft.result == "Drafted in their voice.")
        #expect(draft.error == nil)
        #expect(!draft.isRunning)
    }

    @Test func aSecondClaimOnTheSameRequestIsASilentNoOp() async throws {
        // The normal race between the app's `--draft` launch and the hourly
        // drain. Neither may draft twice, and the loser must not error.
        let (database, store) = try scratch()
        try seed(store, 1)
        let id = try VoiceDrafts.request(prompt: "Anything", database: database, now: now)
        #expect(try VoiceDrafts.claim(id: id, database: database, now: now) != nil)
        let backend = VoiceBackend()
        let second = try await VoiceDrafter.draft(
            id: id, database: database, store: store, backend: backend, now: now)
        #expect(second == nil)
        #expect(backend.calls == 0)
    }

    @Test func aStaleClaimIsTakeable() throws {
        let (database, store) = try scratch()
        try seed(store, 1)
        let id = try VoiceDrafts.request(prompt: "Anything", database: database, now: now)
        #expect(try VoiceDrafts.claim(id: id, database: database, now: now) != nil)
        let later = now.addingTimeInterval(Double(VoiceDrafts.staleClaimMs) / 1_000 + 1)
        #expect(try VoiceDrafts.claim(id: id, database: database, now: later) != nil)
    }

    @Test func failureStampsTheRowSoTheDeskCanSayWhy() async throws {
        // The divergence from decks: a request that quietly returned to
        // `pending` would spin "Drafting…" forever with no reason on screen.
        let (database, store) = try scratch()
        try seed(store, 1)
        let id = try VoiceDrafts.request(prompt: "Anything", database: database, now: now)
        let backend = VoiceBackend(failing: true)
        await #expect(throws: LLMError.self) {
            try await VoiceDrafter.draft(
                id: id, database: database, store: store, backend: backend, now: now)
        }
        let draft = try #require(try VoiceDrafts.draft(id: id, database: database))
        #expect(draft.status == .failed)
        #expect(draft.error?.contains("scripted failure") == true)
        #expect(try VoiceDrafts.pendingIDs(database: database).isEmpty)
    }

    @Test func anEmptyCorpusFailsWithAReasonRatherThanDraftingGenerically() async throws {
        let (database, store) = try scratch()
        let id = try VoiceDrafts.request(prompt: "Anything", database: database, now: now)
        let backend = VoiceBackend()
        await #expect(throws: LLMError.self) {
            try await VoiceDrafter.draft(
                id: id, database: database, store: store, backend: backend, now: now)
        }
        #expect(backend.calls == 0)
        #expect(try VoiceDrafts.draft(id: id, database: database)?.status == .failed)
    }

    @Test func requestsAreRedactedAndHistoryIsBounded() throws {
        let (database, store) = try scratch()
        try seed(store, 1)
        _ = try VoiceDrafts.request(
            prompt: "Rewrite this: my card is 4111 1111 1111 1111",
            database: database, now: now)
        let first = try #require(try VoiceDrafts.recent(database: database).first)
        #expect(first.prompt.contains("[REDACTED:CARD]"))

        for index in 0..<(VoiceDrafts.historyLimit + 5) {
            _ = try VoiceDrafts.request(
                prompt: "Request \(index)", database: database,
                now: now.addingTimeInterval(Double(index + 1)))
        }
        #expect(try VoiceDrafts.recent(database: database, limit: 100).count
            == VoiceDrafts.historyLimit)
    }

    @Test func aCardNumberSpanningTheLengthCapIsStillRedacted() throws {
        // Redaction must run before the cut. The other way round, the cap
        // truncates the card mid-number, the leftover digits no longer match
        // the card pattern, and they land in the DB unredacted.
        let (database, _) = try scratch()
        let filler = String(repeating: "word ", count: (VoiceDrafts.maxPromptChars - 10) / 5)
        _ = try VoiceDrafts.request(
            prompt: filler + "4111 1111 1111 1111", database: database, now: now)
        let stored = try #require(try VoiceDrafts.recent(database: database).first)
        #expect(stored.prompt.count <= VoiceDrafts.maxPromptChars)
        #expect(!stored.prompt.contains("4111"))
    }

    @Test func drainPicksUpRequestsWhoseLaunchNeverHappened() async throws {
        let (database, store) = try scratch()
        try seed(store, 1)
        _ = try VoiceDrafts.request(prompt: "One", database: database, now: now)
        _ = try VoiceDrafts.request(prompt: "Two", database: database,
                                    now: now.addingTimeInterval(1))
        let backend = VoiceBackend()
        let drafted = try await VoiceDrafter.drainPending(
            database: database, store: store, backend: backend, now: now)
        #expect(drafted == 2)
        #expect(try VoiceDrafts.pendingIDs(database: database).isEmpty)
    }

    // MARK: - The prompt (voice.md §4.2)

    @Test func theRequestIsLastSoThePreambleCaches() async throws {
        // Two drafts on one corpus differ only in their request, and
        // everything above the first differing byte bills at the cache rate.
        let (database, store) = try scratch()
        for index in 1...3 { try seed(store, index) }
        let backend = VoiceBackend()
        let first = try VoiceDrafts.request(prompt: "Decline the call",
                                            database: database, now: now)
        try await VoiceDrafter.draft(id: first, database: database, store: store,
                                     backend: backend, now: now)
        let second = try VoiceDrafts.request(prompt: "Accept the call", database: database,
                                             now: now.addingTimeInterval(1))
        try await VoiceDrafter.draft(id: second, database: database, store: store,
                                     backend: backend, now: now)
        #expect(backend.prompts.count == 2)
        let shared = LLMTokens.sharedPrefixBytes(backend.prompts[0], backend.prompts[1])
        #expect(shared >= LLMTokens.cacheBlockBytes)
        // …and the difference really is only the tail.
        #expect(backend.prompts[0].hasSuffix("Decline the call"))
        #expect(backend.prompts[1].hasSuffix("Accept the call"))
    }

    @Test func measuredRulesFollowTheDescribedCard() throws {
        // The card is an opinion, the numbers are evidence; when they
        // disagree the numbers must be the last thing the model read.
        let metrics = VoiceMetrics.measure(
            [String(repeating: "The team shipped the migration on Monday. ", count: 90)])
        #expect(metrics.isMeaningful)
        let profile = VoiceProfile(
            fingerprint: "abc", sampleCount: 1, wordCount: metrics.words,
            card: "## Register\nBreezy and contracted.")
        let prompt = VoiceDrafter.prompt(
            profile: profile, metrics: metrics,
            excerpts: [VoiceExcerpts.Excerpt(title: "One", text: "Body.")],
            request: "Write something")
        let cardAt = try #require(prompt.range(of: "Breezy and contracted"))
        let rulesAt = try #require(prompt.range(of: "these win"))
        #expect(cardAt.lowerBound < rulesAt.lowerBound)
    }

    @Test func aCardlessProfileLeavesNoDanglingHeading() throws {
        // A "described" heading with nothing under it reads to a model as an
        // empty instruction, which is worse than no section at all.
        let prompt = VoiceDrafter.prompt(
            profile: nil, metrics: VoiceMetrics(),
            excerpts: [VoiceExcerpts.Excerpt(title: "One", text: "Body.")],
            request: "Write something")
        #expect(!prompt.contains("described"))
        #expect(!prompt.contains("measured"))
        #expect(prompt.contains("Samples of their writing"))
    }

    // MARK: - Budget (invariant 7)

    @Test func excerptsAreSizedByRenderedTokensNotBySampleCount() async throws {
        // A window that fits the framing and a couple of samples, not eight.
        let (database, store) = try scratch()
        for index in 1...8 { try seed(store, index, words: 400) }
        let backend = VoiceBackend(window: VoiceDrafter.responseTokens + 4_000)
        let id = try VoiceDrafts.request(prompt: "Write something",
                                         database: database, now: now)
        try await VoiceDrafter.draft(id: id, database: database, store: store,
                                     backend: backend, now: now)
        let prompt = backend.lastPrompt
        #expect(LLMTokens.estimate(prompt)
            <= backend.contextWindowTokens
                - backend.responseReserve(VoiceDrafter.responseTokens))
        #expect(prompt.contains("--- sample 1:"))
        #expect(!prompt.contains("--- sample 8:"))
    }

    @Test func aThinkingBackendsHeadroomShrinksTheExcerpts() throws {
        // `responseReserve` is the whole point: a thinking model spends
        // response budget on chain-of-thought before any content, and an
        // answer-sized reserve starves it mid-thought.
        let excerpts = (1...12).map {
            VoiceExcerpts.Excerpt(title: "Sample \($0)",
                                  text: String(repeating: "word ", count: 900))
        }
        func fitted(headroom: Int) -> Int {
            let backend = VoiceBackend(window: 40_000, headroom: headroom)
            let budget = backend.contextWindowTokens
                - backend.responseReserve(VoiceDrafter.responseTokens)
            return VoiceExcerpts.fitting(excerpts, budget: budget) {
                VoiceDrafter.prompt(profile: nil, metrics: VoiceMetrics(),
                                    excerpts: $0, request: "Write something")
            }.count
        }
        #expect(fitted(headroom: 24_000) < fitted(headroom: 0))
    }

    @Test func anExcerptTooBigForTheWindowYieldsNoneRatherThanOverflowing() {
        let huge = [VoiceExcerpts.Excerpt(title: "Novel",
                                          text: String(repeating: "word ", count: 50_000))]
        let kept = VoiceExcerpts.fitting(huge, budget: 1_000) { VoiceExcerpts.render($0) }
        #expect(kept.isEmpty)
    }

    @Test func oneLongSampleCannotBeTheWholeCorpus() throws {
        let store = try scratch().1
        try store.add(title: "Novel", text: String(repeating: "word ", count: 60_000),
                      now: now)
        let capped = VoiceExcerpts.capped(store.samples(),
                                          charCap: VoiceDrafter.excerptCharCap)
        #expect(capped.first?.text.count == VoiceDrafter.excerptCharCap)
    }
}
