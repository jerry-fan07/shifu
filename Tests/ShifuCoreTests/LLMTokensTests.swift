import Foundation
import Testing
@testable import ShifuCore

/// CLAUDE.md invariant 7 at its primitive. Every batched prompt in the
/// analyzer is sized by `LLMTokens.batches`; the stage-level tests
/// (`CardBuilderTests`, `SemanticTaskGrouperTests`, `RadarTests`)
/// prove each caller uses it, and these prove it is right.
@Suite struct LLMTokensTests {
    /// A prompt that renders as a fixed preamble plus one line per item — the
    /// shape every real caller has, and the reason batching cannot be done by
    /// item count: the preamble is re-paid by every batch.
    private static func render(_ items: [String]) -> String {
        (["preamble that every batch pays for"] + items).joined(separator: "\n")
    }

    @Test func theEstimateIsConservativeForDenseText() {
        // ~3 UTF-8 bytes per token, deliberately under a real tokenizer's
        // ratio so dense OCR text cannot overflow the window.
        #expect(LLMTokens.estimate("") == 1)
        #expect(LLMTokens.estimate(String(repeating: "a", count: 300)) == 101)
        // Multi-byte text costs more, not less — bytes, not characters.
        #expect(LLMTokens.estimate("日本語") > LLMTokens.estimate("abc"))
    }

    @Test func everyBatchFitsTheBudget() {
        let items = (0..<40).map { "item-\($0) " + String(repeating: "x", count: 90) }
        let budget = 200
        let batches = LLMTokens.batches(items, budget: budget, render: Self.render)

        #expect(batches.count > 1)
        for batch in batches where batch.count > 1 {
            #expect(LLMTokens.estimate(Self.render(batch)) <= budget)
        }
    }

    @Test func everyItemIsCarriedExactlyOnceAndInOrder() {
        let items = (0..<40).map { "item-\($0) " + String(repeating: "x", count: 90) }
        let batches = LLMTokens.batches(items, budget: 200, render: Self.render)
        #expect(batches.flatMap { $0 } == items)
    }

    /// Splitting further is impossible, and the callers cap each item's
    /// evidence at the source — so an over-budget lone item still ships rather
    /// than being silently dropped.
    @Test func anOversizedLoneItemStillGetsItsOwnBatch() {
        let giant = String(repeating: "x", count: 10_000)
        let batches = LLMTokens.batches([giant], budget: 10, render: Self.render)
        #expect(batches.count == 1)
        #expect(batches[0] == [giant])
    }

    @Test func anOversizedItemNeverDragsItsNeighborsOverWithIt() {
        let giant = String(repeating: "x", count: 10_000)
        let batches = LLMTokens.batches(["small", giant, "small"], budget: 50,
                                        render: Self.render)
        #expect(batches.contains { $0 == [giant] })
        #expect(batches.flatMap { $0 }.count == 3)
    }

    @Test func everythingFittingMeansOneBatch() {
        let items = ["a", "b", "c"]
        #expect(LLMTokens.batches(items, budget: 10_000, render: Self.render) == [items])
    }

    @Test func noItemsMeansNoBatchesAndNoEmptyPrompt() {
        #expect(LLMTokens.batches([String](), budget: 100, render: Self.render).isEmpty)
    }

    @Test func aBudgetSmallerThanThePreambleStillMakesProgress() {
        let items = (0..<5).map { "item-\($0)" }
        let batches = LLMTokens.batches(items, budget: 1, render: Self.render)
        // One item per batch — never an infinite split, never a dropped item.
        #expect(batches.count == items.count)
        #expect(batches.flatMap { $0 } == items)
    }
}

/// The reserve every prompt-budget computation subtracts, so a thinking
/// backend's chain-of-thought headroom is never squeezed out by a dense batch.
@Suite struct LLMBackendReserveTests {
    private struct Backend: LLMBackend {
        var name = "fake"
        var contextWindowTokens: Int
        var responseHeadroomTokens: Int
        func complete(prompt: String, maxTokens: Int) async throws -> String { "" }
    }

    private struct PlainBackend: LLMBackend {
        var name = "plain"
        func complete(prompt: String, maxTokens: Int) async throws -> String { "" }
    }

    @Test func theReserveIsTheLargerOfTheCallersNeedAndTheBackendsHeadroom() {
        let thinking = Backend(contextWindowTokens: 60_000, responseHeadroomTokens: 8_000)
        #expect(thinking.responseReserve(1_000) == 8_000)
        #expect(thinking.responseReserve(12_000) == 12_000)
    }

    @Test func anAnswerOnlyBackendReservesExactlyWhatTheCallerAsked() {
        let answering = Backend(contextWindowTokens: 60_000, responseHeadroomTokens: 0)
        #expect(answering.responseReserve(2_500) == 2_500)
        #expect(answering.responseReserve(0) == 0)
    }

    @Test func theDefaultsAreALargeWindowAndNoThinkingHeadroom() {
        let plain = PlainBackend()
        #expect(plain.contextWindowTokens == 200_000)
        #expect(plain.responseHeadroomTokens == 0)
        #expect(plain.responseReserve(500) == 500)
    }

    @Test func backendErrorsDescribeThemselvesForTheAnalyzerLog() {
        #expect(LLMError.unavailable("no key").description.contains("no key"))
        #expect(LLMError.badResponse("not json").description.contains("not json"))
    }
}
