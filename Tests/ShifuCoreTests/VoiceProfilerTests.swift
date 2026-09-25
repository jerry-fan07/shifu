import Foundation
import Testing
@testable import ShifuCore

/// The described half of the profile (voice.md §3.2–3.3). The claim that
/// matters most here is a *negative* one: this stage must not bill on an
/// hourly pass over a corpus nobody touched.
private final class CardBackend: LLMBackend, @unchecked Sendable {
    let name = "card"
    let contextWindowTokens = 60_000
    private let response: String
    private let lock = NSLock()
    private(set) var calls = 0

    init(response: String = "## Register\nBlunt.\n\n## Avoid\nExclamation marks.") {
        self.response = response
    }

    func complete(prompt: String, maxTokens: Int) async throws -> String {
        lock.withLock { calls += 1 }
        return response
    }
}

@Suite struct VoiceProfilerTests {
    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    private func scratch() throws -> VoiceStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shifu-profiler-test-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return VoiceStore(root: dir)
    }

    @discardableResult
    private func seed(_ store: VoiceStore, _ index: Int) throws -> VoiceSample {
        try store.add(
            title: "Sample \(index)",
            text: (0..<120).map { "sample\(index)word\($0 % 30)" }.joined(separator: " ") + ".",
            now: now.addingTimeInterval(Double(index)))
    }

    @Test func writesACardAndStampsTheCorpusItCameFrom() async throws {
        let store = try scratch()
        try seed(store, 1)
        let backend = CardBackend()
        let profile = try #require(await VoiceProfiler.rebuildIfStale(
            store: store, backend: backend, now: now))
        #expect(profile.hasCard)
        #expect(profile.card.contains("## Register"))
        #expect(profile.fingerprint == store.fingerprint())
        #expect(profile.sampleCount == 1)
        #expect(profile.wordCount > 0)
        // …and it reached disk, measurements and all.
        let loaded = try #require(store.profile())
        #expect(loaded.card == profile.card)
        #expect(!loaded.measured.isEmpty)
    }

    @Test func doesNothingWhenTheCorpusHasNotMoved() async throws {
        // Gated on the fingerprint, never on a clock: the hourly analyzer pass
        // runs this every hour, and an untouched corpus must cost nothing.
        let store = try scratch()
        try seed(store, 1)
        let backend = CardBackend()
        _ = try await VoiceProfiler.rebuildIfStale(store: store, backend: backend, now: now)
        #expect(backend.calls == 1)
        let second = try await VoiceProfiler.rebuildIfStale(
            store: store, backend: backend, now: now)
        #expect(second == nil)
        #expect(backend.calls == 1)
    }

    @Test func rebuildsOnceTheCorpusChanges() async throws {
        let store = try scratch()
        try seed(store, 1)
        let backend = CardBackend()
        _ = try await VoiceProfiler.rebuildIfStale(store: store, backend: backend, now: now)
        try seed(store, 2)
        #expect(try await VoiceProfiler.rebuildIfStale(
            store: store, backend: backend, now: now) != nil)
        #expect(backend.calls == 2)
        #expect(store.profile()?.sampleCount == 2)
    }

    @Test func anEmptyCorpusIsNotAnError() async throws {
        let store = try scratch()
        let backend = CardBackend()
        #expect(try await VoiceProfiler.rebuildIfStale(
            store: store, backend: backend, now: now) == nil)
        #expect(backend.calls == 0)
        #expect(store.profile() == nil)
    }

    @Test func anEmptyAnswerFailsRatherThanStampingTheCorpusDescribed() async throws {
        // Writing an empty card would mark the corpus described and never ask
        // again — the corpus would stay silently unprofiled forever.
        let store = try scratch()
        try seed(store, 1)
        let backend = CardBackend(response: "   \n  ")
        await #expect(throws: LLMError.self) {
            try await VoiceProfiler.rebuildIfStale(
                store: store, backend: backend, now: now)
        }
        #expect(store.profile() == nil)
    }

    @Test func unwrapsACodeFencedAnswer() {
        let fenced = "```markdown\n## Register\nBlunt.\n```"
        #expect(VoiceProfiler.unfenced(fenced) == "## Register\nBlunt.")
        #expect(VoiceProfiler.unfenced("## Register\nBlunt.") == "## Register\nBlunt.")
    }

    @Test func theProfilerPromptWithholdsStatisticsBelowTheFloor() throws {
        // Same floor the drafting prompt keeps: statistics from forty words
        // would be described back as facts about the person.
        let thin = VoiceMetrics.measure(["Short note. Two sentences only."])
        let thinPrompt = VoiceProfiler.prompt(metrics: thin, excerpts: [])
        #expect(thinPrompt.contains("too small for reliable statistics"))

        let thick = VoiceMetrics.measure(
            [String(repeating: "The team shipped the migration on Monday. ", count: 90)])
        let thickPrompt = VoiceProfiler.prompt(metrics: thick, excerpts: [])
        #expect(!thickPrompt.contains("too small for reliable statistics"))
        #expect(thickPrompt.contains("Sentence length"))
    }
}
