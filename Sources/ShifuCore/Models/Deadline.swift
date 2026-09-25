import Foundation
import GRDB

/// A date the user promised something by, and optionally how much work they
/// mean to put in before it (design.md §4.5).
///
/// **Nothing infers one of these.** Every other row in Shifu is derived from
/// what the screen showed; a deadline is the one thing the user states. That
/// asymmetry is a measurement, not a stylistic choice — see the §4.5 note on
/// what a month of real screen text actually contains.
///
/// Unlike `WorkTask`, every column is in `CodingKeys`, so GRDB's
/// `insert`/`update` round-trip the whole row. (`tasks.gist` is not in
/// `WorkTask`, which is why six call sites hand-write SQL for it.)
public struct Deadline: Codable, Sendable, Identifiable, Equatable,
                        FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "deadlines"

    public var id: Int64?
    /// The user's words, shown verbatim in every reminder.
    public var title: String
    /// Unix ms. The *moment* it is due when `allDay` is false; the day it falls
    /// on is all that is meant when `allDay` is true.
    public var dueAt: Int64
    /// True when only a day was given. Reminders for an all-day deadline fire
    /// at the reminder hour rather than at the stored instant, so a deadline
    /// entered as "Friday" cannot announce itself at midnight.
    public var allDay: Bool
    /// The task whose logged time counts as progress. Nullable because a
    /// commitment can precede any task, and because prune and merge delete
    /// task rows — the FK sets this to NULL rather than taking the row with it.
    public var taskID: Int64?
    /// The effort intended before the date, in ms. NULL is a date-only
    /// deadline: still reminded, never reported as a fraction.
    public var targetMs: Int64?
    public var createdAt: Int64
    /// Non-NULL takes the row out of every queue and every reminder. The only
    /// completion state anywhere near a task — `tasks` itself has none.
    public var doneAt: Int64?
    /// The smallest lead bucket (days) already announced; NULL is "nothing said
    /// yet", -1 is "the overdue notice went out". Only ever falls.
    public var announcedLead: Int?
    /// The highest quarter of `targetMs` already reported (0/25/50/75/100).
    public var progressNotch: Int

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case dueAt = "due_at"
        case allDay = "all_day"
        case taskID = "task_id"
        case targetMs = "target_ms"
        case createdAt = "created_at"
        case doneAt = "done_at"
        case announcedLead = "announced_lead"
        case progressNotch = "progress_notch"
    }

    public init(
        id: Int64? = nil, title: String, dueAt: Int64, allDay: Bool = true,
        taskID: Int64? = nil, targetMs: Int64? = nil, createdAt: Int64,
        doneAt: Int64? = nil, announcedLead: Int? = nil, progressNotch: Int = 0
    ) {
        self.id = id
        self.title = title
        self.dueAt = dueAt
        self.allDay = allDay
        self.taskID = taskID
        self.targetMs = targetMs
        self.createdAt = createdAt
        self.doneAt = doneAt
        self.announcedLead = announcedLead
        self.progressNotch = progressNotch
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public var isDone: Bool { doneAt != nil }
}
