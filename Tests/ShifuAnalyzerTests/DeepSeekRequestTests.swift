import Foundation
import ShifuCore
import Testing
@testable import shifu_analyzer

/// The request body DeepSeek is actually sent. This is the only assertion in
/// the codebase about the wire format, and it exists because the field it
/// pins was wrong for a whole release: thinking mode defaults to *enabled* on
/// both DeepSeek slots, so a body that simply omits the toggle bills the fast
/// slot's chain-of-thought as output at the full rate. Measured on 2026-07-30
/// that was 76% of a day's spend — one truncated card call emitted 16,000
/// completion tokens and returned no content at all.
///
/// `requestBody` is a pure function for exactly this reason: there is no other
/// way to observe the toggle short of a live billed call.
@Suite struct DeepSeekRequestTests {
    private func backend(_ role: DeepSeekBackend.Role) throws -> DeepSeekBackend {
        let database = try ShifuDatabase.inMemory()
        return DeepSeekBackend(
            name: role.defaultModel, apiKey: "sk-test", model: role.defaultModel,
            baseURL: DeepSeekBackend.defaultBaseURL,
            responseHeadroomTokens: role.responseHeadroomTokens,
            thinks: role.thinks, database: database)
    }

    private func thinkingType(_ body: [String: Any]) -> String? {
        (body["thinking"] as? [String: String])?["type"]
    }

    /// The bug this whole file exists for. The fast slot is a labeling model
    /// asked for ~400 tokens of JSON; its chain-of-thought is bought and
    /// billed for nothing.
    @Test func theFastSlotAsksForThinkingToBeOff() throws {
        let body = try backend(.fast).requestBody(prompt: "hello", maxTokens: 400)
        #expect(thinkingType(body) == "disabled")
    }

    /// The reasoning slot's chain-of-thought is what it is bought for, so the
    /// same field has to say so out loud rather than lean on the default —
    /// otherwise a provider flipping that default silently guts the one slot
    /// whose judgment the daily reconciliation depends on.
    @Test func theReasoningSlotAsksForThinkingToStayOn() throws {
        let body = try backend(.reasoning).requestBody(prompt: "hello", maxTokens: 400)
        #expect(thinkingType(body) == "enabled")
    }

    /// Everything else on the wire is unchanged — the toggle is an addition,
    /// not a rewrite of the protocol.
    @Test func theRestOfTheBodyIsTheOpenAIShape() throws {
        let body = try backend(.fast).requestBody(prompt: "hello", maxTokens: 400)
        #expect(body["model"] as? String == DeepSeekBackend.defaultModel)
        #expect(body["max_tokens"] as? Int == 400)
        #expect(body["temperature"] as? Double == 0.2)
        let messages = body["messages"] as? [[String: String]]
        #expect(messages?.count == 1)
        #expect(messages?.first?["role"] == "user")
        #expect(messages?.first?["content"] == "hello")
        #expect(JSONSerialization.isValidJSONObject(body))
    }

    /// The 16k floor existed to keep a thinking model from truncating
    /// mid-thought. Applied to a non-thinking slot it does nothing but hide
    /// runaway generation: a stage that asks for 400 tokens and is handed a
    /// 16,000-token allowance has no cap worth the name.
    @Test func theFastSlotIsCappedAtWhatTheStageAskedFor() throws {
        let fast = try backend(.fast)
        #expect(fast.responseCap(prompt: "a short prompt", maxTokens: 400) == 400)
    }

    @Test func theReasoningSlotKeepsItsThinkingHeadroom() throws {
        let reasoning = try backend(.reasoning)
        #expect(reasoning.responseCap(prompt: "a short prompt", maxTokens: 400)
            == DeepSeekBackend.thinkingHeadroomTokens)
    }

    /// Neither slot may promise more response than the window has left, or
    /// the call is rejected outright rather than merely truncated
    /// (CLAUDE.md invariant 7).
    @Test func neitherSlotPromisesMoreThanTheWindowHasLeft() throws {
        // ~3 bytes per token, so this prompt claims most of the 60k window.
        let huge = String(repeating: "x", count: 3 * 58_000)
        for role in [DeepSeekBackend.Role.fast, .reasoning] {
            let cap = try backend(role).responseCap(prompt: huge, maxTokens: 400)
            #expect(cap + LLMTokens.estimate(huge) <= 60_000 || cap == 400)
        }
    }
}
