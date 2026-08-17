import Foundation
import GRDB

/// Reading and writing deadlines (design.md §4.5). The only writer of the
/// `deadlines` table, so "what has been announced" has one place it can change.
public enum DeadlineStore {
    /// The logged-effort half of a `Standing`, as SQL.
    ///
    /// Clipped at `created_at` rather than counted from the task's birth: the
    /// promise is about the work left when it was made, so a task with 40 hours
    /// behind it starts a fresh deadline at zero. `MAX(a.started_at,
    /// d.created_at)` is what clips a block that straddles that moment — without
    /// it, one block begun before the deadline existed would donate its whole
    /// span, and on a long block that is hours of credit for nothing.
    private static let loggedMsSQL = """
        COALESCE((SELECT SUM(a.ended_at - MAX(a.started_at, d.created_at))
                  FROM activities a
                  WHERE a.task_id = d.task_id AND a.ended_at > d.created_at), 0)
        """

    private static func standingsSQL(where clause: String) -> String {
        """
        SELECT d.*, t.name AS task_name, \(loggedMsSQL) AS logged_ms
        FROM deadlines d LEFT JOIN tasks t ON t.id = d.task_id
        WHERE \(clause)
        ORDER BY d.done_at IS NOT NULL, d.due_at, d.id
        """
    }

    private static func standing(_ row: Row) throws -> DeadlineHorizon.Standing {
        DeadlineHorizon.Standing(
            deadline: try Deadline(row: row),
            loggedMs: row["logged_ms"] ?? 0,
            taskName: row["task_name"])
    }

    // MARK: - Reads

    /// Every deadline still open, soonest first — the queue every surface draws
    /// from, and the input to the announcement policy.
    public static func open(database: ShifuDatabase) throws -> [DeadlineHorizon.Standing] {
        try database.queue.read { db in
            try Row.fetchAll(db, sql: standingsSQL(where: "d.done_at IS NULL")).map(standing)
        }
    }

    /// Open deadlines plus the ones already met, for the surfaces that show a
    /// history (`shifu due --all`, the task page's own list).
    public static func all(database: ShifuDatabase) throws -> [DeadlineHorizon.Standing] {
        try database.queue.read { db in
            try Row.fetchAll(db, sql: standingsSQL(where: "1")).map(standing)
        }
    }

    /// One task's deadlines, open ones first. Several is normal — that is what
    /// distinguishes a critical timeline from a due date.
    public static func forTask(
        _ taskID: Int64, database: ShifuDatabase
    ) throws -> [DeadlineHorizon.Standing] {
        try database.queue.read { db in
            try Row.fetchAll(db, sql: standingsSQL(where: "d.task_id = ?"), arguments: [taskID])
                .map(standing)
        }
    }

    public static func find(
        _ deadlineID: Int64, database: ShifuDatabase
    ) throws -> DeadlineHorizon.Standing? {
        try database.queue.read { db in
            try Row.fetchOne(db, sql: standingsSQL(where: "d.id = ?"), arguments: [deadlineID])
                .map(standing)
        }
    }

    // MARK: - Writes

    /// Records a promise. `now` is a parameter so tests and the CLI's `--at`
    /// share one path with the app.
    @discardableResult
    public static func create(
        title: String, dueAt: Int64, allDay: Bool = true, taskID: Int64? = nil,
        targetMs: Int64? = nil, now: Int64 = Int64(Date().timeIntervalSince1970 * 1_000),
        database: ShifuDatabase
    ) throws -> Deadline {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DeadlineError.emptyTitle }
        var row = Deadline(
            title: String(trimmed.prefix(200)), dueAt: dueAt, allDay: allDay,
            taskID: taskID, targetMs: targetMs, createdAt: now)
        try database.queue.write { db in try row.insert(db) }
        return row
    }

    /// Edits the parts a user can change. Passing nil leaves a field alone,
    /// which is why clearing the target and the task have their own flags —
    /// "no change" and "set to none" are different intentions and one optional
    /// cannot carry both.
    public static func update(
        _ deadlineID: Int64, title: String? = nil, dueAt: Int64? = nil, allDay: Bool? = nil,
        taskID: Int64? = nil, clearTask: Bool = false,
        targetMs: Int64? = nil, clearTarget: Bool = false,
        database: ShifuDatabase
    ) throws {
        try database.queue.write { db in
            guard var row = try Deadline.fetchOne(db, key: deadlineID) else { return }
            let before = row
            Edit(
                title: title, dueAt: dueAt, allDay: allDay,
                taskID: taskID, clearTask: clearTask,
                targetMs: targetMs, clearTarget: clearTarget
            ).apply(to: &row)
            // Moving the date re-arms the schedule. Without this, pushing a
            // deadline out a month would stay silent forever — its notices were
            // all "already said" at the old, nearer date.
            if row.dueAt != before.dueAt { row.announcedLead = nil }
            // Changing the target re-arms progress for the same reason, and the
            // reset has to be to the highest quarter *already earned* rather
            // than to zero: raising 20h to 40h after the 100% notice must make
            // 75% reachable again without re-announcing 25% and 50% on the next
            // tick. Clearing the target lands on 0, which is what a target set
            // again later should measure from.
            if row.targetMs != before.targetMs {
                row.progressNotch = try earnedNotch(row, db: db)
            }
            try row.update(db)
        }
    }

    /// The field-by-field half of `update`, as a value so `update` itself stays
    /// under the complexity limit. It is nothing but "nil leaves it alone" —
    /// every decision that reads a *changed* field stays in `update`, where the
    /// before-and-after rows are both in hand.
    private struct Edit {
        var title: String?
        var dueAt: Int64?
        var allDay: Bool?
        var taskID: Int64?
        var clearTask: Bool
        var targetMs: Int64?
        var clearTarget: Bool

        func apply(to row: inout Deadline) {
            if let title {
                let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { row.title = String(trimmed.prefix(200)) }
            }
            if let dueAt { row.dueAt = dueAt }
            if let allDay { row.allDay = allDay }
            if clearTask { row.taskID = nil } else if let taskID { row.taskID = taskID }
            if clearTarget { row.targetMs = nil } else if let targetMs { row.targetMs = targetMs }
        }
    }

    /// The highest quarter of a row's *current* target that its logged time
    /// already covers — what `progressNotch` must fall to when the target moves,
    /// so no quarter is announced twice and none above it is lost.
    ///
    /// Reads the same clipped sum as `loggedMsSQL`, inside the caller's write
    /// transaction: the figure has to be the one the next announcement will see,
    /// and a second connection could be looking at a ledger mid-rebuild.
    private static func earnedNotch(_ row: Deadline, db: Database) throws -> Int {
        guard let target = row.targetMs, target > 0, let taskID = row.taskID else { return 0 }
        let logged = try Int64.fetchOne(
            db,
            sql: """
                SELECT COALESCE(SUM(a.ended_at - MAX(a.started_at, ?)), 0) FROM activities a
                WHERE a.task_id = ? AND a.ended_at > ?
                """,
            arguments: [row.createdAt, taskID, row.createdAt]) ?? 0
        let percent = Int((Double(logged) / Double(target) * 100).rounded(.down))
        return DeadlineHorizon.notches.filter { $0 <= percent }.max() ?? 0
    }

    /// Marks a promise kept (or `nil` to reopen it). A done deadline is out of
    /// every queue and says nothing further, including the overdue notice.
    public static func markDone(
        _ deadlineID: Int64, at moment: Int64? = Int64(Date().timeIntervalSince1970 * 1_000),
        database: ShifuDatabase
    ) throws {
        try database.queue.write { db in
            try db.execute(
                sql: "UPDATE deadlines SET done_at = ? WHERE id = ?",
                arguments: [moment, deadlineID])
        }
    }

    public static func delete(_ deadlineID: Int64, database: ShifuDatabase) throws {
        try database.queue.write { db in
            try db.execute(sql: "DELETE FROM deadlines WHERE id = ?", arguments: [deadlineID])
        }
    }

    /// Records that an announcement was delivered, so it cannot be delivered
    /// again. Written *after* the notification is handed to the system: the
    /// failure this ordering picks is a repeated reminder rather than a silent
    /// one, and only one of those is recoverable by the user.
    public static func stamp(
        _ announcement: DeadlineAnnouncement, database: ShifuDatabase
    ) throws {
        try database.queue.write { db in
            if let lead = announcement.lead {
                try db.execute(
                    sql: """
                        UPDATE deadlines SET announced_lead = ?
                        WHERE id = ? AND (announced_lead IS NULL OR announced_lead > ?)
                        """,
                    arguments: [lead, announcement.deadlineID, lead])
            }
            if let notch = announcement.notch {
                try db.execute(
                    sql: """
                        UPDATE deadlines SET progress_notch = ?
                        WHERE id = ? AND progress_notch < ?
                        """,
                    arguments: [notch, announcement.deadlineID, notch])
            }
        }
    }
}

public enum DeadlineError: Error, LocalizedError {
    case emptyTitle
    case unreadableDate(String)

    public var errorDescription: String? {
        switch self {
        case .emptyTitle:
            return "a deadline needs a title"
        case .unreadableDate(let text):
            return "couldn't read \"\(text)\" as a date — try 2026-08-30, "
                + "2026-08-30 17:00, tomorrow, friday, or +10d"
        }
    }
}
