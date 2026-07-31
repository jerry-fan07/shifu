import Foundation
import GRDB

/// One block's structured card: what the user was doing, distilled once by
/// the fast model and stored on the activity row (`activities.card`, v20).
///
/// The card is the *intermediate representation* between raw evidence and
/// every later LLM stage: grouping and clustering render `promptFacts`
/// (~40 tokens) instead of re-sampling titles and OCR text (~180 tokens),
/// so the expensive stages read a cleaner signal at a fraction of the size —
/// and the raw sampling happens exactly once per block instead of once per
/// stage per run. Like `signature` (v8), it is durable derived text that
/// outlives the 14-day raw-text retention.
public struct BlockCard: Codable, Equatable, Sendable {
    public var category: Category
    /// The user's ongoing task or goal in a few words — the same role
    /// `activities.topic` plays, and worded to reuse existing task wording.
    public var topic: String
    /// Up to 4 `kind:name` identifiers actually on screen
    /// ("repo:shifu", "file:LLMUsage.swift", "site:github.com/org/repo").
    public var entities: [String]
    /// One clause: what the user was concretely doing.
    public var gist: String

    enum CodingKeys: String, CodingKey {
        case category = "cat"
        case topic
        case entities
        case gist
    }

    public init(category: Category, topic: String, entities: [String], gist: String) {
        self.category = category
        self.topic = topic
        self.entities = entities
        self.gist = gist
    }

    /// Compact deterministic JSON — what `activities.card` holds. Sorted keys
    /// so an identical card is an identical string across runs (the rebuild
    /// carry and any prompt cache both key on bytes).
    public var json: String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) }
    }

    public static func parse(_ json: String?) -> BlockCard? {
        guard let data = json?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(BlockCard.self, from: data)
    }

    /// The card as consumer prompts render it:
    /// "stepping through AX teardown | topic=debugging capture daemon | repo:shifu".
    public var promptFacts: String {
        var parts = [gist, "topic=\(topic)"]
        if !entities.isEmpty { parts.append(entities.joined(separator: ", ")) }
        return parts.joined(separator: " | ")
    }
}

/// Tier-2 evidence pass (design.md §4.2): one fast-model call distills each
/// closed, substantial block into a `BlockCard`, and — because the card
/// carries a category — relabels the blocks the rules tier marked ambiguous
/// in the same call. This replaced `AmbiguousClassifier` as the analyzer
/// stage; a separate classification pass would bill the same evidence twice.
///
/// One shot per block, not `maxAttempts` retries of a confident answer: a
/// card is built from a *closed* block, so the evidence can never improve —
/// re-asking buys the same answer. The attempt counter only guards the
/// failure paths (unparseable answers, failed calls).
public enum CardBuilder {
    /// Same floor the classifier used: a relabel below it stays as the rules
    /// tier left it rather than guessing (design.md §4.2).
    public static let confidenceFloor = 0.6
    public static let maxAttempts = 3
    /// Candidates per run; the rest wait for the next pass.
    public static let batchLimit = 40
    /// Raw-text budget per block — the one place raw OCR still reaches a
    /// prompt hourly, so it is the amount one card is worth, not what the
    /// window can hold.
    public static let textSampleChars = 700
    public static let responseTokenReserve = 3_000
    /// Topic anchors shown so a block that continues existing work repeats
    /// its wording — task keys only recur if topic wording recurs
    /// (`TaskGrouper.key` slugs the text).
    public static let maxOngoingTopics = 20
    static let ongoingTopicWindowMs: Int64 = 14 * 86_400_000
    static let entityLimit = 4

    /// The evidence for one block. Everything here passed the redaction
    /// choke point on its way into `observations`; urls are re-redacted by
    /// `urlToken` on the way out.
    public struct BlockSample: Sendable {
        public var id: Int64
        public var appBundle: String
        public var domain: String?
        public var ambiguous: Bool
        public var titles: [String]
        public var urls: [String]
        public var textSample: String

        public init(id: Int64, appBundle: String, domain: String?, ambiguous: Bool,
                    titles: [String], urls: [String] = [], textSample: String) {
            self.id = id
            self.appBundle = appBundle
            self.domain = domain
            self.ambiguous = ambiguous
            self.titles = titles
            self.urls = urls
            self.textSample = textSample
        }
    }

    /// One parsed card proposal. Applied only when its `id` was in the batch
    /// asked about; the category relabel additionally needs `confidence`
    /// above the floor and a block still ambiguous and not user-ruled.
    public struct Verdict: Equatable, Sendable {
        public var id: Int64
        public var card: BlockCard
        public var confidence: Double
    }

    public struct Summary: Equatable, Sendable {
        public var built: Int
        public var relabeled: Int

        public init(built: Int = 0, relabeled: Int = 0) {
            self.built = built
            self.relabeled = relabeled
        }
    }

    // MARK: - Prompt (pure, testable)

    static func prompt(for blocks: [BlockSample], ongoingTopics: [String] = []) -> String {
        let categories = Category.allCases
            .filter { $0 != .privateTime && $0 != .unclassified }
            .map(\.rawValue).joined(separator: ", ")
        var lines: [String] = [
            "Distill each screen-time block into one card of what the user was doing.",
            "Card fields:",
            "- cat: exactly one of \(categories)",
            "- conf: 0-1, your confidence in cat; low when the evidence is thin",
            "- topic: the user's ongoing task or goal, 3-6 words (\"booking flights",
            "  to tokyo\") — never the page or subject passing on screen",
            "- entities: up to \(entityLimit) kind:name identifiers actually on screen",
            "  (repo:shifu, file:LLMUsage.swift, doc:Q3 roadmap, site:github.com/org/repo)",
            "- gist: one clause, what the user was concretely doing",
            "Respond with ONLY a JSON array, one object per block:",
            #"[{"id": 1, "cat": "work", "conf": 0.9, "topic": "debugging capture daemon","#,
            #"  "entities": ["repo:shifu"], "gist": "stepping through AX observer teardown"}]"#
        ]
        if !ongoingTopics.isEmpty {
            lines.append("Ongoing tasks — when a block continues one, repeat its topic verbatim:")
            lines.append(contentsOf: ongoingTopics.map { "- \($0)" })
        }
        lines.append(contentsOf: ["", "Blocks:"])
        for block in blocks {
            var desc = "id=\(block.id) app=\(SemanticTaskGrouper.shortBundle(block.appBundle))"
            if !block.urls.isEmpty {
                desc += " pages=\(block.urls.joined(separator: " | "))"
            } else if let domain = block.domain {
                desc += " domain=\(domain)"
            }
            if !block.titles.isEmpty {
                desc += " titles=\(block.titles.prefix(4).joined(separator: " | "))"
            }
            lines.append(desc)
            if !block.textSample.isEmpty {
                lines.append("  text: \(block.textSample)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Splits samples into batches whose rendered prompt fits the budget
    /// (invariant 7) — `LLMTokens.batches`, never item count.
    static func batches(
        _ samples: [BlockSample], ongoingTopics: [String] = [], promptTokenBudget: Int
    ) -> [[BlockSample]] {
        LLMTokens.batches(samples, budget: promptTokenBudget) {
            prompt(for: $0, ongoingTopics: ongoingTopics)
        }
    }

    /// Distinct topics the recent ledger already carries (newest first,
    /// deduped by slug) — the wording that must recur for a block to land in
    /// an existing task rather than mint a new one.
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

    /// Parses the model's JSON array (tolerating surrounding prose/fences).
    /// A card without a usable category, topic, or gist is dropped whole —
    /// a half-card would poison every downstream prompt that renders it.
    static func parseVerdicts(_ response: String) -> [Verdict] {
        guard let start = response.firstIndex(of: "["),
              let end = response.lastIndex(of: "]"), start < end,
              let data = String(response[start...end]).data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return array.compactMap { item in
            guard let id = (item["id"] as? NSNumber)?.int64Value,
                  let category = (item["cat"] as? String).flatMap(Category.init(rawValue:)),
                  let topic = (item["topic"] as? String)?
                      .trimmingCharacters(in: .whitespacesAndNewlines), !topic.isEmpty,
                  let gist = (item["gist"] as? String)?
                      .trimmingCharacters(in: .whitespacesAndNewlines), !gist.isEmpty
            else { return nil }
            let entities = (item["entities"] as? [String] ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .prefix(entityLimit)
                .map { String($0.prefix(60)) }
            let card = BlockCard(
                category: category, topic: String(topic.prefix(80)),
                entities: Array(entities), gist: String(gist.prefix(160)))
            return Verdict(id: id, card: card,
                           confidence: (item["conf"] as? NSNumber)?.doubleValue ?? 0)
        }
    }
}

// MARK: - Pipeline

extension CardBuilder {
    /// Card-less blocks in the window worth a card: closed (a sessionizer gap
    /// between `ended_at` and `to` — a growing block's card would die with
    /// the next rebuild's span change), a minute or more, non-private,
    /// non-system, and carrying some evidence beyond the app name.
    public static func pendingSamples(
        database: ShifuDatabase, from: Int64, to: Int64, limit: Int = batchLimit
    ) throws -> [BlockSample] {
        let denied = TaskGrouper.notSystemBundleSQL()
        return try database.queue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, app_bundle, domain, ambiguous FROM activities
                WHERE ended_at > ? AND started_at < ? AND ended_at <= ?
                  AND category != 'private'
                  AND card IS NULL AND card_attempts < ?
                  AND ended_at - started_at >= ?
                  AND \(denied.clause)
                  AND EXISTS (SELECT 1 FROM observations o
                              WHERE o.session_id = activities.id
                                AND (o.window_title IS NOT NULL OR o.text IS NOT NULL
                                     OR o.url IS NOT NULL))
                ORDER BY started_at DESC LIMIT ?
                """, arguments: [from, to, to - Sessionizer.gapThresholdMs,
                                 maxAttempts, SemanticTaskGrouper.minBlockMs]
                    + StatementArguments(denied.arguments) + [limit])
            return try rows.map { row in
                let id: Int64 = row["id"]
                let evidence = try SemanticTaskGrouper.blockEvidence(
                    db, blockID: id, textCap: textSampleChars)
                return BlockSample(
                    id: id, appBundle: row["app_bundle"], domain: row["domain"],
                    ambiguous: row["ambiguous"], titles: evidence.titles,
                    urls: evidence.urls, textSample: evidence.text)
            }
        }
    }

    /// Builds cards for the window's pending blocks. Batches are cut one at
    /// a time so a topic coined early anchors later batches (one effort, one
    /// wording); a mid-run failure keeps earlier writes and leaves the rest
    /// queued (design.md §10).
    @discardableResult
    public static func run(
        database: ShifuDatabase, backend: any LLMBackend, from: Int64, to: Int64
    ) async throws -> Summary {
        let samples = try pendingSamples(database: database, from: from, to: to)
        guard !samples.isEmpty else { return Summary() }

        let promptBudget = max(
            512, backend.contextWindowTokens - backend.responseReserve(responseTokenReserve))
        var anchors = try ongoingTopics(database: database, before: to)
        var anchorSlugs = Set(anchors.map(TaskGrouper.slug))
        var remaining = samples[...]
        var summary = Summary()
        while !remaining.isEmpty {
            guard let batch = batches(Array(remaining), ongoingTopics: anchors,
                                      promptTokenBudget: promptBudget).first
            else { break }
            remaining = remaining.dropFirst(batch.count)
            let response = try await backend.complete(
                prompt: prompt(for: batch, ongoingTopics: anchors),
                maxTokens: responseTokenReserve)
            // Dropped here, not just inside `apply`: a card for an id we didn't
            // ask about is stored nowhere, so letting its topic anchor later
            // batches would invite them to repeat wording that describes no
            // block at all — and topic wording is what `TaskGrouper.key` slugs
            // into a task key.
            let batchIDs = Set(batch.map(\.id))
            let verdicts = parseVerdicts(response).filter { batchIDs.contains($0.id) }
            let outcome = try apply(verdicts, batch: batch, database: database)
            summary.built += outcome.built
            summary.relabeled += outcome.relabeled
            for verdict in verdicts {
                let slug = TaskGrouper.slug(verdict.card.topic)
                guard !slug.isEmpty, anchorSlugs.insert(slug).inserted else { continue }
                anchors.insert(verdict.card.topic, at: 0)
                if anchors.count > maxOngoingTopics { anchors.removeLast() }
            }
        }
        return summary
    }

    /// Writes one batch: cards land on their rows; ambiguous blocks whose
    /// card clears the floor are relabeled exactly as the old classifier
    /// did (`source='llm'`, never over `source='user'`); batch ids that got
    /// no usable card burn an attempt.
    static func apply(
        _ verdicts: [Verdict], batch: [BlockSample], database: ShifuDatabase
    ) throws -> Summary {
        let batchIDs = Set(batch.map(\.id))
        let usable = verdicts.filter { batchIDs.contains($0.id) }
        return try database.queue.write { db in
            var summary = Summary()
            var cardedIDs: Set<Int64> = []
            for verdict in usable {
                guard let json = verdict.card.json else { continue }
                try db.execute(sql: "UPDATE activities SET card = ? WHERE id = ?",
                               arguments: [json, verdict.id])
                cardedIDs.insert(verdict.id)
                summary.built += 1
                guard verdict.confidence >= confidenceFloor else { continue }
                try db.execute(sql: """
                    UPDATE activities
                    SET category = ?, topic = ?, confidence = ?, source = 'llm', ambiguous = 0
                    WHERE id = ? AND ambiguous = 1 AND source != 'user'
                    """, arguments: [verdict.card.category.rawValue, verdict.card.topic,
                                     verdict.confidence, verdict.id])
                summary.relabeled += db.changesCount
            }
            for id in batchIDs.subtracting(cardedIDs) {
                try db.execute(
                    sql: "UPDATE activities SET card_attempts = card_attempts + 1 WHERE id = ?",
                    arguments: [id])
            }
            return summary
        }
    }
}
