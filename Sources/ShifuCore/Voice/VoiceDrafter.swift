import Foundation

/// Writing one draft in the user's voice (voice.md §4). Takes an injected
/// backend, like `DeckBuilder`, so the network stays in `shifu-analyzer`
/// (invariant 1) and this stays testable with a fake.
public enum VoiceDrafter {
    /// A draft is a mail, a message, or a few paragraphs. Four thousand
    /// tokens is well over any of those, and `responseReserve` widens it
    /// further on a thinking backend.
    public static let responseTokens = 4_000
    /// Per-excerpt cut. Smaller than the profiler's: the profiler reads the
    /// corpus once to describe it, while this prompt carries excerpts *and*
    /// the card *and* the rules *and* whatever the user pasted into the
    /// request.
    public static let excerptCharCap = 4_000

    // MARK: - Prompt (pure, testable)

    /// The request goes **last** for the reason `DeckBuilder.prompt` puts its
    /// budget line there: everything above the first byte that differs between
    /// two prompts bills at the provider's cache rate, and on this desk the
    /// request is the only thing that changes between two drafts on the same
    /// corpus. A user iterating on one piece of writing re-sends an identical
    /// several-thousand-token preamble every time, and it should be cached.
    static func prompt(
        profile: VoiceProfile?, metrics: VoiceMetrics,
        excerpts: [VoiceExcerpts.Excerpt], request: String
    ) -> String {
        """
        Write a draft that reads as though one particular person wrote it themselves.
        Everything before the request at the bottom describes how that person writes.

        Rules:
        - Imitate the voice, never the content. The samples below are handwriting, not
          source material: no name, number, company, product, date or claim may cross
          from a sample into the draft.
        - Match their register, sentence rhythm and punctuation habits, including the
          ones that look like flaws. A tidier version of someone's writing is not their
          writing.
        - Respond with the draft and nothing else — no preamble, no restatement of the
          request, no explanation afterwards, no alternatives to choose between.
        - Use no headings, bullets or bold unless their own samples show them using
          those.
        - If the request needs facts you have not been given, leave an obvious short
          placeholder in square brackets rather than inventing one.
        \(describedBlock(profile))\(measuredBlock(metrics))
        Samples of their writing, most recent first:
        \(VoiceExcerpts.render(excerpts))

        Now write this, in their voice:
        \(request)
        """
    }

    private static func describedBlock(_ profile: VoiceProfile?) -> String {
        guard let profile, profile.hasCard else { return "\n" }
        return "\nHow they write, described:\n\(profile.card)\n"
    }

    /// The measured rules land *after* the described card on purpose. The card
    /// is an opinion and the numbers are evidence; when they disagree the
    /// numbers should be the last thing the model read (voice.md §3.2).
    private static func measuredBlock(_ metrics: VoiceMetrics) -> String {
        let rules = metrics.rules()
        guard !rules.isEmpty else { return "\n" }
        return "\nHow they write, measured. These are counted facts — where the "
            + "description above disagrees with them, these win:\n"
            + rules.map { "- " + $0 }.joined(separator: "\n") + "\n\n"
    }

    // MARK: - Drafting

    /// Drafts one request, if this process wins the claim. Returns nil on a
    /// lost claim — the normal race between the app's `--draft` launch and the
    /// hourly drain — and throws on a real failure, having already stamped the
    /// row `failed` so the desk can say why.
    @discardableResult
    public static func draft(
        id: Int64, database: ShifuDatabase, store: VoiceStore,
        backend: any LLMBackend, now: Date = Date()
    ) async throws -> String? {
        guard let claimed = try VoiceDrafts.claim(id: id, database: database, now: now)
        else { return nil }
        do {
            let samples = store.samples()
            guard !samples.isEmpty else {
                throw LLMError.unavailable("no writing samples to draft from")
            }
            let metrics = VoiceMetrics.measure(samples.map(\.text))
            let profile = store.profile()
            let budget = backend.contextWindowTokens - backend.responseReserve(responseTokens)
            let excerpts = VoiceExcerpts.fitting(
                VoiceExcerpts.capped(samples, charCap: excerptCharCap), budget: budget
            ) { prompt(profile: profile, metrics: metrics, excerpts: $0,
                       request: claimed.prompt) }

            let answer = try await backend.completeProse(
                prompt: prompt(profile: profile, metrics: metrics, excerpts: excerpts,
                               request: claimed.prompt),
                maxTokens: responseTokens)
            let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw LLMError.badResponse("empty draft") }
            try VoiceDrafts.complete(id: id, result: text, database: database, now: now)
            return text
        } catch {
            // Unlike a deck, this row is not handed back to the queue: someone
            // is watching it, and a silent return to `pending` would spin
            // "Drafting…" forever with no reason on screen (voice.md §4.1).
            try? VoiceDrafts.fail(id: id, error: "\(error)", database: database, now: now)
            throw error
        }
    }

    /// Every request still waiting. The safety net for a draft asked for when
    /// no backend was configured, or whose analyzer launch died before it
    /// claimed the row.
    @discardableResult
    public static func drainPending(
        database: ShifuDatabase, store: VoiceStore, backend: any LLMBackend,
        now: Date = Date()
    ) async throws -> Int {
        var written = 0
        for id in try VoiceDrafts.pendingIDs(database: database)
        where try await draft(id: id, database: database, store: store,
                              backend: backend, now: now) != nil {
            written += 1
        }
        return written
    }
}
