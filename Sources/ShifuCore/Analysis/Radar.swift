import Foundation
import GRDB

/// A ranked automation suggestion (design.md §6.2).
public struct Suggestion: Codable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "suggestions"

    public var id: Int64?
    public var createdAt: Int64
    public var patternKey: String
    public var kind: String
    public var evidence: String
    public var occurrences: Int
    public var avgMinutes: Double
    public var estMinutesSavedWeekly: Double
    public var title: String?
    public var suggestion: String?
    public var confidence: Double?
    public var status: String                 // new | dismissed | snoozed
    public var dismissedAtOccurrences: Int?
    public var snoozedUntil: Int64?

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt = "created_at"
        case patternKey = "pattern_key"
        case kind
        case evidence
        case occurrences
        case avgMinutes = "avg_minutes"
        case estMinutesSavedWeekly = "est_minutes_saved_weekly"
        case title
        case suggestion
        case confidence
        case status
        case dismissedAtOccurrences = "dismissed_at_occurrences"
        case snoozedUntil = "snoozed_until"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    /// Rank: estimated time saved × confidence (§6.2).
    public var score: Double { estMinutesSavedWeekly * (confidence ?? 0.5) }

    /// The v1 "Draft it" action: a well-formed prompt describing the workflow,
    /// ready to paste into Claude Code (§6.2).
    public var automationPrompt: String {
        """
        I have a repetitive workflow I'd like to automate.

        Pattern: \(title ?? patternKey)
        Evidence: \(evidence)
        \(suggestion.map { "Analysis: \($0)" } ?? "")

        Please figure out how to automate this — a script, a scheduled job, or a
        small tool. Ask me about the specifics of the data sources involved, then
        build it.
        """
    }
}

/// The radar pipeline: mine → upsert (with dismissal memory) → describe.
public enum Radar {
    /// Upserts mined patterns. Dismissed patterns stay dismissed unless their
    /// frequency doubles (§6.2); snoozes expire by timestamp.
    @discardableResult
    public static func upsert(
        patterns: [PatternMiner.Pattern], database: ShifuDatabase, now: Date = Date()
    ) throws -> Int {
        let nowMs = Int64(now.timeIntervalSince1970 * 1_000)
        return try database.queue.write { db in
            var changed = 0
            for pattern in patterns {
                if var existing = try Suggestion
                    .filter(Column("pattern_key") == pattern.key).fetchOne(db) {
                    existing.occurrences = pattern.occurrences
                    existing.evidence = pattern.evidence
                    existing.avgMinutes = pattern.avgMinutes
                    existing.estMinutesSavedWeekly = pattern.estMinutesSavedWeekly
                    if existing.status == "dismissed",
                       let atDismissal = existing.dismissedAtOccurrences,
                       pattern.occurrences >= atDismissal * 2 {
                        existing.status = "new"     // resurfaced: frequency doubled
                    }
                    if existing.status == "snoozed",
                       let until = existing.snoozedUntil, until <= nowMs {
                        existing.status = "new"
                    }
                    try existing.update(db)
                } else {
                    var fresh = Suggestion(
                        id: nil, createdAt: nowMs, patternKey: pattern.key,
                        kind: pattern.kind, evidence: pattern.evidence,
                        occurrences: pattern.occurrences, avgMinutes: pattern.avgMinutes,
                        estMinutesSavedWeekly: pattern.estMinutesSavedWeekly,
                        title: nil, suggestion: nil, confidence: nil,
                        status: "new", dismissedAtOccurrences: nil, snoozedUntil: nil
                    )
                    try fresh.insert(db)
                    changed += 1
                }
            }
            return changed
        }
    }

    /// Active suggestions, ranked by score.
    public static func active(database: ShifuDatabase) throws -> [Suggestion] {
        try database.queue.read { db in
            try Suggestion.filter(Column("status") == "new").fetchAll(db)
        }.sorted { $0.score > $1.score }
    }

    public static func dismiss(_ suggestion: Suggestion, database: ShifuDatabase) throws {
        guard let id = suggestion.id else { return }
        try database.queue.write { db in
            try db.execute(sql: """
                UPDATE suggestions SET status = 'dismissed', dismissed_at_occurrences = occurrences
                WHERE id = ?
                """, arguments: [id])
        }
    }

    public static func snooze(_ suggestion: Suggestion, days: Int = 30,
                              database: ShifuDatabase, now: Date = Date()) throws {
        guard let id = suggestion.id else { return }
        let until = Int64(now.timeIntervalSince1970 * 1_000) + Int64(days) * 86_400_000
        try database.queue.write { db in
            try db.execute(sql: "UPDATE suggestions SET status = 'snoozed', snoozed_until = ? WHERE id = ?",
                           arguments: [until, id])
        }
    }

    // MARK: - Describer (§6.2)

    static func describerPrompt(_ pending: [Suggestion]) -> String {
        var lines = [
            "For each observed usage pattern, judge whether it is automatable and how.",
            "Respond with ONLY a JSON array:",
            #"[{"id": 1, "title": "Morning metrics ritual (~22 min/week)", "#
                + #""suggestion": "1-3 sentences: what this looks like and how to automate it, "#
                + #"including estimated setup effort", "confidence": 0.7}]"#,
            "Confidence 0-1 that automation is genuinely worthwhile. Be honest — mark",
            "patterns that are probably fine as manual habits with low confidence.",
            "",
            "Patterns:",
        ]
        for item in pending {
            guard let id = item.id else { continue }
            lines.append("id=\(id) kind=\(item.kind) \(item.evidence) "
                + "(≈\(Int(item.estMinutesSavedWeekly)) min/week at stake)")
        }
        return lines.joined(separator: "\n")
    }

    static func parseDescriptions(_ response: String) -> [(id: Int64, title: String, suggestion: String, confidence: Double)] {
        guard let start = response.firstIndex(of: "["),
              let end = response.lastIndex(of: "]"), start < end,
              let data = String(response[start...end]).data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return array.compactMap { obj in
            guard let id = (obj["id"] as? NSNumber)?.int64Value,
                  let title = obj["title"] as? String,
                  let suggestion = obj["suggestion"] as? String,
                  let confidence = (obj["confidence"] as? NSNumber)?.doubleValue
            else { return nil }
            return (id, title, suggestion, confidence)
        }
    }

    /// Describes not-yet-described suggestions with the LLM. Returns count updated.
    @discardableResult
    public static func describe(database: ShifuDatabase, backend: LLMBackend) async throws -> Int {
        let pending = try await database.queue.read { db in
            try Suggestion
                .filter(sql: "suggestion IS NULL AND status = 'new'")
                .limit(10)
                .fetchAll(db)
        }
        guard !pending.isEmpty else { return 0 }

        let response = try await backend.complete(
            prompt: describerPrompt(pending), maxTokens: 1_500)
        let described = parseDescriptions(response)
        let validIDs = Set(pending.compactMap(\.id))

        return try await database.queue.write { db in
            var updated = 0
            for item in described where validIDs.contains(item.id) {
                try db.execute(sql: """
                    UPDATE suggestions SET title = ?, suggestion = ?, confidence = ?
                    WHERE id = ?
                    """, arguments: [item.title, item.suggestion, item.confidence, item.id])
                updated += db.changesCount
            }
            return updated
        }
    }
}
