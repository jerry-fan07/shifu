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

    public struct BlockSample: Sendable {
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

    public struct Verdict: Equatable, Sendable {
        public var id: Int64
        public var category: Category
        public var confidence: Double
        public var topic: String?
    }

    // MARK: - Prompt (pure, testable)

    static func prompt(for blocks: [BlockSample]) -> String {
        let categories = Category.allCases
            .filter { $0 != .privateTime && $0 != .unclassified }
            .map(\.rawValue).joined(separator: ", ")
        var lines: [String] = [
            "Classify each screen-time block into exactly one category: \(categories).",
            "Also give a short free-text topic (3-6 words) describing what the user was doing.",
            "Respond with ONLY a JSON array, one object per block:",
            #"[{"id": 1, "category": "work", "confidence": 0.9, "topic": "debugging capture daemon"}]"#,
            "Confidence is 0-1. Use low confidence when the evidence is thin.",
            "",
            "Blocks:"
        ]
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
    /// budget, so small-window backends (Foundation Models: 4k total) never
    /// see an oversized prompt. An over-budget lone sample still gets its own
    /// batch — its text is already capped by pendingSamples.
    static func batches(_ samples: [BlockSample], promptTokenBudget: Int) -> [[BlockSample]] {
        var result: [[BlockSample]] = []
        var current: [BlockSample] = []
        for sample in samples {
            current.append(sample)
            if current.count > 1, LLMTokens.estimate(prompt(for: current)) > promptTokenBudget {
                current.removeLast()
                result.append(current)
                current = [sample]
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
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
    public static func pendingSamples(
        database: ShifuDatabase, from: Int64, to: Int64, limit: Int = batchLimit
    ) throws -> [BlockSample] {
        try database.queue.read { db in
            let activities = try Activity
                .filter(sql: "ambiguous = 1 AND source != 'llm' AND ended_at > ? AND started_at < ?",
                        arguments: [from, to])
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

        let promptBudget = max(512, backend.contextWindowTokens - responseTokenReserve)
        var updated = 0
        // Verdicts apply per batch: a mid-run failure keeps earlier updates
        // and leaves the rest ambiguous for the next run.
        for batch in batches(samples, promptTokenBudget: promptBudget) {
            let response = try await backend.complete(
                prompt: prompt(for: batch), maxTokens: responseTokenReserve)
            let batchIDs = Set(batch.map(\.id))
            let confident = parseVerdicts(response).filter {
                batchIDs.contains($0.id) && $0.confidence >= confidenceFloor
            }
            guard !confident.isEmpty else { continue }

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
                return applied
            }
        }
        return updated
    }
}
