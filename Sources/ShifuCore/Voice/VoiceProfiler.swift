import Foundation

/// The described half of the profile (voice.md §3.2): one LLM call that turns
/// the corpus into a short **voice card**.
///
/// It runs only when the corpus fingerprint has moved, which is what keeps an
/// hourly analyzer pass over untouched samples free. Like every LLM stage here
/// it takes an injected backend and lives in ShifuCore — nothing
/// network-shaped enters this module (invariant 1); the analyzer supplies the
/// conformer.
public enum VoiceProfiler {
    /// A voice card is five short sections. Anything longer stops being a
    /// description and starts being an essay the drafting prompt has to carry
    /// on every call.
    public static let responseTokens = 1_600
    public static let excerptCharCap = 6_000

    // MARK: - Prompt (pure, testable)

    static func prompt(metrics: VoiceMetrics, excerpts: [VoiceExcerpts.Excerpt]) -> String {
        let measured = metrics.rules()
        let measuredBlock = measured.isEmpty
            ? "(The corpus is too small for reliable statistics — describe only what you "
                + "can see in the samples, and say nothing about frequencies.)"
            : measured.map { "- " + $0 }.joined(separator: "\n")
        return """
        Describe how one person writes, from samples of their own writing, so that another
        writer could imitate them convincingly.

        Rules:
        - Describe only what the samples show. No praise, no grading, no suggestions for
          how they could write better — this is a description, not a review.
        - Name concrete, imitable habits: how they open, how they join clauses, what they
          do instead of a transition, how they end, what they do with a caveat.
        - Quote a short phrase from the samples as evidence where it makes a habit clear.
        - Nothing about who they are, what they do for a living, or what they care about.
          This describes handwriting, not the person.
        - No preamble, no closing remark.

        Respond with ONLY markdown under exactly these five headings, a few lines each:
        ## Register
        ## Sentences
        ## Structure
        ## Habits
        ## Avoid

        "Avoid" is what an imitator would get wrong — the moves this writer never makes.

        Measured statistics over these same samples. Your description must not contradict them:
        \(measuredBlock)

        Their writing:
        \(VoiceExcerpts.render(excerpts))
        """
    }

    // MARK: - Rebuild

    /// Rewrites `profile.md` when the corpus has changed under it. Returns nil
    /// when there is nothing to do — no samples, or a card already built from
    /// exactly this corpus — so the caller can stay silent rather than
    /// reporting a no-op as work.
    @discardableResult
    public static func rebuildIfStale(
        store: VoiceStore, backend: any LLMBackend, now: Date = Date()
    ) async throws -> VoiceProfile? {
        let samples = store.samples()
        guard !samples.isEmpty else { return nil }
        let current = VoiceStore.digest(of: samples)
        if let existing = store.profile(), existing.hasCard,
           !existing.isStale(against: current) { return nil }

        let metrics = VoiceMetrics.measure(samples.map(\.text))
        let budget = backend.contextWindowTokens - backend.responseReserve(responseTokens)
        let excerpts = VoiceExcerpts.fitting(
            VoiceExcerpts.capped(samples, charCap: excerptCharCap), budget: budget
        ) { prompt(metrics: metrics, excerpts: $0) }

        let answer = try await backend.completeProse(
            prompt: prompt(metrics: metrics, excerpts: excerpts), maxTokens: responseTokens)
        let card = unfenced(answer)
        // An empty answer is a failure, not an empty card: writing one would
        // stamp the corpus as described and never ask again.
        guard !card.isEmpty else { throw LLMError.badResponse("empty voice card") }

        let profile = VoiceProfile(
            built: now, fingerprint: current, sampleCount: samples.count,
            wordCount: metrics.words, card: card, measured: metrics.readings)
        try store.saveProfile(profile)
        return profile
    }

    /// Models asked for "only markdown" sometimes wrap the markdown in a code
    /// fence. Unwrap it, or the card renders as a grey block in the page and
    /// travels into the drafting prompt wearing backticks.
    static func unfenced(_ answer: String) -> String {
        var text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("```") else { return text }
        if let firstBreak = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: firstBreak)...])
        }
        if let fence = text.range(of: "```", options: .backwards) {
            text = String(text[..<fence.lowerBound])
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
