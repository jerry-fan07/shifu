import Foundation

/// One protocol, several implementations (implementation.md Phase 3 item 1):
/// Apple Foundation Models (on-device, OS-gated), Claude API (opt-in, lives in
/// shifu-analyzer so no network code links into shifud), rules-only fallback
/// when none is available. MLX bundled model deferred (design.md §12).
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

public enum LLMTokens {
    /// Conservative prompt-size estimate: ≈3 UTF-8 bytes per token, so dense
    /// OCR text can't overflow a real tokenizer's count.
    public static func estimate(_ text: String) -> Int {
        text.utf8.count / 3 + 1
    }
}

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
