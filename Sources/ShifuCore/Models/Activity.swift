import Foundation
import GRDB

/// Time categories (design.md §4.2). User-extensible later; enum for v1 seeds.
public enum Category: String, Codable, Sendable, CaseIterable {
    case work
    case learning
    case entertainment
    case social
    case communication
    case admin
    /// Excluded apps/domains: counted opaquely, never inspected (§13.5 default).
    case privateTime = "private"
    case unclassified
}

/// One classified activity block in the ledger (design.md §4.1, §4.3).
public struct Activity: Codable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "activities"

    public var id: Int64?
    public var startedAt: Int64          // unix ms
    public var endedAt: Int64
    public var appBundle: String
    public var domain: String?
    public var category: Category
    public var topic: String?
    public var confidence: Double?
    public var source: String            // rules | llm | user
    /// True when the rules layer marked this mapping ambiguous (`*` entries):
    /// the LLM tier should revisit it (§4.2).
    public var ambiguous: Bool

    public var durationMs: Int64 { endedAt - startedAt }

    enum CodingKeys: String, CodingKey {
        case id
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case appBundle = "app_bundle"
        case domain
        case category
        case topic
        case confidence
        case source
        case ambiguous
    }

    public init(
        id: Int64? = nil,
        startedAt: Int64,
        endedAt: Int64,
        appBundle: String,
        domain: String? = nil,
        category: Category,
        topic: String? = nil,
        confidence: Double? = nil,
        source: String = "rules",
        ambiguous: Bool = false
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.appBundle = appBundle
        self.domain = domain
        self.category = category
        self.topic = topic
        self.confidence = confidence
        self.source = source
        self.ambiguous = ambiguous
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
