import Foundation

// MARK: - Narrative (LLM, optional — vault-features.md §2.1)
//
// The billable half of the compiler, split from WorkNoteCompiler.swift the
// way SemanticTaskEvidence.swift splits from its grouper: the deterministic
// compile stays there, everything that renders or spends a prompt lives here.

extension WorkNoteCompiler {
    static func prompt(taskName: String, day: String, sessions: [WorkNote.Session],
                       samples: String, tier: Tier = .light) -> String {
        let spans = sessions.map { "\($0.start)–\($0.end)" }.joined(separator: ", ")
        let bullets = """
        Summarize one day (\(day)) of work on the task "\(taskName)".
        Session times: \(spans)
        Write 1-3 markdown bullets, each formatted
        "**HH:MM–HH:MM** — what happened, what was accomplished."
        """
        guard tier == .detailed else {
            return """
            \(bullets)
            Use ONLY the screen-text samples below as evidence. Respond with ONLY the bullets.

            Screen-text samples:
            \(samples)
            """
        }
        return """
        \(bullets)
        Then, after the bullets, write a section that starts with the exact line
        "## Notes" and documents the day under these sub-headings:
        "### What was worked on" — 2-5 sentences of what the work actually was.
        "### Learned / decided" — bullets, each with the reason behind it.
        "### Problems → fixes" — bullets pairing what went wrong with what fixed it;
        omit this whole sub-heading if the day had no problems.
        Write documentation someone could read months from now to understand this day.
        No flashcards, no quiz questions.
        Use ONLY the screen-text samples below as evidence — do not invent anything
        they don't show.

        Screen-text samples:
        \(samples)
        """
    }

    /// The `## Notes` header the detailed prompt is told to emit, and the seam
    /// the response is split on.
    static let detailHeader = "\n## Notes"

    /// Splits a detailed response into its two sections. A model that ignored
    /// the header instruction has written session bullets and nothing else,
    /// which is exactly the light shape — so it degrades rather than fails.
    static func split(_ response: String) -> (sessions: String, detail: String?) {
        guard let range = response.range(of: detailHeader) else {
            return (response.trimmingCharacters(in: .whitespacesAndNewlines), nil)
        }
        let detail = response[range.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (String(response[..<range.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines),
                detail.isEmpty ? nil : detail)
    }

    /// One prompt per task-day, sized to the backend's window (invariant 7):
    /// samples are truncated rather than the day split — quality over
    /// coverage, the deterministic line 1 always exists.
    static func narrative(
        for pending: Pending, backend: any LLMBackend
    ) async throws -> (sessions: String, detail: String?) {
        var samples = pending.samples
        func render() -> String {
            prompt(taskName: pending.note.taskName, day: pending.note.day,
                   sessions: pending.note.sessions, samples: samples, tier: pending.tier)
        }
        var text = render()
        // The tier's own answer need, floored at the backend's thinking
        // headroom (`responseReserve`) so a reasoning slot can't be starved.
        while !samples.isEmpty,
              LLMTokens.estimate(text) + backend.responseReserve(pending.tier.responseTokens)
                > backend.contextWindowTokens {
            samples = String(samples.prefix(samples.count * 2 / 3))
            text = render()
        }
        let response = try await backend.complete(
            prompt: text, maxTokens: pending.tier.responseTokens)
        return split(response)
    }
}
