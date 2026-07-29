import Foundation
import GRDB

/// Knowledge extraction (design.md §5.1): learning blocks (and work blocks
/// with fresh text) are scanned for candidate notes. Candidates land in the
/// inbox; nothing enters the review queue unconfirmed.
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

    struct Candidate {
        var topic: String
        var note: String
        var question: String?
        var answer: String?
        var confidence: Double
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
        Create spaced-repetition flashcards from this screen text the user was reading
        (\(source.joined(separator: ", "))).\(workingLine)
        Look for: definitions, facts, how-tos, error→fix pairs, shortcuts, new terms.
        Write cards that teach, not clippings: combine what the screen shows with your
        own knowledge of the subject — define the terms involved, explain how or why it
        works, and add a concrete example or gotcha where you know one. Every card must
        stand on its own months from now, when the screen and this task are gone.
        Write every formula, variable, and symbol as LaTeX — inline as \\( ... \\),
        displayed as $$ ... $$ — never as ASCII or pasted Unicode: \\alpha not "alpha",
        \\frac{a}{b} not "a/b", \\|x\\| not "||x||", x^{2} not "x^2". Name a variable in
        prose and it still gets delimiters: "the angle \\( \\theta \\) between ...".
        Because this is JSON, every backslash must be doubled: write "\\\\frac{a}{b}".
        Respond with ONLY a JSON array (empty if nothing is worth keeping):
        [{"topic": "short topic",
          "note": "markdown explanation, 3-6 sentences: the fact plus the background needed to understand it",
          "question": "optional recall question that names its subject (never 'this function' or 'the error above')",
          "answer": "optional answer, 2-4 sentences: the direct answer plus the why",
          "confidence": 0.8}]
        Extract at most 3 candidates. Only genuinely reusable knowledge — no UI chrome,
        no navigation text, no user's own writing.

        Screen text:
        \(context.text)
        """
    }

    static func parseCandidates(_ response: String) -> [Candidate] {
        guard let start = response.firstIndex(of: "["),
              let end = response.lastIndex(of: "]"), start < end
        else { return [] }
        let raw = String(response[start...end])
        guard let array = objects(repairingLaTeXEscapes(raw)) ?? objects(raw)
        else { return [] }
        return array.compactMap { obj in
            guard let topic = obj["topic"] as? String,
                  let note = obj["note"] as? String,
                  let confidence = (obj["confidence"] as? NSNumber)?.doubleValue
            else { return nil }
            return Candidate(topic: topic, note: note,
                             question: obj["question"] as? String,
                             answer: obj["answer"] as? String,
                             confidence: confidence)
        }
    }

    private static func objects(_ json: String) -> [[String: Any]]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
    }

    /// Backslashes that open LaTeX rather than a JSON escape (§5.2). Models
    /// are asked to double them and routinely don't, and unrepaired the damage
    /// is silent: `"\(x\)"` is an invalid escape that fails the whole array —
    /// losing every candidate in the batch — while `"\frac"` parses as a
    /// formfeed and quietly eats the `f`. Only names `CardMarkup` recognises
    /// are escaped, so a genuine `\n` between sentences survives.
    static func repairingLaTeXEscapes(_ json: String) -> String {
        let chars = Array(json)
        var result = ""
        var index = 0
        while index < chars.count {
            guard chars[index] == "\\", index + 1 < chars.count else {
                result.append(chars[index])
                index += 1
                continue
            }
            let next = chars[index + 1]
            if next == "\\" {   // already a correctly escaped backslash
                result += "\\\\"
                index += 2
            } else if next.isLetter {
                var name = ""
                var cursor = index + 1
                while cursor < chars.count, chars[cursor].isLetter {
                    name.append(chars[cursor])
                    cursor += 1
                }
                if CardMarkup.isKnownCommand(name) {
                    result += "\\\\" + name
                    index = cursor
                } else {
                    result.append(chars[index])
                    index += 1
                }
            } else if latexPunctuation.contains(next) {
                result += "\\\\"
                index += 1
            } else {
                result.append(chars[index])
                index += 1
            }
        }
        return result
    }

    /// Characters a backslash can precede in LaTeX that JSON has no escape
    /// for, so seeing one means the backslash was never meant as an escape.
    private static let latexPunctuation: Set<Character> = [
        "(", ")", "[", "]", "{", "}", "|", ";", ",", "!", ":", "%", "&", "#",
        "_", "$", " "
    ]

    static func note(
        from candidate: Candidate, activity: Activity, sourceURL: String?, taskKey: String?
    ) -> Note {
        var body = candidate.note
        if let question = candidate.question, let answer = candidate.answer {
            body += "\n\nQ: \(question)\nA: \(answer)"
        }
        return Note(
            captured: Date(timeIntervalSince1970: Double(activity.startedAt) / 1_000),
            sourceApp: activity.appBundle.split(separator: ".").last.map(String.init),
            sourceURL: sourceURL,
            topic: candidate.topic,
            taskKey: taskKey,
            confidence: candidate.confidence,
            state: .inbox,
            body: body
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
            for candidate in parseCandidates(response)
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
