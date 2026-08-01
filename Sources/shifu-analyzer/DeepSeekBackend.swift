import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ShifuCore

/// Chat-completions backend (design.md §4.2 tier 2) — one wire client for
/// every tier that speaks the OpenAI-compatible protocol: DeepSeek with the
/// user's key, the hosted Shifu Cloud proxy, or a local server the user runs
/// (`analysis.backend = local`, e.g. llama-server with Qwen). Analyzer-only:
/// this file must never move into ShifuCore, or network symbols would link
/// into shifud (CLAUDE.md invariant 1). Only post-exclusion, post-redaction
/// text samples are ever sent, and only after the user's affirmative opt-in
/// (§8) — a pasted key, or choosing the cloud or local tier outright.
///
/// Thinking mode is stated on every call and never left to the provider:
/// DeepSeek defaults it to *enabled* on both slots, so a body that merely
/// omits the toggle buys chain-of-thought for the high-volume labeling stages
/// and bills it as output at the full rate. Measured on 2026-07-30, that was
/// 76% of a day's spend — flash averaged 9,241 completion tokens on prompts
/// asking for ~400, and the two calls that ran past the cap returned no
/// content at all after four minutes.
///
/// Only the reasoning slot asks for thinking (`Role.thinks`), and only that
/// slot carries the `thinkingHeadroomTokens` floor: a thinking model streams
/// its reasoning into `reasoning_content` out of the same `max_tokens` budget
/// as its answer, so a cap sized for the answer alone truncates it mid-thought
/// and yields an empty answer. On a non-thinking slot that same floor bounds
/// nothing and only hides runaway generation.
struct DeepSeekBackend: LLMBackend {
    let name: String
    let apiKey: String
    let model: String
    let baseURL: String
    /// Nonzero only for the reasoning slot — see
    /// `reasoningResponseHeadroomTokens`.
    let responseHeadroomTokens: Int
    /// Whether this slot's chain-of-thought is worth paying for — see
    /// `Role.thinks`.
    let thinks: Bool
    /// Where billed token counts land (`LLMUsage`). This is the only place in
    /// the codebase that ever sees a provider's `usage` object, so if it isn't
    /// written here the cost of a day's analysis is gone for good.
    let database: ShifuDatabase
    /// Which analyzer stage this handle serves, stamped on every row it
    /// records — see `labeled`. Nil means unattributed, which is what the
    /// column meant for every row written before v27.
    var stage: String?

    /// Duty-cycle governor for a local endpoint — see `paced`. Nil (cloud,
    /// interactive runs) means every call fires as soon as its stage asks.
    var pacer: LLMPacer?

    /// Prompt + response budget per call. Every stage sizes its batches to
    /// it (invariant 7), so this one number is how the local tier adapts the
    /// whole pipeline: state the window the server actually serves, and
    /// every prompt shrinks to fit.
    var contextWindowTokens = DeepSeekBackend.defaultContextWindowTokens

    /// Conservative: v4 models advertise up to 1M, but 60k keeps individual
    /// batches sane and works with any OpenAI-compatible endpoint the user
    /// points the base URL at.
    static let defaultContextWindowTokens = 60_000

    /// What `local.context_tokens` may claim. Below 8k even a compact-
    /// roster grouping prompt stops fitting; 200k covers any server worth
    /// pointing the base URL at.
    static let contextWindowTokenRange = 8_000...200_000

    /// The `max_tokens` floor for a *thinking* call: observed reasoning runs
    /// are 2-3k tokens, so this is generous while staying inside the output
    /// limit of any OpenAI-compatible server. It still exists (rather than
    /// sending the whole window remainder) to bound a runaway reasoning loop's
    /// cost and latency. A run that thinks past it gets one retry at the whole
    /// window remainder (see `complete`) — escalation is the exception path,
    /// so the common case stays bounded. Non-thinking calls never take this
    /// floor: they ask for what the stage asked for.
    static let thinkingHeadroomTokens = 16_000

    /// What reasoning-slot batchers must keep free in the window
    /// (`responseHeadroomTokens`): the first-attempt cap plus an equal
    /// escalation, so even a maximal batch leaves the retry real room. Fast
    /// (non-thinking) instances report 0 and keep their batches full-width.
    static let reasoningResponseHeadroomTokens = 2 * thinkingHeadroomTokens

    static let defaultBaseURL = "https://api.deepseek.com"
    /// Two model slots, one backend. The fast slot (V4 Flash: an order of
    /// magnitude cheaper, and run with thinking off — see `Role.thinks` — so
    /// it answers in seconds) serves the high-volume labeling stages; the
    /// reasoning slot (V4 Pro, run as the thinking model it is) serves the
    /// judgment-heavy grouping stages that decide what a task *is*. Either can
    /// be overridden independently in settings.
    static let defaultModel = "deepseek-v4-flash"
    static let defaultReasoningModel = "deepseek-v4-pro"

    /// Which model slot a stage draws from — decided per call site in
    /// main.swift, not configured per stage, to keep settings minimal.
    enum Role {
        case fast, reasoning

        var settingsKey: String {
            switch self {
            case .fast: return Settings.deepseekModelKey
            case .reasoning: return Settings.deepseekReasoningModelKey
            }
        }

        var defaultModel: String {
            switch self {
            case .fast: return DeepSeekBackend.defaultModel
            case .reasoning: return DeepSeekBackend.defaultReasoningModel
            }
        }

        var responseHeadroomTokens: Int {
            switch self {
            case .fast: return 0
            case .reasoning: return DeepSeekBackend.reasoningResponseHeadroomTokens
            }
        }

        /// Whether chain-of-thought is what this slot is bought for. Stated
        /// per slot rather than inferred from `responseHeadroomTokens == 0`
        /// because it is a claim about the model, not about batch sizing, and
        /// the two only happen to coincide.
        var thinks: Bool {
            switch self {
            case .fast: return false
            case .reasoning: return true
            }
        }
    }

    /// Nil until the user has opted in (§8): pasted their own key, chosen
    /// the hosted Shifu Cloud backend (whose device token main.swift
    /// provisions before any backend is built — a still-missing token means
    /// registration failed, and the stages skip like a keyless install), or
    /// chosen the local tier. The wire protocol is identical throughout;
    /// only who holds the credentials — and whether any exist — moves.
    static func ifConfigured(
        database: ShifuDatabase, role: Role = .fast, edition: Edition = .current
    ) throws -> DeepSeekBackend? {
        let credential: String
        let base: String
        switch try Settings.llmCredential(database: database, edition: edition) {
        case nil:
            return nil
        case .deepseek(let key):
            credential = key
            base = (try? Settings.get(Settings.deepseekBaseURLKey, database: database))
                .flatMap { $0.isEmpty ? nil : $0 } ?? defaultBaseURL
        case .shifuCloud(let token):
            guard let token else { return nil }
            credential = token
            base = ShifuCloud.baseURL(database: database)
        case .localServer:
            return localServer(role: role, database: database)
        }
        let model = (try? Settings.get(role.settingsKey, database: database))
            .flatMap { $0.isEmpty ? nil : $0 } ?? role.defaultModel
        return DeepSeekBackend(
            name: model, apiKey: credential, model: model,
            baseURL: base.hasSuffix("/") ? String(base.dropLast()) : base,
            responseHeadroomTokens: role.responseHeadroomTokens,
            thinks: role.thinks, database: database)
    }

    /// The local tier: one self-hosted model serves both slots — it is one
    /// server with one model loaded, so the roles differ only in which
    /// stages call them. Thinking stays off on both: at a local-sized window
    /// the stock 32k chain-of-thought headroom would turn every
    /// reasoning-slot prompt budget negative — TaskReconciler sheds its
    /// roster to 2 entries and the `max(512, …)` stages batch degenerately.
    /// The window comes from `local.context_tokens` and resizes every
    /// stage's batches through invariant 7.
    private static func localServer(role: Role, database: ShifuDatabase) -> DeepSeekBackend {
        let base = (try? Settings.get(Settings.localBaseURLKey, database: database))
            .flatMap { $0.isEmpty ? nil : $0 } ?? LocalLLMDefaults.baseURL
        let model = (try? Settings.get(Settings.localModelKey, database: database))
            .flatMap { $0.isEmpty ? nil : $0 } ?? LocalLLMDefaults.model
        return DeepSeekBackend(
            // llama-server ignores auth; the placeholder only fills the header.
            name: model, apiKey: "local", model: model,
            baseURL: base.hasSuffix("/") ? String(base.dropLast()) : base,
            responseHeadroomTokens: 0,
            thinks: false, database: database,
            contextWindowTokens: localContextWindow(database: database))
    }

    /// `local.context_tokens`, clamped to `contextWindowTokenRange`; blank,
    /// absent or unparseable means `LocalLLMDefaults.contextWindowTokens`.
    /// Clamped on read (like `IntSetting.clamp`) so a hand-edited row can't
    /// zero every stage's budget.
    static func localContextWindow(database: ShifuDatabase) -> Int {
        guard let raw = try? Settings.get(Settings.localContextTokensKey, database: database),
              let parsed = Int(raw.trimmingCharacters(in: .whitespaces))
        else { return LocalLLMDefaults.contextWindowTokens }
        return min(max(parsed, contextWindowTokenRange.lowerBound),
                   contextWindowTokenRange.upperBound)
    }

    /// A copy of this backend that stamps `stage` on every row it records.
    ///
    /// The label rides on the handle rather than on each call because a stage
    /// holds one backend for the whole of its run — and because the obvious
    /// alternative, threading a `stage:` argument through
    /// `LLMBackend.complete`, is worse twice over: Swift forbids default
    /// arguments in protocol requirements, so it cannot be added compatibly,
    /// and every one of the protocol's conformers would have to take a
    /// parameter that only this one implementation has any use for.
    func labeled(_ stage: String) -> DeepSeekBackend {
        var copy = self
        copy.stage = stage
        return copy
    }

    /// A copy of this backend whose calls wait on `pacer` (design.md §4.2):
    /// rest before each request, sized to the one before it, so a local
    /// GPU works in bursts instead of one fan-spinning block. The actor
    /// reference rides through every later `labeled` copy, and one pacer is
    /// shared across both model slots — their calls interleave on one
    /// sequential pipeline, and the duty only means something measured over
    /// the whole stream.
    func paced(_ pacer: LLMPacer?) -> DeepSeekBackend {
        var copy = self
        copy.pacer = pacer
        return copy
    }

    /// The `max_tokens` one call asks for, clamped so prompt + response still
    /// fit the context window. Only a thinking slot takes the headroom floor;
    /// a non-thinking one asks for exactly what the stage reserved, so a card
    /// prompt written for ~400 tokens is capped near 400 and a model that
    /// starts generating without stopping is cut off rather than indulged.
    func responseCap(prompt: String, maxTokens: Int) -> Int {
        let remainder = contextWindowTokens - LLMTokens.estimate(prompt)
        let wanted = thinks ? max(maxTokens, Self.thinkingHeadroomTokens) : maxTokens
        return min(wanted, max(maxTokens, remainder))
    }

    func complete(prompt: String, maxTokens: Int) async throws -> String {
        let remainder = contextWindowTokens - LLMTokens.estimate(prompt)
        let cap = responseCap(prompt: prompt, maxTokens: maxTokens)
        do {
            return try await send(prompt: prompt, maxTokens: cap)
        } catch is ResponseTruncated where thinks && remainder > cap {
            // A thinking model thought past the cap and returned no answer.
            // One retry at the whole window remainder — batchers reserve
            // `responseHeadroomTokens`, so a reasoning-slot retry always has
            // at least another `thinkingHeadroomTokens` to grow into. Paying
            // the prompt twice beats losing the pass, and the provider's
            // context cache discounts the resent prompt.
            //
            // Deliberately not offered to the fast slot: with thinking off,
            // a labeling call that runs out of budget without emitting content
            // is a bug in the prompt or the reserve, and re-asking at a bigger
            // cap buys a second full-price answer to hide it. The two
            // escalations measured on 2026-07-30 cost 50.6% of the day and
            // produced nothing.
            do {
                return try await send(prompt: prompt, maxTokens: remainder)
            } catch let again as ResponseTruncated {
                throw LLMError.badResponse("after escalated retry: \(again.detail)")
            }
        } catch let truncated as ResponseTruncated {
            throw LLMError.badResponse(truncated.detail)
        }
    }

    /// Thrown only by `send`, for the recoverable case: the response budget
    /// ran out (finish_reason=length). Raised whether or not any `content`
    /// arrived — a truncated JSON answer is not a partial success, it is an
    /// answer no caller can parse. `complete` converts it to `LLMError` once
    /// escalation is exhausted, so it never crosses the backend boundary.
    private struct ResponseTruncated: Error {
        let detail: String
    }

    /// The JSON body of one chat-completions call. Split out of `send` so the
    /// wire format can be asserted without a live call: what this dictionary
    /// does or doesn't say about thinking mode is worth more than the rest of
    /// the bill put together, and nothing else in the process observes it.
    func requestBody(prompt: String, maxTokens: Int) -> [String: Any] {
        [
            "model": model,
            "max_tokens": maxTokens,
            "temperature": 0.2,
            // Never omitted: DeepSeek's default is `enabled` on both slots.
            "thinking": ["type": thinks ? "enabled" : "disabled"],
            "messages": [["role": "user", "content": prompt]]
        ]
    }

    private func send(prompt: String, maxTokens: Int) async throws -> String {
        guard let url = URL(string: baseURL + "/chat/completions") else {
            throw LLMError.unavailable("bad base URL: \(baseURL)")
        }
        var request = URLRequest(url: url)
        // URLSession's 60s default assumes a chatty cloud endpoint; a local
        // server prefilling a long prompt sends nothing until it finishes, so
        // the client must outwait the whole compute, not a network round trip.
        request.timeoutInterval = 600
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: requestBody(prompt: prompt, maxTokens: maxTokens))

        // Pace around the request alone: that is the span the server spends
        // computing, and the escalated retry in `complete` is a second full
        // burst that must pay its own rest. A throw records nothing — the
        // previous burst's measurement stands.
        await pacer?.willCall()
        let began = DispatchTime.now().uptimeNanoseconds
        let (data, response) = try await URLSession.shared.data(for: request)
        await pacer?.didCall(
            seconds: Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000_000)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw LLMError.badResponse("HTTP \(status): \(body.prefix(300))")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.badResponse("response body was not a JSON object")
        }
        // Before anything below can throw: an answer we can't parse was billed
        // exactly like one we can, and the truncation path above deliberately
        // pays for the prompt twice. Recording only successes would understate
        // precisely the runs that cost the most.
        if let call = LLMUsage.Call.parse(response: json, requested: model) {
            LLMUsage.record(
                call, at: Int64(Date().timeIntervalSince1970 * 1_000),
                stage: stage, database: database)
        }
        guard let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            throw LLMError.badResponse("no choices/message in response")
        }
        // Some servers return content as an array of typed parts.
        var text = message["content"] as? String
        if text == nil, let parts = message["content"] as? [[String: Any]] {
            text = parts.compactMap { $0["text"] as? String }.joined()
        }
        let finish = choices.first?["finish_reason"] as? String ?? "?"
        let reasoningChars = (message["reasoning_content"] as? String)?.count ?? 0

        // finish_reason=length means the budget ran out mid-answer, and that
        // is a failure even when some content arrived: every caller parses the
        // reply as JSON, and half an object yields no verdicts while still
        // burning each block's attempt. Returning the fragment merely because
        // it was non-empty cost 40 cards in a single batch and told nobody —
        // the stage's only log line fires on `built > 0`. Thrown typed so
        // `complete` can escalate a thinking slot; a non-thinking one surfaces
        // it, which at least leaves the blocks eligible to try again.
        if finish == "length" {
            throw ResponseTruncated(detail:
                "hit max_tokens=\(maxTokens) (content=\(text?.count ?? 0) chars, "
                + "reasoning_content=\(reasoningChars) chars)")
        }
        if let text, !text.isEmpty { return text }

        throw LLMError.badResponse(
            "no message content (finish_reason=\(finish), "
            + "keys=\(message.keys.sorted().joined(separator: ",")), "
            + "reasoning_content=\(reasoningChars) chars, max_tokens=\(maxTokens))")
    }
}
