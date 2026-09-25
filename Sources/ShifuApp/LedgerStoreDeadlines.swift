import Foundation
import ShifuCore

/// The store's deadline reads and actions (design.md §4.5), split out of
/// LedgerStore.swift the way decks and themes were — for that file's length,
/// and because deadlines are the one thing in the app the user *authors*
/// outright rather than adjusts on something the pipeline made.
@MainActor
extension LedgerStore {
    // MARK: - Reads

    /// Open deadlines, soonest first — what the Coming-up band and the menu bar
    /// line both draw. Refreshed with everything else; there is no separate
    /// poll, because nothing but the user changes this list.
    var comingUp: [DeadlineHorizon.Standing] { deadlines }

    /// The ones near enough to be worth the menu bar's one line: inside the
    /// longest lead, or already past. Further out is a list you go and look at,
    /// not a thing to be told.
    var pressingDeadlines: [DeadlineHorizon.Standing] {
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        return deadlines.filter {
            DeadlineHorizon.daysUntil(dueAt: $0.deadline.dueAt, now: now)
                <= (DeadlineHorizon.leads.first ?? 7)
        }
    }

    func refreshDeadlines() {
        guard let database = try? db() else { return }
        deadlines = (try? DeadlineStore.open(database: database)) ?? []
    }

    func deadlines(forTask taskID: Int64) -> [DeadlineHorizon.Standing] {
        guard let database = try? db() else { return [] }
        return (try? DeadlineStore.forTask(taskID, database: database)) ?? []
    }

    // MARK: - Actions

    /// Records a deadline. The date arrives as text because that is how it is
    /// typed — `DeadlineDate` is the one parser, shared with `shifu due`, so the
    /// two surfaces cannot disagree about what "friday" means. Returns false
    /// when the text was not a date, which is the form the field needs to keep
    /// the sheet open and say so.
    @discardableResult
    func addDeadline(
        title: String, when: String, taskID: Int64? = nil, targetHours: String = ""
    ) -> Bool {
        guard let database = try? db(), let parsed = DeadlineDate.parse(when) else { return false }
        let target = targetHours.isEmpty ? nil : DeadlineDate.parseEffort(targetHours)
        guard (try? DeadlineStore.create(
            title: title, dueAt: parsed.dueAt, allDay: parsed.allDay,
            taskID: taskID, targetMs: target, database: database)) != nil
        else { return false }
        refreshSoon()
        return true
    }

    @discardableResult
    func updateDeadline(
        _ deadlineID: Int64, title: String? = nil, when: String? = nil,
        targetHours: String? = nil
    ) -> Bool {
        guard let database = try? db() else { return false }
        var parsed: DeadlineDate.Parsed?
        if let when, !when.isEmpty {
            guard let read = DeadlineDate.parse(when) else { return false }
            parsed = read
        }
        try? DeadlineStore.update(
            deadlineID, title: title, dueAt: parsed?.dueAt, allDay: parsed?.allDay,
            targetMs: targetHours.flatMap { $0.isEmpty ? nil : DeadlineDate.parseEffort($0) },
            clearTarget: targetHours == "",
            database: database)
        refreshSoon()
        return true
    }

    func markDeadlineDone(_ deadlineID: Int64, done: Bool = true) {
        if let database = try? db() {
            try? DeadlineStore.markDone(
                deadlineID,
                at: done ? Int64(Date().timeIntervalSince1970 * 1_000) : nil,
                database: database)
        }
        refreshSoon()
    }

    func deleteDeadline(_ deadlineID: Int64) {
        if let database = try? db() {
            try? DeadlineStore.delete(deadlineID, database: database)
        }
        refreshSoon()
    }
}
