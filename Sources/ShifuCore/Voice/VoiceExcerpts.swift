import Foundation

/// Picking which of the user's writing a prompt actually carries, and sizing
/// the pick by tokens rather than by sample count (invariant 7, voice.md §4.3).
///
/// Verbatim excerpts are the strongest part of either prompt — few-shot with
/// someone's real sentences beats every description of them — so the budget is
/// spent here first and the rest of the prompt is what has to fit around it.
public enum VoiceExcerpts {
    /// One sample as a prompt sees it: the user's title, and text already cut
    /// to the caller's cap.
    public struct Excerpt: Equatable, Sendable {
        public var title: String
        public var text: String

        public init(title: String, text: String) {
            self.title = title
            self.text = text
        }
    }

    /// Samples in the order given, each cut to `charCap`. Capping per sample
    /// before the budget runs is what stops one long document from being the
    /// entire corpus the model sees.
    public static func capped(_ samples: [VoiceSample], charCap: Int) -> [Excerpt] {
        samples.map {
            Excerpt(title: $0.title, text: String($0.text.prefix(charCap)))
        }
    }

    /// The longest prefix of `excerpts` whose *rendered prompt* fits `budget`.
    ///
    /// Renders the real prompt at each step for the reason `LLMTokens.batches`
    /// does: an excerpt's cost is its text, and no count of samples bounds
    /// that. Returns empty rather than overflowing — a draft with no examples
    /// still has the measured rules, where a prompt over the window has
    /// nothing at all.
    public static func fitting(
        _ excerpts: [Excerpt], budget: Int, render: ([Excerpt]) -> String
    ) -> [Excerpt] {
        var kept: [Excerpt] = []
        for excerpt in excerpts {
            let candidate = kept + [excerpt]
            guard LLMTokens.estimate(render(candidate)) <= budget else { break }
            kept = candidate
        }
        return kept
    }

    /// How excerpts appear in both prompts. Fenced by a marker rather than by
    /// quotes so a sample containing quotation marks can't close its own
    /// block, and titled so the model can tell one piece of writing from the
    /// next instead of reading the corpus as one rambling document.
    public static func render(_ excerpts: [Excerpt]) -> String {
        excerpts.enumerated().map { index, excerpt in
            "--- sample \(index + 1): \(excerpt.title) ---\n\(excerpt.text)"
        }.joined(separator: "\n\n")
    }
}
