import Foundation

/// One protocol, several implementations (implementation.md Phase 3 item 1):
/// Apple Foundation Models (on-device, OS-gated), Claude API (opt-in, lives in
/// shifu-analyzer so no network code links into shifud), rules-only fallback
/// when none is available. MLX bundled model deferred (design.md §12).
public protocol LLMBackend: Sendable {
    var name: String { get }
    func complete(prompt: String, maxTokens: Int) async throws -> String
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
