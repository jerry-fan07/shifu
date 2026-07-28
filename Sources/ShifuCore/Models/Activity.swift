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

/// One classified activity block in the ledger (design.md §4.1, §4.3) — a run
/// of observations on the same app/domain, folded together and given a category.
///
/// Rows are **not stable across runs.** `LedgerBuilder.rebuild` deletes and
/// re-inserts every activity overlapping its window each time the analyzer
/// runs, so `id` changes freely. What persists is the *span identity*
/// (`startedAt`, `endedAt`, `appBundle`); the rebuild uses it to carry
/// expensive derived state — the LLM verdict, `extracted`, `llmAttempts` —
/// onto the newly inserted row. Never store a long-lived reference to an
/// activity `id`.
///
/// This struct is a **partial** mirror of the `activities` table. The columns
/// added by migrations v4–v10 — `extracted`, `task_id`, `signature`,
/// `llm_attempts` — are deliberately absent here and read/written with raw SQL
/// by the passes that own them (`KnowledgeExtractor`, `TaskGrouper`,
/// `TaskMerges`, `AmbiguousClassifier`). Check the migrator in
/// `ShifuDatabase`, not this type, for the full schema.
public struct Activity: Codable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "activities"

    public var id: Int64?
    /// Unix ms. With `endedAt` and `appBundle`, forms the span identity the
    /// idempotent rebuild matches on.
    public var startedAt: Int64
    public var endedAt: Int64
    public var appBundle: String
    /// Normalized host of the block's URL: lowercased, `www.` stripped
    /// (`Sessionizer.domain(of:)`). Nil for non-browser blocks.
    public var domain: String?
    public var category: Category
    /// Short free-text description of what the user was doing. Only the LLM
    /// tier produces one — nil for every rules-classified block.
    public var topic: String?
    /// The LLM's self-reported confidence, nil outside the LLM tier. Verdicts
    /// below `AmbiguousClassifier.confidenceFloor` are never applied at all.
    public var confidence: Double?
    /// Which tier produced `category`: `"rules"`, `"llm"`, or `"user"`. A free
    /// string rather than an enum; `"user"` outranks the others and is never
    /// overwritten by a later pass.
    public var source: String
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
