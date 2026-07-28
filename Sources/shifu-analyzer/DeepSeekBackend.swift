import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ShifuCore

/// DeepSeek chat-completions backend (design.md §4.2 tier 2) — the only LLM
/// backend since the on-device Foundation Models tier was dropped (4k window,
/// macOS 26+ only, weak labels). Speaks the OpenAI-compatible protocol, so
/// `deepseek.base_url`/`deepseek.model` can point at any /chat/completions
/// server. Analyzer-only: this file must never move into ShifuCore, or
/// network symbols would link into shifud (CLAUDE.md invariant 1). Only
/// post-exclusion, post-redaction text samples are ever sent, and only once
/// the user has supplied an API key — the key *is* the opt-in (§8).
///
/// Thinking models (DeepSeek reasoner-style) stream chain-of-thought into
/// `reasoning_content` before any `content`, and `max_tokens` covers both —
/// a cap sized for the answer alone truncates mid-thought and yields an empty
/// answer. So every call requests `thinkingHeadroomTokens` up front (clamped
/// to the context window): a cap, not a target — unused budget isn't billed,
/// and non-thinking models simply never use it.
struct DeepSeekBackend: LLMBackend {
    let name: String
    let apiKey: String
    let model: String
    let baseURL: String

    /// Conservative: v4 models advertise up to 1M, but 60k keeps individual
    /// batches sane and works with any OpenAI-compatible endpoint the user
    /// points the base URL at. Batching sizes prompts to it (invariant 7).
    let contextWindowTokens = 60_000

    /// The `max_tokens` floor for every call: observed reasoning runs are
    /// 2-3k tokens, so this is generous while staying inside the output limit
    /// of any OpenAI-compatible server. It still exists (rather than sending
    /// the whole window remainder) to bound a runaway reasoning loop's cost
    /// and latency.
    static let thinkingHeadroomTokens = 16_000

    static let defaultBaseURL = "https://api.deepseek.com"
    /// Two model slots, one backend. The fast slot (V4 Flash: an order of
    /// magnitude cheaper, non-reasoning, returns in seconds) serves the
    /// high-volume labeling stages; the reasoning slot (V4 Pro, a thinking
    /// model) serves the judgment-heavy grouping stages that decide what a
    /// task *is*. Either can be overridden independently in settings.
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
    }

    /// Nil when analysis is off or no key exists. No key ⇒ rules-only and
    /// nothing ever leaves the machine, so a fresh install stays local until
    /// the user pastes a key.
    static func ifConfigured(
        database: ShifuDatabase, role: Role = .fast
    ) throws -> DeepSeekBackend? {
        let backend = try Settings.get(Settings.analysisBackendKey, database: database)
        guard backend != "off" else { return nil }
        let env = ProcessInfo.processInfo.environment
        let key = try env["DEEPSEEK_API_KEY"]
            ?? Settings.get(Settings.deepseekAPIKeyKey, database: database)
        guard let key, !key.isEmpty else { return nil }
        let base = (try? Settings.get(Settings.deepseekBaseURLKey, database: database))
            .flatMap { $0.isEmpty ? nil : $0 } ?? defaultBaseURL
        let model = (try? Settings.get(role.settingsKey, database: database))
            .flatMap { $0.isEmpty ? nil : $0 } ?? role.defaultModel
        return DeepSeekBackend(
            name: model, apiKey: key, model: model,
            baseURL: base.hasSuffix("/") ? String(base.dropLast()) : base)
    }

    func complete(prompt: String, maxTokens: Int) async throws -> String {
        // Headroom for chain-of-thought on every call, clamped so prompt +
        // response still fit the context window.
        let cap = min(
            max(maxTokens, Self.thinkingHeadroomTokens),
            max(maxTokens, contextWindowTokens - LLMTokens.estimate(prompt)))
        return try await send(prompt: prompt, maxTokens: cap)
    }

    private func send(prompt: String, maxTokens: Int) async throws -> String {
        guard let url = URL(string: baseURL + "/chat/completions") else {
            throw LLMError.unavailable("bad base URL: \(baseURL)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "max_tokens": maxTokens,
            "temperature": 0.2,
            "messages": [["role": "user", "content": prompt]]
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw LLMError.badResponse("HTTP \(status): \(body.prefix(300))")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            throw LLMError.badResponse("no choices/message in response")
        }
        // Some servers return content as an array of typed parts.
        var text = message["content"] as? String
        if text == nil, let parts = message["content"] as? [[String: Any]] {
            text = parts.compactMap { $0["text"] as? String }.joined()
        }
        if let text, !text.isEmpty { return text }

        // finish_reason=length + reasoning_content but no content means even
        // the headroom cap ran out mid-thought — surfaced, not retried; the
        // stage fails soft and its blocks stay queued (§10).
        let finish = choices.first?["finish_reason"] as? String ?? "?"
        let reasoningChars = (message["reasoning_content"] as? String)?.count ?? 0
        throw LLMError.badResponse("no message content (finish_reason=\(finish), "
            + "keys=\(message.keys.sorted().joined(separator: ",")), "
            + "reasoning_content=\(reasoningChars) chars, max_tokens=\(maxTokens))")
    }
}
