import Foundation
import GRDB

/// Builds a requested deck's cards (design.md §5.2). The user has already
/// committed — accepting a suggestion or pressing the button on a task page
/// mints a `pending` deck — so this stage does not judge whether the deck
/// should exist. It reads the task's learning and work blocks and writes the
/// cards, kept and FSRS-seeded, that the deck was asked for.
///
/// It deliberately never touches `activities.extracted`. That flag is
/// `KnowledgeExtractor`'s high-water mark; a deck build re-reads whatever
/// blocks the task has, and consuming the flag would silently starve the
/// reference-note stage of the same blocks.
public enum DeckBuilder {
    /// Blocks per deck. Recent-first: a deck is about what the task has been
    /// lately, and forty blocks is already more evidence than any card needs.
    public static let maxBlocks = 40
    public static let blockCharCap = 6_000
    public static let responseTokens = 4_000
    public static let maxCardsPerBatch = 10
    public static let confidenceFloor = 0.5

    /// One block's screen text, as the prompt sees it.
    struct BlockText {
        var id: Int64
        var text: String
    }

    // MARK: - Prompt (pure, testable)

    static func prompt(
        title: String, taskName: String, instructions: String?,
        range: DeckStore.CardRange? = nil, written: Int = 0, blocks: [BlockText]
    ) -> String {
        let brief = instructionLines(instructions, written: written)
        return """
        Create spaced-repetition flashcards for the deck "\(title)", built from the
        user's work on the task "\(taskName)".
        \(brief)Look for: definitions, facts, how-tos, error→fix pairs, shortcuts, new terms.
        Write cards that teach, not clippings: combine what the screen text shows with
        your own knowledge of the subject — define the terms involved, explain how or
        why it works, and add a concrete example or gotcha where you know one. Every
        question must name its subject (never "this function" or "the error above"),
        because the deck will be reviewed months from now when the screen and this task
        are gone.
        \(CardCandidates.latexRules())
        Respond with ONLY a JSON array (empty if nothing is worth a card):
        [{"topic": "short topic",
          "note": "markdown explanation, 3-6 sentences: the fact plus the background needed to understand it",
          "question": "recall question that names its subject",
          "answer": "answer, 2-4 sentences: the direct answer plus the why",
          "confidence": 0.8}]
        \(budgetLine(instructions, range: range, written: written)) Only genuinely
        reusable knowledge — no UI chrome, no navigation text, no user's own writing.

        Screen text excerpts:
        \(blocks.map(\.text).joined(separator: "\n---\n"))
        """
    }

    /// The user's own brief for the deck, when one was given. One operative
    /// count, never two: the brief outranks the batch budget *by name*, and
    /// `budgetLine` yields right where the model decides how many to write —
    /// a lone precedence sentence up top loses to a concrete number beside
    /// the format spec. `written` is what earlier batches already produced,
    /// so a "3-4 cards" brief reads as a deck total rather than restarting
    /// from zero every call.
    private static func instructionLines(_ instructions: String?, written: Int) -> String {
        guard let instructions, !instructions.isEmpty else { return "" }
        var lines = """
        The user gave instructions for this deck. They outrank every other rule in
        this prompt, including the card budget below — a card count in them is a
        total for the whole deck, not a per-response target:
        \(instructions)
        """
        if written > 0 {
            lines += "\n(\(written) card\(written == 1 ? "" : "s") from earlier passes "
                + "already count toward that total; respond with an empty array if the "
                + "instructions are already satisfied.)"
        }
        return lines + "\n\n"
    }

    /// The count directive — exactly one per prompt. The user's range when
    /// one was picked (a deck total, tracked across batches; its ceiling is
    /// *also* enforced in `build`, so this line is a promise rather than a
    /// hope), the per-response ceiling otherwise, yielding to the brief
    /// either way since the brief outranks the budget by name.
    private static func budgetLine(
        _ instructions: String?, range: DeckStore.CardRange?, written: Int
    ) -> String {
        if let range {
            var line = "Write between \(range.lower) and \(range.upper) cards in "
                + "total for this deck, across every response"
            if written > 0 {
                line += " — \(written) already written in earlier responses; "
                    + "respond with an empty array once the total is met"
            }
            return line + "."
        }
        guard let instructions, !instructions.isEmpty else {
            return "Write at most \(maxCardsPerBatch) cards."
        }
        return "Write at most \(maxCardsPerBatch) cards — fewer if the user's "
            + "instructions above ask for fewer; their count wins."
    }

    // MARK: - Build

    /// Builds one deck, if this process wins the claim. Returns the number of
    /// cards written; zero is a legitimate outcome (nothing card-worthy, or a
    /// deck whose task has since been pruned) and still marks the deck ready
    /// so the drain stops retrying it.
    ///
    /// A lost claim is silent and returns nil: another analyzer already has
    /// the deck, which is the normal race between the app's `--build-deck`
    /// launch and the hourly drain.
    @discardableResult
    public static func build(
        deckKey: String, database: ShifuDatabase, vault: VaultStore,
        backend: any LLMBackend, now: Date = Date()
    ) async throws -> Int? {
        guard let claim = try DeckStore.claimForBuild(
            key: deckKey, database: database, now: now) else { return nil }
        do {
            let blocks = try blocks(taskKey: claim.taskKey, database: database)
            let taskName = try taskName(taskKey: claim.taskKey, database: database)
                ?? claim.title
            var written = 0
            for batch in batches(blocks, claim: claim, taskName: taskName, backend: backend) {
                // The range's top is enforced, not just asked for: a full
                // deck skips its remaining batches without another call.
                if let ceiling = claim.cardRange?.upper, written >= ceiling { break }
                let response = try await backend.complete(
                    prompt: prompt(title: claim.title, taskName: taskName,
                                   instructions: claim.instructions,
                                   range: claim.cardRange, written: written,
                                   blocks: batch),
                    maxTokens: responseTokens)
                written += try save(CardCandidates.parse(response), claim: claim,
                                    vault: vault,
                                    limit: claim.cardRange.map { $0.upper - written },
                                    now: now)
            }
            try DeckStore.markReady(key: deckKey, database: database, now: now)
            return written
        } catch {
            // Hand the claim back so the next drain retries; the caller logs.
            try DeckStore.releaseClaim(key: deckKey, database: database, now: now)
            throw error
        }
    }

    /// Builds every deck still waiting. The safety net for builds that never
    /// happened — the app launched the analyzer without an API key, or the
    /// process died mid-flight — so a deck can't sit "Building…" forever.
    @discardableResult
    public static func drainPending(
        database: ShifuDatabase, vault: VaultStore, backend: any LLMBackend,
        now: Date = Date()
    ) async throws -> Int {
        var built = 0
        for key in try DeckStore.pendingDeckKeys(database: database) {
            let cards = try await build(deckKey: key, database: database, vault: vault,
                                        backend: backend, now: now)
            if cards != nil { built += 1 }
        }
        return built
    }

    /// The task's most recent learning/work blocks, each text capped at the
    /// source (invariant 7) so no single block can dominate a batch.
    static func blocks(taskKey: String, database: ShifuDatabase) throws -> [BlockText] {
        try database.queue.read { db in
            let ids = try Int64.fetchAll(db, sql: """
                SELECT a.id FROM activities a JOIN tasks t ON t.id = a.task_id
                WHERE t.key = ? AND a.category IN ('learning', 'work')
                ORDER BY a.started_at DESC LIMIT ?
                """, arguments: [taskKey, maxBlocks])
            return try ids.compactMap { id in
                let texts = try String.fetchAll(db, sql: """
                    SELECT text FROM observations
                    WHERE session_id = ? AND text IS NOT NULL LIMIT 8
                    """, arguments: [id])
                guard !texts.isEmpty else { return nil }
                return BlockText(
                    id: id, text: String(texts.joined(separator: "\n").prefix(blockCharCap)))
            }
        }
    }

    /// The task's display name, or nil once the task is gone — a deck outlives
    /// its task (prune and merge delete task rows), and must still reach
    /// `ready` rather than stall the drain.
    static func taskName(taskKey: String, database: ShifuDatabase) throws -> String? {
        try database.queue.read { db in
            try String.fetchOne(db, sql: "SELECT name FROM tasks WHERE key = ?",
                                arguments: [taskKey])
        }
    }

    /// Token-sized batches, never a fixed block count (invariant 7): a block
    /// is up to 6k chars of OCR text, so a 40-block deck is one or two calls
    /// against DeepSeek's 60k window and many more against a smaller one.
    static func batches(
        _ blocks: [BlockText], claim: DeckStore.Claim, taskName: String,
        backend: any LLMBackend
    ) -> [[BlockText]] {
        LLMTokens.batches(
            blocks,
            budget: backend.contextWindowTokens - backend.responseReserve(responseTokens)
        ) {
            // Sized with a nonzero `written` so the bookkeeping line a later
            // batch carries is already inside the budget its batch was cut to.
            prompt(title: claim.title, taskName: taskName,
                   instructions: claim.instructions, range: claim.cardRange,
                   written: maxCardsPerBatch, blocks: $0)
        }
    }

    /// Writes the batch's cards. Deck-scoped dedupe (§5.2) keeps a second
    /// batch from re-filing what the first one already wrote without letting
    /// an unrelated vault note swallow a requested card. `limit` is the
    /// card range's remaining headroom — the hard half of the ceiling, for
    /// when the model overshoots the prompt's ask anyway.
    private static func save(
        _ candidates: [CardCandidates.Candidate], claim: DeckStore.Claim,
        vault: VaultStore, limit: Int? = nil, now: Date
    ) throws -> Int {
        var written = 0
        for candidate in candidates where candidate.confidence >= confidenceFloor {
            if let limit, written >= limit { break }
            guard let question = candidate.question, let answer = candidate.answer,
                  !question.isEmpty, !answer.isEmpty else { continue }
            let card = DeckStore.SampleCard(
                topic: candidate.topic, note: candidate.note,
                question: question, answer: answer)
            if try DeckStore.write(card, deckKey: claim.key, taskKey: claim.taskKey,
                                   vault: vault, confidence: candidate.confidence, now: now) {
                written += 1
            }
        }
        return written
    }
}
