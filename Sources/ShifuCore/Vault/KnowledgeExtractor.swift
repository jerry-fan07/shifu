import Foundation
import GRDB

/// Knowledge extraction (design.md §5.1): learning blocks (and work blocks
/// with fresh text) are scanned for reference notes worth keeping. Candidates
/// land in the inbox for triage.
///
/// This stage writes no flashcards. Cards are user-requested only now (§5.2):
/// they come from a deck, and the deck request is the confirmation. What
/// automatic extraction still earns is the *reference* half — a paragraph
/// explaining something the user read — which is worth having in the vault
/// and searchable whether or not it ever becomes a card.
public enum KnowledgeExtractor {
    public static let batchLimit = 8
    public static let confidenceFloor = 0.5

    struct BlockContext {
        var text: String
        var url: String?
        var titles: [String] = []
        var taskKey: String?
        var taskName: String?
    }

    static func prompt(context: BlockContext, app: String, topic: String?) -> String {
        var source = ["app: \(app)"]
        if let url = context.url { source.append("url: \(url)") }
        if !context.titles.isEmpty {
            source.append("windows: \(context.titles.joined(separator: " · "))")
        }
        var working = [String]()
        if let taskName = context.taskName { working.append("task: \"\(taskName)\"") }
        if let topic { working.append("topic: \(topic)") }
        let workingLine = working.isEmpty
            ? "" : "\nWhile reading, the user was working on — \(working.joined(separator: ", "))."
        return """
        Extract reference notes worth keeping from this screen text the user was reading
        (\(source.joined(separator: ", "))).\(workingLine)
        Look for: definitions, facts, how-tos, error→fix pairs, shortcuts, new terms.
        Write notes that explain, not clippings: combine what the screen shows with your
        own knowledge of the subject — define the terms involved, explain how or why it
        works, and add a concrete example or gotcha where you know one. Every note must
        stand on its own months from now, when the screen and this task are gone.
        Do not write quiz questions or flashcards — these are reference notes, not cards.
        \(CardCandidates.latexRules())
        Respond with ONLY a JSON array (empty if nothing is worth keeping):
        [{"topic": "short topic",
          "note": "markdown explanation, 3-6 sentences: the fact plus the background needed to understand it",
          "confidence": 0.8}]
        Extract at most 3 candidates. Only genuinely reusable knowledge — no UI chrome,
        no navigation text, no user's own writing.

        Screen text:
        \(context.text)
        """
    }

    /// The note is the candidate's explanation and nothing else. Any `question`
    /// or `answer` a model volunteers anyway is dropped rather than appended:
    /// a `Q:`/`A:` pair here would put an unrequested card in the review queue,
    /// which is exactly what §5.2 took away.
    static func note(
        from candidate: CardCandidates.Candidate, activity: Activity,
        sourceURL: String?, taskKey: String?
    ) -> Note {
        Note(
            captured: Date(timeIntervalSince1970: Double(activity.startedAt) / 1_000),
            sourceApp: activity.appBundle.split(separator: ".").last.map(String.init),
            sourceURL: sourceURL,
            topic: candidate.topic,
            taskKey: taskKey,
            confidence: candidate.confidence,
            state: .inbox,
            body: candidate.note
        )
    }

    /// The block's redacted text sample, first URL, window titles, and task.
    /// TaskGrouper runs before extraction (vault-features.md §3), so the source
    /// activity's task exists to stamp into new notes (§2.3) and to name in the
    /// prompt. The 8-row / 6k-char cap bounds the prompt at the source
    /// (CLAUDE.md invariant 7): ~2k estimated tokens against DeepSeek's 60k.
    private static func blockContext(
        for activityID: Int64, database: ShifuDatabase
    ) async throws -> BlockContext {
        try await database.queue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT text, url, window_title FROM observations
                WHERE session_id = ? AND text IS NOT NULL LIMIT 8
                """, arguments: [activityID])
            let text = rows.compactMap { $0["text"] as String? }
                .joined(separator: "\n").prefix(6_000)
            var titles = [String]()
            for title in rows.compactMap({ $0["window_title"] as String? })
            where !title.isEmpty && !titles.contains(title) {
                titles.append(title)
            }
            let task = try Row.fetchOne(db, sql: """
                SELECT t.key, t.name FROM tasks t
                JOIN activities a ON a.task_id = t.id WHERE a.id = ?
                """, arguments: [activityID])
            return BlockContext(
                text: String(text),
                url: rows.compactMap { $0["url"] as String? }.first,
                titles: Array(titles.prefix(3)),
                taskKey: task?["key"],
                taskName: task?["name"])
        }
    }

    /// Runs extraction over unprocessed learning/novel-work blocks in the
    /// window. Returns the number of new inbox candidates written.
    @discardableResult
    public static func run(
        database: ShifuDatabase, vault: VaultStore, backend: LLMBackend,
        from: Int64, to: Int64
    ) async throws -> Int {
        // Learning blocks always qualify; work blocks only when they carry text.
        let targets = try await database.queue.read { db in
            try Activity
                .filter(sql: """
                    extracted = 0 AND ended_at > ? AND started_at < ?
                    AND category IN ('learning', 'work')
                    AND (ended_at - started_at) >= 180000
                    """, arguments: [from, to])
                .order(sql: "started_at DESC")
                .limit(batchLimit)
                .fetchAll(db)
        }
        guard !targets.isEmpty else { return 0 }

        var written = 0
        for activity in targets {
            guard let activityID = activity.id else { continue }
            let context = try await blockContext(for: activityID, database: database)

            // Mark processed regardless of outcome so we never re-bill a block.
            try await database.queue.write { db in
                try db.execute(sql: "UPDATE activities SET extracted = 1 WHERE id = ?",
                               arguments: [activityID])
            }
            guard context.text.count >= 200 else { continue }   // not enough signal

            let response = try await backend.complete(
                prompt: prompt(context: context, app: activity.appBundle,
                               topic: activity.topic),
                maxTokens: 2_000)
            for candidate in CardCandidates.parse(response)
            where candidate.confidence >= confidenceFloor {
                let note = note(from: candidate, activity: activity,
                                sourceURL: context.url, taskKey: context.taskKey)
                if try !vault.mergeIfDuplicate(of: note) {
                    try vault.save(note)
                    written += 1
                }
            }
        }
        return written
    }
}
