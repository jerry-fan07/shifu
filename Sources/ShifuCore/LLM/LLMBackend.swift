import Foundation

/// One protocol, one production implementation (design.md §4.2): DeepSeek,
/// which lives in shifu-analyzer so no network code links into shifud, with
/// rules-only fallback when no API key is configured. The on-device tiers
/// (Apple Foundation Models, bundled MLX) were dropped in 2026-07 — too weak,
/// 4k window, macOS 26+ only. Tests supply in-memory fakes.
///
/// That verdict was re-measured 2026-07-31 against current local models and
/// no longer holds wholesale (design.md §12): Qwen3.5-9B behind the §4.2
/// local profile (16k window, thinking off, llama-server) matched DeepSeek
/// on card categories 32/36 and grouped plausibly at ledger scale on a base
/// M4. A future MLX backend belongs in shifu-analyzer as another conformer
/// of this protocol — never in ShifuCore, or its weights-loading and
/// download machinery would ride into shifud.
public protocol LLMBackend: Sendable {
    var name: String { get }
    /// Total context window (prompt + response) in tokens. Batched prompts
    /// must be chunked to fit it — see LLMTokens.estimate.
    var contextWindowTokens: Int { get }
    /// Response-side tokens callers must leave free inside the context window
    /// when sizing a prompt, when that is more than their own answer reserve.
    /// Thinking models spend response budget on chain-of-thought before any
    /// content, so an answer-sized reserve starves them mid-thought on dense
    /// prompts. Zero (the default) for answer-only models.
    var responseHeadroomTokens: Int { get }
    func complete(prompt: String, maxTokens: Int) async throws -> String
}

extension LLMBackend {
    public var contextWindowTokens: Int { 200_000 }
    public var responseHeadroomTokens: Int { 0 }

    /// The reserve to subtract from `contextWindowTokens` when sizing a
    /// prompt: the caller's own answer need or the backend's thinking
    /// headroom, whichever is larger. Every prompt-budget computation goes
    /// through this so no stage can starve a thinking model (invariant 7).
    public func responseReserve(_ answerTokens: Int) -> Int {
        max(answerTokens, responseHeadroomTokens)
    }
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

    /// Bytes two prompts share from the front — the only part of a prompt a
    /// provider's context cache can discount, since the cache is keyed on the
    /// longest byte-identical *prefix* and quantized to a block (128 tokens on
    /// DeepSeek, measured: every non-zero `cached_prompt_tokens` ever recorded
    /// is a multiple of 128, and none is smaller).
    ///
    /// Deliberately bytes rather than `estimate`: this is the one measurement
    /// where the estimator's deliberate over-count would lie in the dangerous
    /// direction. `estimate` divides by 3 while real prompts of this content
    /// measure ~3.9 bytes/token, so a 192-byte header reads as 65 "tokens" and
    /// would satisfy a token-denominated floor while the provider sees ~49 and
    /// caches nothing. `PromptPrefixTests` asserts a byte floor for that
    /// reason, and `estimate` stays what invariant 7 sizes batches with.
    public static func sharedPrefixBytes(_ first: String, _ second: String) -> Int {
        var count = 0
        var left = first.utf8.makeIterator()
        var right = second.utf8.makeIterator()
        while let lhs = left.next(), let rhs = right.next(), lhs == rhs { count += 1 }
        return count
    }

    /// A byte floor that guarantees one whole 128-token cache block even at a
    /// pessimistic 4 bytes per token. A prompt family sharing less than this
    /// is billed as if it shared nothing.
    public static let cacheBlockBytes = 512

    /// Greedy token-sized batching, shared by every batched prompt: grow a
    /// batch, render the *real* prompt, and split when the render exceeds
    /// `budget`. Sizing by the rendered prompt rather than by item count is
    /// the invariant (CLAUDE.md 7) — an item's cost is its titles and OCR
    /// text, which no fixed count can bound.
    ///
    /// An over-budget lone item still gets its own batch: splitting further is
    /// impossible, and the callers cap each item's evidence at the source.
    public static func batches<Item>(
        _ items: [Item], budget: Int, render: ([Item]) -> String
    ) -> [[Item]] {
        var result: [[Item]] = []
        var current: [Item] = []
        for item in items {
            current.append(item)
            if current.count > 1, estimate(render(current)) > budget {
                current.removeLast()
                result.append(current)
                current = [item]
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
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
