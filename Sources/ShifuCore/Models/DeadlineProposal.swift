import Foundation
import GRDB

/// A date Shifu spotted on screen and thinks the user may want to look out
/// for (design.md §4.7). A proposal, never a deadline: nothing in this row is
/// reminded about on the five-notice schedule until the user accepts it, at
/// which point a `Deadline` is minted and this row only remembers that.
///
/// Like `theme_proposals`, `key` is unique and a dismissal is permanent — the
/// same line on the same page tomorrow folds into this row's sighting count
/// and does not come back as news.
public struct DeadlineProposal: Codable, Sendable, Identifiable, Equatable,
                                FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "deadline_proposals"

    public enum Status: String, Codable, Sendable {
        case new, accepted, dismissed, expired
    }

    public var id: Int64?
    /// `DeadlineScout.key`: the due day plus the words around the date.
    public var key: String
    /// The scout's reading of the line, or the judge's rewording of it.
    public var title: String
    /// The window it was read in, stripped to its subject.
    public var context: String?
    public var dueAt: Int64
    public var allDay: Bool
    public var category: DeadlineScout.Category
    /// The scorer's best single-sighting score — the repetition bonus is
    /// added on top to make `score`.
    public var baseScore: Int
    public var score: Int
    public var tier: DeadlineScout.Tier
    /// The line, verbatim, as the evidence a user judges the proposal on.
    public var evidence: String
    public var sourceApp: String
    public var sourceDomain: String?
    /// The task the sighting's block was filed to, carried into the deadline
    /// on acceptance so progress has something to measure.
    public var taskID: Int64?
    public var sightings: Int
    /// Distinct calendar days the line was seen on. A date that keeps being
    /// on screen is one the user keeps running into.
    public var seenDays: Int
    public var firstSeen: Int64
    public var lastSeen: Int64
    public var status: Status
    /// The `deadlines` row minted on acceptance. Nullable FK, set NULL if
    /// that deadline is later deleted.
    public var deadlineID: Int64?
    /// When a notification named this proposal — once, ever.
    public var notifiedAt: Int64?
    /// Whether the model has judged it. 0 until the judge runs, 1 after, so
    /// no proposal is sent twice.
    public var judged: Bool
    public var createdAt: Int64

    enum CodingKeys: String, CodingKey {
        case id, key, title, context
        case dueAt = "due_at"
        case allDay = "all_day"
        case category
        case baseScore = "base_score"
        case score, tier, evidence
        case sourceApp = "source_app"
        case sourceDomain = "source_domain"
        case taskID = "task_id"
        case sightings
        case seenDays = "seen_days"
        case firstSeen = "first_seen"
        case lastSeen = "last_seen"
        case status
        case deadlineID = "deadline_id"
        case notifiedAt = "notified_at"
        case judged
        case createdAt = "created_at"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    /// Whole calendar days from `now` to the due day, negative once past.
    public func daysLeft(now: Int64, calendar: Calendar = .current) -> Int {
        DeadlineHorizon.daysUntil(dueAt: dueAt, now: now, calendar: calendar)
    }
}
