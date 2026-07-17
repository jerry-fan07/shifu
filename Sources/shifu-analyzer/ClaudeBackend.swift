import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ShifuCore

/// Claude API backend (design.md §4.2 tier 3). Opt-in, analyzer-only — this
/// file must never move into ShifuCore, or network symbols would link into
/// shifud (CLAUDE.md invariant 1). Only post-exclusion, post-redaction text
/// samples are ever sent.
struct ClaudeBackend: LLMBackend {
    let name = "claude"
    let apiKey: String
    let model: String

    static let defaultModel = "claude-opus-4-8"

    /// Available only when the user opted in (settings) and a key exists.
    static func ifConfigured(database: ShifuDatabase) throws -> ClaudeBackend? {
        let backend = try Settings.get(Settings.analysisBackendKey, database: database)
        guard backend == "claude" else { return nil }
        let key = try ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]
            ?? Settings.get(Settings.claudeAPIKeyKey, database: database)
        guard let key, !key.isEmpty else { return nil }
        let model = (try Settings.get("claude.model", database: database)) ?? defaultModel
        return ClaudeBackend(apiKey: key, model: model)
    }

    func complete(prompt: String, maxTokens: Int) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "max_tokens": maxTokens,
            "messages": [["role": "user", "content": prompt]],
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw LLMError.badResponse("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1): \(body.prefix(300))")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.badResponse("unparseable body")
        }
        // A refusal or empty content is not retryable here; surface it.
        guard let content = json["content"] as? [[String: Any]] else {
            throw LLMError.badResponse("missing content array")
        }
        let text = content.compactMap { block -> String? in
            block["type"] as? String == "text" ? block["text"] as? String : nil
        }.joined(separator: "\n")
        guard !text.isEmpty else {
            throw LLMError.badResponse("no text blocks (stop_reason: \(json["stop_reason"] ?? "?"))")
        }
        return text
    }
}
