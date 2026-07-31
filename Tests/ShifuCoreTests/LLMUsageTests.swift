import Foundation
import Testing
@testable import ShifuCore

/// Token accounting (`LLMUsage`). The parsing half is tested here rather than
/// in the analyzer because that target is an executable with no test bundle —
/// which is also why `Call.parse` takes a decoded body instead of fetching one.
@Suite struct LLMUsageParsingTests {
    /// The shape DeepSeek actually answers with: both spellings of the cache
    /// split, and a `model` that may be a resolved snapshot rather than the
    /// alias that was asked for.
    private func body(
        promptTokens: Int, completionTokens: Int,
        cacheHit: Int? = nil, cachedDetail: Int? = nil, model: String? = "deepseek-v4-pro"
    ) -> [String: Any] {
        var usage: [String: Any] = [
            "prompt_tokens": promptTokens,
            "completion_tokens": completionTokens,
            "total_tokens": promptTokens + completionTokens
        ]
        if let cacheHit {
            usage["prompt_cache_hit_tokens"] = cacheHit
            usage["prompt_cache_miss_tokens"] = promptTokens - cacheHit
        }
        if let cachedDetail { usage["prompt_tokens_details"] = ["cached_tokens": cachedDetail] }
        var response: [String: Any] = ["usage": usage, "choices": []]
        if let model { response["model"] = model }
        return response
    }

    @Test func theBilledCountsComeStraightOffTheResponse() throws {
        let call = try #require(
            LLMUsage.Call.parse(response: body(promptTokens: 41_000, completionTokens: 2_500),
                                requested: "deepseek-v4-pro"))
        #expect(call.promptTokens == 41_000)
        #expect(call.completionTokens == 2_500)
        #expect(call.cachedPromptTokens == 0)
    }

    /// A cache hit bills at a fraction of a miss, so losing the split loses the
    /// cost estimate — and the escalated retry in DeepSeekBackend exists
    /// precisely because the resent prompt is discounted.
    @Test func eitherSpellingOfTheCacheSplitIsRead() throws {
        let openAIStyle = try #require(
            LLMUsage.Call.parse(
                response: body(promptTokens: 41_000, completionTokens: 100, cachedDetail: 30_000),
                requested: "deepseek-v4-pro"))
        #expect(openAIStyle.cachedPromptTokens == 30_000)

        let deepSeekStyle = try #require(
            LLMUsage.Call.parse(
                response: body(promptTokens: 41_000, completionTokens: 100, cacheHit: 12_000),
                requested: "deepseek-v4-pro"))
        #expect(deepSeekStyle.cachedPromptTokens == 12_000)
    }

    @Test func theModelOnTheInvoiceIsTheOneTheServerAnswersWith() throws {
        let resolved = try #require(
            LLMUsage.Call.parse(
                response: body(promptTokens: 10, completionTokens: 10, model: "deepseek-v4-pro-0728"),
                requested: "deepseek-v4-pro"))
        #expect(resolved.model == "deepseek-v4-pro-0728")

        let silent = try #require(
            LLMUsage.Call.parse(
                response: body(promptTokens: 10, completionTokens: 10, model: nil),
                requested: "deepseek-v4-flash"))
        #expect(silent.model == "deepseek-v4-flash")
    }

    /// No usage object means nothing was reported, which is not the same as a
    /// free call — a zero row would quietly understate the day.
    @Test func aBodyWithoutUsageRecordsNothing() {
        #expect(LLMUsage.Call.parse(response: ["choices": []], requested: "m") == nil)
    }
}

@Suite struct LLMUsageStoreTests {
    private func call(
        _ model: String, prompt: Int, cached: Int = 0, completion: Int
    ) -> LLMUsage.Call {
        LLMUsage.Call(
            model: model, promptTokens: prompt,
            cachedPromptTokens: cached, completionTokens: completion)
    }

    @Test func totalsRollUpPerModelInsideTheWindow() throws {
        let database = try ShifuDatabase.inMemory()
        let day: Int64 = 1_753_800_000_000
        LLMUsage.record(call("flash", prompt: 1_000, cached: 400, completion: 200),
                        at: day + 1_000, database: database)
        LLMUsage.record(call("flash", prompt: 2_000, cached: 0, completion: 300),
                        at: day + 2_000, database: database)
        LLMUsage.record(call("pro", prompt: 40_000, cached: 30_000, completion: 4_000),
                        at: day + 3_000, database: database)
        // Yesterday's spend must not leak into today's answer.
        LLMUsage.record(call("pro", prompt: 999_999, cached: 0, completion: 999_999),
                        at: day - 1, database: database)

        let totals = try LLMUsage.totals(
            from: day, to: day + 86_400_000, database: database)
        #expect(totals.count == 2)
        // Biggest spender first — the one worth looking at.
        #expect(totals[0].model == "pro")
        #expect(totals[0].calls == 1)
        #expect(totals[0].promptTokens == 40_000)
        #expect(totals[0].cachedPromptTokens == 30_000)
        #expect(totals[0].completionTokens == 4_000)

        #expect(totals[1].model == "flash")
        #expect(totals[1].calls == 2)
        #expect(totals[1].promptTokens == 3_000)
        #expect(totals[1].cachedPromptTokens == 400)
        #expect(totals[1].completionTokens == 500)
    }

    @Test func aWindowWithNoCallsIsEmptyRatherThanZeroes() throws {
        let database = try ShifuDatabase.inMemory()
        #expect(try LLMUsage.totals(from: 0, to: 1_000, database: database).isEmpty)
    }

    /// Every call is its own row: the same model called twice in a second is
    /// two billed responses, and a per-day counter keyed on local midnight is
    /// what strands rows when the machine changes time zone.
    @Test func repeatedCallsAccumulateRatherThanOverwrite() throws {
        let database = try ShifuDatabase.inMemory()
        for _ in 0..<5 {
            LLMUsage.record(call("flash", prompt: 100, completion: 10),
                            at: 500, database: database)
        }
        let totals = try LLMUsage.totals(from: 0, to: 1_000, database: database)
        #expect(totals.count == 1)
        #expect(totals[0].calls == 5)
        #expect(totals[0].promptTokens == 500)
    }
}
