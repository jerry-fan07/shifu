import Foundation
import GRDB

/// Knowledge extraction (design.md §5.1): learning blocks (and work blocks
/// with fresh text) are scanned for candidate notes. Candidates land in the
/// inbox; nothing enters the review queue unconfirmed.
public enum KnowledgeExtractor {
    public static let batchLimit = 8
    public static let confidenceFloor = 0.5

    struct Candidate {
        var topic: String
        var note: String
        var question: String?
        var answer: String?
        var confidence: Double
    }

    static func prompt(blockText: String, app: String, url: String?) -> String {
        """
        Extract knowledge worth remembering from this screen text the user was reading
        (app: \(app)\(url.map { ", url: \($0)" } ?? "")).
        Look for: definitions, facts, how-tos, error→fix pairs, shortcuts, new terms.
        Respond with ONLY a JSON array (empty if nothing is worth keeping):
        [{"topic": "short topic", "note": "1-3 sentence markdown fact",
          "question": "optional recall question", "answer": "optional short answer",
          "confidence": 0.8}]
        Extract at most 3 candidates. Only genuinely reusable knowledge — no UI chrome,
        no navigation text, no user's own writing.

        Screen text:
        \(blockText)
        """
    }

    static func parseCandidates(_ response: String) -> [Candidate] {
        guard let start = response.firstIndex(of: "["),
              let end = response.lastIndex(of: "]"), start < end,
              let data = String(response[start...end]).data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
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

    static func note(from candidate: Candidate, activity: Activity, sourceURL: String?) -> Note {
        var body = candidate.note
        if let question = candidate.question, let answer = candidate.answer {
            body += "\n\nQ: \(question)\nA: \(answer)"
        }
        return Note(
            captured: Date(timeIntervalSince1970: Double(activity.startedAt) / 1_000),
            sourceApp: activity.appBundle.split(separator: ".").last.map(String.init),
            sourceURL: sourceURL,
            topic: candidate.topic,
            confidence: candidate.confidence,
            state: .inbox,
            body: body
        )
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
            let (text, url) = try await database.queue.read { db -> (String, String?) in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT text, url FROM observations
                    WHERE session_id = ? AND text IS NOT NULL LIMIT 4
                    """, arguments: [activityID])
                let text = rows.compactMap { $0["text"] as String? }
                    .joined(separator: "\n").prefix(2_500)
                let url = rows.compactMap { $0["url"] as String? }.first
                return (String(text), url)
            }

            // Mark processed regardless of outcome so we never re-bill a block.
            try await database.queue.write { db in
                try db.execute(sql: "UPDATE activities SET extracted = 1 WHERE id = ?",
                               arguments: [activityID])
            }
            guard text.count >= 200 else { continue }   // not enough signal

            let response = try await backend.complete(
                prompt: prompt(blockText: text, app: activity.appBundle, url: url),
                maxTokens: 1_000)
            for candidate in parseCandidates(response)
            where candidate.confidence >= confidenceFloor {
                let note = note(from: candidate, activity: activity, sourceURL: url)
                if try !vault.mergeIfDuplicate(of: note) {
                    try vault.save(note)
                    written += 1
                }
            }
        }
        return written
    }
}
