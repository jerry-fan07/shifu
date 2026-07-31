import Foundation
import GRDB

/// Tier-2 classification (design.md §4.2): ambiguous blocks get a category and
/// topic from an LLM, batch-prompted, JSON out, confidence-gated. Low
/// confidence stays as the rules layer left it rather than guessing.
public enum AmbiguousClassifier {
    public static let confidenceFloor = 0.6
    public static let batchLimit = 20
    public static let textSampleBytes = 1_200
    public static let responseTokenReserve = 2_000
    /// How many recent topics the prompt lists as anchors, and how far back
    /// they're pulled from. Task keys only recur if topic *wording* recurs
    /// (TaskGrouper.key slugs the text), so the prompt shows the model what
    /// wording is already in play instead of letting it coin a fresh phrase
    /// per block.
    public static let maxOngoingTopics = 20
    static let ongoingTopicWindowMs: Int64 = 14 * 86_400_000
    /// Give a stubborn block a few tries at a confident verdict, then stop
    /// re-billing it until its text changes (design.md §4.2, §12). The count
    /// survives the analyzer's idempotent rebuild via LedgerBuilder's carry;
    /// a changed span resets it to zero, so genuinely new evidence retries.
    public static let maxAttempts = 3

    /// The evidence for one block, as sent to the model.
    ///
    /// Everything here has already passed the redaction choke point — it comes
    /// from `observations.text`, which `ObservationRecorder` redacted before it
    /// ever reached disk. `textSample` is additionally capped (600 bytes) so a
    /// batch stays inside a small context window.
    public struct BlockSample: Sendable {
        /// The `activities.id` this sample describes. Round-trips through the
        /// prompt as `id=` and comes back in the verdict, which is how a
        /// response is matched to its block.
        public var id: Int64
        public var appBundle: String
        public var domain: String?
        public var titles: [String]
        public var textSample: String

        public init(id: Int64, appBundle: String, domain: String?, titles: [String], textSample: String) {
            self.id = id
            self.appBundle = appBundle
            self.domain = domain
            self.titles = titles
            self.textSample = textSample
        }
    }

    /// One parsed classification from the model.
    ///
    /// A verdict is a *proposal*, not a decision. `run` discards any whose
    /// `confidence` is below `confidenceFloor`, and any whose `id` wasn't in
    /// the batch that was asked about — a hallucinated id can't reach the
    /// database. Blocks asked about but not confidently answered spend an
    /// `llm_attempts` credit instead, which is what bounds re-billing.
    public struct Verdict: Equatable, Sendable {
        public var id: Int64
        public var category: Category
        public var confidence: Double
        public var topic: String?
    }

    // MARK: - Prompt (pure, testable)

    static func prompt(for blocks: [BlockSample], ongoingTopics: [String] = []) -> String {
        let categories = Category.allCases
            .filter { $0 != .privateTime && $0 != .unclassified }
            .map(\.rawValue).joined(separator: ", ")
        var lines: [String] = [
            "Classify each screen-time block into exactly one category: \(categories).",
            "Also give a short topic (3-6 words) naming the user's ongoing task or goal",
            "(\"booking flights to tokyo\"), not the page or subject passing on screen.",
            "Respond with ONLY a JSON array, one object per block:",
            #"[{"id": 1, "category": "work", "confidence": 0.9, "topic": "debugging capture daemon"}]"#,
            "Confidence is 0-1. Use low confidence when the evidence is thin."
        ]
        if !ongoingTopics.isEmpty {
            lines.append("Ongoing tasks — when a block continues one, repeat its topic verbatim:")
            lines.append(contentsOf: ongoingTopics.map { "- \($0)" })
        }
        lines.append(contentsOf: ["", "Blocks:"])
        for block in blocks {
            var desc = "id=\(block.id) app=\(block.appBundle)"
            if let domain = block.domain { desc += " domain=\(domain)" }
            if !block.titles.isEmpty {
                desc += " titles=\(block.titles.prefix(3).joined(separator: " | "))"
            }
            lines.append(desc)
            if !block.textSample.isEmpty {
                lines.append("  text: \(block.textSample)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Splits samples into batches whose rendered prompt fits the token
    /// budget, so the backend never sees an oversized prompt however dense
    /// the day's text was (`LLMTokens.batches`; each sample's text is already
    /// capped by `pendingSamples`).
    static func batches(
        _ samples: [BlockSample], ongoingTopics: [String] = [], promptTokenBudget: Int
    ) -> [[BlockSample]] {
        LLMTokens.batches(samples, budget: promptTokenBudget) {
            prompt(for: $0, ongoingTopics: ongoingTopics)
        }
    }

    /// Distinct topics the recent ledger already carries (newest first,
    /// deduped by slug so two casings of one topic surface once). These are
    /// the prompt's anchors: the wording that must recur for the block to
    /// land in an existing task rather than mint a new one.
    public static func ongoingTopics(
        database: ShifuDatabase, before: Int64, limit: Int = maxOngoingTopics
    ) throws -> [String] {
        let rows = try database.queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT topic, MAX(ended_at) AS last_seen FROM activities
                WHERE topic IS NOT NULL AND category != 'private' AND ended_at > ?
                GROUP BY topic ORDER BY last_seen DESC LIMIT ?
                """, arguments: [before - ongoingTopicWindowMs, limit * 2])
        }
        var seenSlugs: Set<String> = []
        var topics: [String] = []
        for row in rows {
            let topic: String = row["topic"]
            let slug = TaskGrouper.slug(topic)
            guard !slug.isEmpty, seenSlugs.insert(slug).inserted else { continue }
            topics.append(topic)
            if topics.count == limit { break }
        }
        return topics
    }

    /// Parses the model's JSON (tolerating surrounding prose / code fences).
    static func parseVerdicts(_ response: String) -> [Verdict] {
        guard let start = response.firstIndex(of: "["),
              let end = response.lastIndex(of: "]"), start < end else { return [] }
        let json = String(response[start...end])
        guard let data = json.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return array.compactMap { obj in
            guard let id = (obj["id"] as? NSNumber)?.int64Value,
                  let rawCategory = obj["category"] as? String,
                  let category = Category(rawValue: rawCategory),
                  let confidence = (obj["confidence"] as? NSNumber)?.doubleValue
            else { return nil }
            return Verdict(id: id, category: category, confidence: confidence,
                           topic: obj["topic"] as? String)
        }
    }

    // MARK: - Pipeline

    /// Loads up to `batchLimit` ambiguous rules-classified activities in the
    /// window, with a text sample from their linked observations.
    ///
    /// Only *closed* blocks — ones a sessionizer gap already separates from
    /// `to` (the caller's "now"). A block still inside the gap may still grow,
    /// and LedgerBuilder carries verdicts by exact span identity: a verdict
    /// bought on a growing block is discarded when `ended_at` moves, so it
    /// would be paid for twice and describe less of the block both times.
    public static func pendingSamples(
        database: ShifuDatabase, from: Int64, to: Int64, limit: Int = batchLimit
    ) throws -> [BlockSample] {
        try database.queue.read { db in
            let activities = try Activity
                .filter(sql: """
                    ambiguous = 1 AND source != 'llm' AND llm_attempts < ?
                    AND ended_at > ? AND started_at < ? AND ended_at <= ?
                    """, arguments: [maxAttempts, from, to,
                                     to - Sessionizer.gapThresholdMs])
                .order(sql: "started_at DESC")
                .limit(limit)
                .fetchAll(db)
            return try activities.compactMap { activity in
                guard let id = activity.id else { return nil }
                let rows = try Row.fetchAll(db, sql: """
                    SELECT window_title, text FROM observations
                    WHERE session_id = ? AND text IS NOT NULL LIMIT 5
                    """, arguments: [id])
                var titles: [String] = []
                var sample = ""
                for row in rows {
                    if let title: String = row["window_title"], !titles.contains(title) {
                        titles.append(title)
                    }
                    if sample.utf8.count < textSampleBytes, let text: String = row["text"] {
                        sample += text.prefix(400) + " "
                    }
                }
                return BlockSample(
                    id: id, appBundle: activity.appBundle, domain: activity.domain,
                    titles: titles, textSample: String(sample.prefix(600))
                )
            }
        }
    }

    /// Classifies pending ambiguous blocks with the backend and applies
    /// confidence-gated verdicts. Returns how many activities were updated.
    @discardableResult
    public static func run(
        database: ShifuDatabase, backend: LLMBackend, from: Int64, to: Int64
    ) async throws -> Int {
        let samples = try pendingSamples(database: database, from: from, to: to)
        guard !samples.isEmpty else { return 0 }

        let promptBudget = max(
            512, backend.contextWindowTokens - backend.responseReserve(responseTokenReserve))
        var anchors = try ongoingTopics(database: database, before: to)
        var anchorSlugs = Set(anchors.map(TaskGrouper.slug))
        var remaining = samples[...]
        var updated = 0
        // Verdicts apply per batch: a mid-run failure keeps earlier updates
        // and leaves the rest ambiguous for the next run. Batches are cut one
        // at a time so a topic coined for an early block anchors the later
        // ones — the same effort in one window must not get two wordings.
        while !remaining.isEmpty {
            guard let batch = batches(Array(remaining), ongoingTopics: anchors,
                                      promptTokenBudget: promptBudget).first
            else { break }
            remaining = remaining.dropFirst(batch.count)
            let response = try await backend.complete(
                prompt: prompt(for: batch, ongoingTopics: anchors),
                maxTokens: responseTokenReserve)
            let batchIDs = Set(batch.map(\.id))
            let confident = parseVerdicts(response).filter {
                batchIDs.contains($0.id) && $0.confidence >= confidenceFloor
            }
            let confidentIDs = Set(confident.map(\.id))

            updated += try await database.queue.write { db in
                var applied = 0
                for verdict in confident {
                    try db.execute(sql: """
                        UPDATE activities
                        SET category = ?, topic = ?, confidence = ?, source = 'llm', ambiguous = 0
                        WHERE id = ? AND source != 'user'
                        """, arguments: [verdict.category.rawValue, verdict.topic,
                                         verdict.confidence, verdict.id])
                    applied += db.changesCount
                }
                // Blocks we asked about but couldn't confidently label spend an
                // attempt, so an unchanged low-confidence block is retried at
                // most `maxAttempts` times rather than every run (§12).
                for id in batchIDs.subtracting(confidentIDs) {
                    try db.execute(
                        sql: "UPDATE activities SET llm_attempts = llm_attempts + 1 WHERE id = ?",
                        arguments: [id])
                }
                return applied
            }
            for verdict in confident {
                guard let topic = verdict.topic else { continue }
                let slug = TaskGrouper.slug(topic)
                guard !slug.isEmpty, anchorSlugs.insert(slug).inserted else { continue }
                anchors.insert(topic, at: 0)
                if anchors.count > maxOngoingTopics { anchors.removeLast() }
            }
        }
        return updated
    }
}
