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

/// Stage attribution (v27). `llm_usage` records what a response cost; without
/// a label it does not record what it bought, and per-stage cost has to be
/// inferred by lining rows up against the order main.swift runs its stages.
/// That inference has no chance against batching, retries, gated stages,
/// fail-soft skips, or the second analyzer process `--build-deck` starts.
@Suite struct DeepSeekStageLabelTests {
    private func backend(_ database: ShifuDatabase) -> DeepSeekBackend {
        DeepSeekBackend(
            name: "deepseek-v4-flash", apiKey: "sk-test", model: "deepseek-v4-flash",
            baseURL: DeepSeekBackend.defaultBaseURL, responseHeadroomTokens: 0,
            thinks: false, database: database)
    }

    @Test func anUnlabelledBackendCarriesNoStage() throws {
        #expect(backend(try ShifuDatabase.inMemory()).stage == nil)
    }

    @Test func labelingReturnsACopyThatKnowsItsStage() throws {
        let plain = backend(try ShifuDatabase.inMemory())
        let cards = plain.labeled("cards")
        #expect(cards.stage == "cards")
        // A copy, not a mutation: two stages share one configured backend, and
        // the second must not inherit the first's label.
        #expect(plain.stage == nil)
        #expect(plain.labeled("themes").stage == "themes")
    }

    /// The label must change nothing about what is sent — it exists to
    /// annotate the bill, not to alter the call.
    @Test func labelingDoesNotDisturbTheRequest() throws {
        let plain = backend(try ShifuDatabase.inMemory())
        let labeled = plain.labeled("cards")
        #expect(labeled.model == plain.model)
        #expect(labeled.thinks == plain.thinks)
        #expect(labeled.responseCap(prompt: "hi", maxTokens: 400)
            == plain.responseCap(prompt: "hi", maxTokens: 400))
        let plainBody = plain.requestBody(prompt: "hi", maxTokens: 400)
        let labeledBody = labeled.requestBody(prompt: "hi", maxTokens: 400)
        #expect(NSDictionary(dictionary: plainBody) == NSDictionary(dictionary: labeledBody))
    }

    /// The link that makes the column worth having: a labelled backend's
    /// recorded row is attributable, and rolls up under its own stage.
    @Test func aLabeledBackendsSpendRollsUpUnderItsStage() throws {
        let database = try ShifuDatabase.inMemory()
        let usage: [String: Any] = [
            "prompt_tokens": 1_000, "completion_tokens": 200,
            "prompt_tokens_details": ["cached_tokens": 400]
        ]
        let response: [String: Any] = ["model": "deepseek-v4-flash", "usage": usage]
        for stage in ["cards", "cards", "themes"] {
            let call = try #require(
                LLMUsage.Call.parse(response: response, requested: "deepseek-v4-flash"))
            LLMUsage.record(call, at: 500, stage: backend(database).labeled(stage).stage,
                            database: database)
        }

        let byStage = try LLMUsage.totals(
            from: 0, to: 1_000, byStage: true, database: database)
        #expect(byStage.count == 2)
        #expect(byStage.first { $0.stage == "cards" }?.calls == 2)
        #expect(byStage.first { $0.stage == "themes" }?.calls == 1)
    }
}

/// The local tier (design.md §4.2): `analysis.backend = local` builds the
/// same wire client against a self-hosted server, with no credential, one
/// model on both slots, thinking always off, and `local.context_tokens`
/// resizing every stage's batches through invariant 7. Thinking-off is what
/// makes a 16k llama-server window viable — at 16k the stock 32k thinking
/// headroom would otherwise swallow every reasoning-slot prompt budget whole.
@Suite struct DeepSeekLocalTierTests {
    private func configured(
        _ role: DeepSeekBackend.Role, settings: [String: String] = [:]
    ) throws -> DeepSeekBackend {
        let database = try ShifuDatabase.inMemory()
        try Settings.set(Settings.analysisBackendKey, to: "local", database: database)
        for (key, value) in settings {
            try Settings.set(key, to: value, database: database)
        }
        // The tier only exists in the Qwen edition (the standard bundle
        // doesn't offer the choice), so these tests run as that bundle.
        return try #require(
            try DeepSeekBackend.ifConfigured(database: database, role: role, edition: .qwen))
    }

    /// The whole point of the tier: no key, no token, and a backend still
    /// exists — the choice was the opt-in.
    @Test func theLocalTierNeedsNoKey() throws {
        for role in [DeepSeekBackend.Role.fast, .reasoning] {
            let backend = try configured(role)
            #expect(backend.baseURL == LocalLLMDefaults.baseURL)
            #expect(backend.model == LocalLLMDefaults.model)
            #expect(backend.contextWindowTokens == LocalLLMDefaults.contextWindowTokens)
        }
    }

    /// One server, one model: both slots send the same name, and naming a
    /// model applies to both — there is no second model to configure.
    @Test func oneModelServesBothSlots() throws {
        for role in [DeepSeekBackend.Role.fast, .reasoning] {
            let backend = try configured(
                role, settings: [Settings.localModelKey: "qwen3.5-4b"])
            #expect(backend.model == "qwen3.5-4b")
        }
    }

    /// Thinking stays off on both slots — no chain-of-thought requested, no
    /// headroom reserved, responses capped at what the stage asked for —
    /// whatever role the stage drew.
    @Test func neitherSlotThinksLocally() throws {
        for role in [DeepSeekBackend.Role.fast, .reasoning] {
            let backend = try configured(role)
            #expect(!backend.thinks)
            #expect(backend.responseHeadroomTokens == 0)
            #expect(backend.responseCap(prompt: "a short prompt", maxTokens: 400) == 400)
            let body = backend.requestBody(prompt: "hello", maxTokens: 400)
            #expect((body["thinking"] as? [String: String])?["type"] == "disabled")
        }
    }

    /// Meanwhile a keyed DeepSeek install is untouched by the tier's
    /// existence: 60k window, and the reasoning slot keeps its thinking and
    /// its full headroom.
    @Test func theHostedTiersKeepTheirStockShape() throws {
        let database = try ShifuDatabase.inMemory()
        try Settings.set(Settings.analysisBackendKey, to: "deepseek", database: database)
        try Settings.set(Settings.deepseekAPIKeyKey, to: "sk-test", database: database)
        // A stale local window must not leak into the hosted tiers.
        try Settings.set(Settings.localContextTokensKey, to: "16000", database: database)
        let reasoning = try #require(
            try DeepSeekBackend.ifConfigured(database: database, role: .reasoning))
        #expect(reasoning.contextWindowTokens == DeepSeekBackend.defaultContextWindowTokens)
        #expect(reasoning.thinks)
        #expect(reasoning.responseHeadroomTokens
            == DeepSeekBackend.reasoningResponseHeadroomTokens)
    }

    @Test func theContextSettingResizesBothSlots() throws {
        for role in [DeepSeekBackend.Role.fast, .reasoning] {
            let backend = try configured(
                role, settings: [Settings.localContextTokensKey: "32000"])
            #expect(backend.contextWindowTokens == 32_000)
        }
    }

    /// Clamped on read, mirroring `IntSetting.clamp`: a hand-edited row may
    /// not zero every stage's budget or claim a window no server serves.
    @Test func absurdWindowsAreClampedNotObeyed() throws {
        let range = DeepSeekBackend.contextWindowTokenRange
        for (stored, window) in [
            ("500", range.lowerBound), ("5000000", range.upperBound),
            ("not a number", LocalLLMDefaults.contextWindowTokens),
            ("", LocalLLMDefaults.contextWindowTokens)
        ] {
            let backend = try configured(
                .fast, settings: [Settings.localContextTokensKey: stored])
            #expect(backend.contextWindowTokens == window, "stored \(stored)")
        }
    }

    /// The Phase 1 bug class: a window smaller than a slot's response
    /// reserve makes `contextWindowTokens - responseReserve(…)` negative,
    /// TaskReconciler sheds its roster to 2 entries, and every `max(512, …)`
    /// stage batches degenerately. With thinking pinned off, no window a
    /// user can store may reproduce it.
    @Test func noConfiguredWindowProducesANegativePromptBudget() throws {
        for window in ["1", "8000", "12000", "16000", "60000", "200000", "99999999"] {
            for role in [DeepSeekBackend.Role.fast, .reasoning] {
                let backend = try configured(
                    role, settings: [Settings.localContextTokensKey: window])
                let budget = backend.contextWindowTokens
                    - backend.responseReserve(TaskReconciler.responseTokens)
                #expect(budget >= DeepSeekBackend.contextWindowTokenRange.lowerBound
                            - TaskReconciler.responseTokens,
                        "window \(window), \(role)")
                #expect(budget > 0, "window \(window), \(role)")
            }
        }
    }
}
