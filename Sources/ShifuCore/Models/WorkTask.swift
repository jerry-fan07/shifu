import Foundation
import GRDB

/// A user-created goal grouping tasks (design.md §5.3): a learning goal, a
/// work effort, anything extended enough to want its own time totals.
public struct Project: Codable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "projects"

    public var id: Int64?
    public var name: String
    public var createdAt: Int64          // unix ms

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case createdAt = "created_at"
    }

    public init(id: Int64? = nil, name: String, createdAt: Int64) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// One ongoing task the user works on (design.md §5.3). Derived from
/// activities by TaskGrouper (stable `key`), renameable, spans any number of
/// days. Named WorkTask because `Task` is Swift concurrency's.
public struct WorkTask: Codable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "tasks"

    public var id: Int64?
    public var key: String               // grouping key; see TaskGrouper.key
    public var name: String
    public var projectID: Int64?
    public var createdAt: Int64          // unix ms
    public var lastActiveAt: Int64

    enum CodingKeys: String, CodingKey {
        case id
        case key
        case name
        case projectID = "project_id"
        case createdAt = "created_at"
        case lastActiveAt = "last_active_at"
    }

    public init(
        id: Int64? = nil, key: String, name: String, projectID: Int64? = nil,
        createdAt: Int64, lastActiveAt: Int64
    ) {
        self.id = id
        self.key = key
        self.name = name
        self.projectID = projectID
        self.createdAt = createdAt
        self.lastActiveAt = lastActiveAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// One day of work on one task, compiled by the analyzer (design.md §5.3):
/// what apps/sites were involved and what the time went to.
public struct TaskLog: Codable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "task_logs"

    public var id: Int64?
    public var taskID: Int64
    public var dayStart: Int64           // local-midnight unix ms
    public var durationMs: Int64
    public var summary: String

    enum CodingKeys: String, CodingKey {
        case id
        case taskID = "task_id"
        case dayStart = "day_start"
        case durationMs = "duration_ms"
        case summary
    }

    public init(id: Int64? = nil, taskID: Int64, dayStart: Int64, durationMs: Int64, summary: String) {
        self.id = id
        self.taskID = taskID
        self.dayStart = dayStart
        self.durationMs = durationMs
        self.summary = summary
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
