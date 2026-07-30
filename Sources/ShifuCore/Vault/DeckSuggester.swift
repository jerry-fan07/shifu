import Foundation
import GRDB

/// Proposes flashcard decks (design.md §5.2). Cards are user-requested now,
/// which would leave the feature entirely dependent on the user thinking to
/// ask — so once a week the analyzer looks for a task substantial enough to
/// deserve a deck and offers one, complete with two or three real sample
/// cards so the offer can be judged rather than guessed at.
///
/// Most tasks are not worth a deck, and saying so costs a call. Three caps
/// keep that honest: at most `maxPerRun` model calls per run, at most
/// `maxOpenSuggestions` proposals waiting for the user at once, and a
/// permanent `deck_suggestions` row for every verdict — including "no" — so
/// no task is ever evaluated twice.
public enum DeckSuggester {
    /// Proposals allowed to sit unanswered. Past this the suggester goes
    /// quiet: a wall of offers is noise, not help.
    public static let maxOpenSuggestions = 3
    /// Model calls per run — *not* accepted suggestions. The first weekly run
    /// against a mature ledger would otherwise bill an open-ended row of ~8k
    /// token `worth: false` probes in one pass. Unevaluated tasks simply wait
    /// for a later week; they are not going anywhere.
    public static let maxPerRun = 2
    public static let windowDays = 14
    public static let minMinutes = 45
    static let maxDayLines = 7
    static let maxBlockSamples = 12
    static let sampleChars = 1_500
    static let responseTokens = 2_500
    /// Below this a proposal isn't worth showing: the samples *are* the offer,
    /// and one card can't demonstrate a deck.
    static let minSampleCards = 2

    /// One task the suggester may evaluate, with the evidence its prompt uses.
    struct Candidate {
        var taskKey: String
        var name: String
        var gist: String?
        var focusMs: Int64
        var dayLines: [String] = []
        var samples: [String] = []
    }

    // MARK: - Prompt (pure, testable)

    static func prompt(for candidate: Candidate) -> String {
        var evidence = ["task: \"\(candidate.name)\""]
        if let gist = candidate.gist { evidence.append("what it is about: \(gist)") }
        evidence.append("time spent: \(candidate.focusMs / 60_000) minutes over "
            + "the last \(windowDays) days")
        if !candidate.dayLines.isEmpty {
            evidence.append("recent days:\n" + candidate.dayLines
                .map { "- \($0)" }.joined(separator: "\n"))
        }
        return """
        Decide whether this task is worth a spaced-repetition flashcard deck, and if so
        write two or three sample cards to show the user what the deck would be like.

        \(evidence.joined(separator: "\n"))

        A deck is worth it only when the task involves durable knowledge the user would
        genuinely want to recall months from now — a subject being learned, an API or
        tool being mastered, a domain with its own vocabulary. It is NOT worth it for
        routine execution, admin, browsing, or work whose value was the doing rather
        than anything learned. Most tasks are not worth a deck; say so.

        If it is not worth it, respond with ONLY: {"worth": false}

        If it is worth it, write cards that teach, not clippings: combine what the screen
        text shows with your own knowledge of the subject — define the terms involved,
        explain how or why it works, and add a concrete example or gotcha where you know
        one. Every question must name its subject (never "this function" or "the error
        above"), because the deck will be reviewed months from now with the screen gone.
        \(CardCandidates.latexRules())
        Respond with ONLY:
        {"worth": true,
         "title": "short deck title, the subject rather than the task's name",
         "cards": [{"topic": "short topic",
                    "note": "markdown explanation, 3-6 sentences",
                    "question": "recall question that names its subject",
                    "answer": "answer, 2-4 sentences: the direct answer plus the why",
                    "confidence": 0.8}]}

        Screen text from this task:
        \(candidate.samples.joined(separator: "\n---\n"))
        """
    }

    /// The model's verdict, already validated. `nil` means "not worth it" —
    /// which includes a malformed or too-thin `worth: true`, because a
    /// proposal the user can't judge from its samples is not a proposal.
    struct Proposal: Equatable {
        var title: String
        var samples: [DeckStore.SampleCard]
    }

    static func parse(_ response: String) -> Proposal? {
        guard let verdict = CardCandidates.verdict(response),
              (verdict["worth"] as? NSNumber)?.boolValue == true,
              let title = (verdict["title"] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty
        else { return nil }
        let cards = CardCandidates.parse(response).compactMap { candidate -> DeckStore.SampleCard? in
            guard let question = candidate.question, let answer = candidate.answer,
                  !question.isEmpty, !answer.isEmpty else { return nil }
            return DeckStore.SampleCard(topic: candidate.topic, note: candidate.note,
                                        question: question, answer: answer)
        }
        guard cards.count >= minSampleCards else { return nil }
        return Proposal(title: title, samples: cards)
    }

    // MARK: - Selection

    /// Tasks that could earn a deck, richest first. Everything cheap is
    /// decided here so a model call is only ever spent on a real contender:
    /// intent-named key (`app:`/`domain:` tasks name a container, not a
    /// subject — PatternMiner.namesIntent), enough learning/work time, that
    /// time actually *dominant* rather than incidental, and no deck or
    /// verdict on file.
    static func candidates(
        database: ShifuDatabase, now: Date = Date()
    ) throws -> [Candidate] {
        let windowStart = Int64(now.timeIntervalSince1970 * 1_000)
            - Int64(windowDays) * 86_400_000
        let spokenFor = try DeckStore.spokenForTaskKeys(database: database)
        let minMs = Int64(minMinutes) * 60_000

        return try database.queue.read { db in
            var byTask: [String: Candidate] = [:]
            var byCategory: [String: [String: Int64]] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT t.key, t.name, t.gist, a.category,
                       SUM(a.ended_at - a.started_at) AS ms
                FROM tasks t JOIN activities a ON a.task_id = t.id
                WHERE a.ended_at > ? GROUP BY t.key, a.category
                """, arguments: [windowStart]) {
                let key: String = row["key"]
                guard PatternMiner.namesIntent(taskKey: key), !spokenFor.contains(key)
                else { continue }
                let ms: Int64 = row["ms"]
                let category: String = row["category"]
                byCategory[key, default: [:]][category, default: 0] += ms
                var candidate = byTask[key]
                    ?? Candidate(taskKey: key, name: row["name"], gist: row["gist"], focusMs: 0)
                if category == Category.learning.rawValue || category == Category.work.rawValue {
                    candidate.focusMs += ms
                }
                byTask[key] = candidate
            }
            return byTask.values
                .filter { $0.focusMs >= minMs && isFocusDominant(byCategory[$0.taskKey] ?? [:]) }
                .sorted { $0.focusMs > $1.focusMs }
        }
    }

    /// True when the task's biggest single category is learning or work — the
    /// tier rule shared with the work-note compiler. A task that is mostly
    /// admin with a learning tail is not a deck.
    static func isFocusDominant(_ msByCategory: [String: Int64]) -> Bool {
        guard let dominant = msByCategory.max(by: { $0.value < $1.value })?.key else { return false }
        return dominant == Category.learning.rawValue || dominant == Category.work.rawValue
    }

    /// The day summaries and screen text a candidate is judged on.
    private static func evidence(
        for candidate: Candidate, database: ShifuDatabase
    ) throws -> Candidate {
        var filled = candidate
        try database.queue.read { db in
            filled.dayLines = try String.fetchAll(db, sql: """
                SELECT l.summary FROM task_logs l JOIN tasks t ON t.id = l.task_id
                WHERE t.key = ? ORDER BY l.day_start DESC LIMIT ?
                """, arguments: [candidate.taskKey, maxDayLines]).reversed()
            filled.samples = try String.fetchAll(db, sql: """
                SELECT o.text FROM observations o
                JOIN activities a ON a.id = o.session_id
                JOIN tasks t ON t.id = a.task_id
                WHERE t.key = ? AND o.text IS NOT NULL
                  AND a.category IN ('learning', 'work')
                ORDER BY o.started_at DESC LIMIT ?
                """, arguments: [candidate.taskKey, maxBlockSamples]
            ).map { String($0.prefix(sampleChars)) }
        }
        return filled
    }

    // MARK: - Run

    /// Evaluates up to `maxPerRun` tasks and files a row for every verdict.
    /// Returns the number of proposals now waiting for the user.
    @discardableResult
    public static func run(
        database: ShifuDatabase, backend: any LLMBackend, now: Date = Date()
    ) async throws -> Int {
        // Orphaned rows can't inflate this: the count JOINs live tasks, and
        // prune/merge clear open rows for the tasks they kill.
        let open = try DeckStore.openSuggestionCount(database: database)
        var slots = maxOpenSuggestions - open
        guard slots > 0 else { return 0 }

        var suggested = 0
        for candidate in try candidates(database: database, now: now).prefix(maxPerRun) {
            let filled = try evidence(for: candidate, database: database)
            let response = try await backend.complete(
                prompt: budgeted(filled, backend: backend), maxTokens: responseTokens)
            guard let proposal = parse(response) else {
                // A "no" is worth storing: it is what stops this task being
                // re-billed every week for the same answer.
                try DeckStore.decline(taskKey: filled.taskKey, database: database, now: now)
                continue
            }
            try DeckStore.suggest(taskKey: filled.taskKey, title: proposal.title,
                                  samples: proposal.samples, database: database, now: now)
            suggested += 1
            slots -= 1
            if slots == 0 { break }
        }
        return suggested
    }

    /// Sized to the backend's window (invariant 7): drop screen-text samples
    /// rather than fail, the day lines and task name being the evidence that
    /// matters most.
    static func budgeted(_ candidate: Candidate, backend: any LLMBackend) -> String {
        var trimmed = candidate
        var text = prompt(for: trimmed)
        while !trimmed.samples.isEmpty,
              LLMTokens.estimate(text) + backend.responseReserve(responseTokens)
                > backend.contextWindowTokens {
            trimmed.samples.removeLast()
            text = prompt(for: trimmed)
        }
        return text
    }
}
