import Foundation

/// One protocol, one production implementation (design.md §4.2): DeepSeek,
/// which lives in shifu-analyzer so no network code links into shifud, with
/// rules-only fallback when no API key is configured. The on-device tiers
/// (Apple Foundation Models, bundled MLX) were dropped in 2026-07 — too weak,
/// 4k window, macOS 26+ only. Tests supply in-memory fakes.
public protocol LLMBackend: Sendable {
    var name: String { get }
    /// Total context window (prompt + response) in tokens. Batched prompts
    /// must be chunked to fit it — see LLMTokens.estimate.
    var contextWindowTokens: Int { get }
    func complete(prompt: String, maxTokens: Int) async throws -> String
}

extension LLMBackend {
    public var contextWindowTokens: Int { 200_000 }
}

/// Prompt sizing (CLAUDE.md invariant 7). Every batched prompt must be sized
/// with this, never by item count — the window covers prompt *and* response
/// combined, and dense OCR days can blow past any fixed item count.
public enum LLMTokens {
    /// Conservative prompt-size estimate: ≈3 UTF-8 bytes per token, so dense
    /// OCR text can't overflow a real tokenizer's count.
    public static func estimate(_ text: String) -> Int {
        text.utf8.count / 3 + 1
    }
}

/// Backend failures. Both are non-fatal by design: every analyzer stage that
/// calls an LLM catches, logs, and leaves its blocks queued for the next run,
/// so a failing model never blocks the ledger (design.md §10).
public enum LLMError: Error, CustomStringConvertible {
    case unavailable(String)
    case badResponse(String)

    public var description: String {
        switch self {
        case .unavailable(let why): return "LLM unavailable: \(why)"
        case .badResponse(let why): return "LLM bad response: \(why)"
        }
    }
}
