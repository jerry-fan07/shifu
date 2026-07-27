import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ShifuCore

/// OpenAI-compatible chat-completions backend (design.md §4.2 tier 3) —
/// DeepSeek by default, but any endpoint speaking the same protocol works
/// (OpenAI, OpenRouter, a local server). Opt-in and analyzer-only, exactly
/// like ClaudeBackend: this file must never move into ShifuCore, or network
/// symbols would link into shifud (CLAUDE.md invariant 1). Only
/// post-exclusion, post-redaction text samples are ever sent.
///
/// Thinking models (DeepSeek reasoner-style) stream chain-of-thought into
/// `reasoning_content` before any `content`, and `max_tokens` covers both —
/// a cap sized for the answer alone truncates mid-thought and yields an empty
/// answer. First time that happens the call is retried with headroom for the
/// thinking, and the lesson sticks for the rest of the run.
struct OpenAIBackend: LLMBackend {
    let name: String
    let apiKey: String
    let model: String
    let baseURL: String

    /// Conservative: DeepSeek's window is 64k; anything OpenAI-compatible
    /// offers at least this much. Batching sizes prompts to it (invariant 7).
    let contextWindowTokens = 60_000

    /// `max_tokens` for retries against a thinking model: observed reasoning
    /// runs are 2-3k tokens, so this is generous while staying far inside the
    /// context window. A cap, not a target — unused tokens aren't billed.
    static let thinkingHeadroomTokens = 16_000

    static let defaultBaseURL = "https://api.deepseek.com"
    static let defaultModel = "deepseek-chat"

    /// Flips once a response proves the model thinks; never resets within a
    /// run, so later calls skip the doomed small-cap attempt.
    private let thinking = ReasoningFlag()

    private final class ReasoningFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }

    /// Available only when the user opted in (settings) and a key exists.
    static func ifConfigured(database: ShifuDatabase) throws -> OpenAIBackend? {
        let backend = try Settings.get(Settings.analysisBackendKey, database: database)
        guard backend == "openai" else { return nil }
        let env = ProcessInfo.processInfo.environment
        let key = try env["DEEPSEEK_API_KEY"] ?? env["OPENAI_API_KEY"]
            ?? Settings.get(Settings.openAIAPIKeyKey, database: database)
        guard let key, !key.isEmpty else { return nil }
        let base = (try? Settings.get(Settings.openAIBaseURLKey, database: database))
            .flatMap { $0.isEmpty ? nil : $0 } ?? defaultBaseURL
        let model = (try? Settings.get(Settings.openAIModelKey, database: database))
            .flatMap { $0.isEmpty ? nil : $0 } ?? defaultModel
        return OpenAIBackend(
            name: model, apiKey: key, model: model,
            baseURL: base.hasSuffix("/") ? String(base.dropLast()) : base)
    }

    func complete(prompt: String, maxTokens: Int) async throws -> String {
        // Roomier cap for thinking models: headroom for the chain-of-thought,
        // clamped so prompt + response still fit the context window.
        let roomier = min(
            max(maxTokens, Self.thinkingHeadroomTokens),
            max(maxTokens, contextWindowTokens - LLMTokens.estimate(prompt)))
        if thinking.isSet {
            switch try await send(prompt: prompt, maxTokens: roomier) {
            case .text(let text): return text
            case .reasoningExhausted(let detail): throw LLMError.badResponse(detail)
            }
        }
        switch try await send(prompt: prompt, maxTokens: maxTokens) {
        case .text(let text):
            return text
        case .reasoningExhausted(let detail):
            guard roomier > maxTokens else { throw LLMError.badResponse(detail) }
            thinking.set()
            switch try await send(prompt: prompt, maxTokens: roomier) {
            case .text(let text): return text
            case .reasoningExhausted(let retryDetail):
                throw LLMError.badResponse(retryDetail)
            }
        }
    }

    private enum Outcome {
        case text(String)
        /// The token cap ran out while the model was still thinking:
        /// finish_reason=length, reasoning_content present, content empty.
        case reasoningExhausted(detail: String)
    }

    private func send(prompt: String, maxTokens: Int) async throws -> Outcome {
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
        if let text, !text.isEmpty { return .text(text) }

        let finish = choices.first?["finish_reason"] as? String ?? "?"
        let reasoningChars = (message["reasoning_content"] as? String)?.count ?? 0
        let detail = "no message content (finish_reason=\(finish), "
            + "keys=\(message.keys.sorted().joined(separator: ",")), "
            + "reasoning_content=\(reasoningChars) chars, max_tokens=\(maxTokens))"
        if finish == "length", reasoningChars > 0 {
            return .reasoningExhausted(detail: detail)
        }
        throw LLMError.badResponse(detail)
    }
}
