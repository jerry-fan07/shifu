import Foundation
import GRDB

/// Reading and writing spotted dates (design.md §4.7) — the only writer of
/// `deadline_proposals`, so what counts as "seen again", "ruled on" and
/// "announced" each has one place it can change.
public enum DeadlineProposalStore {
    /// Extra score per additional day a line was seen on, and its cap. Three
    /// days of the same date on screen is as much as repetition can say.
    static let repeatBonusCap = 3

    // MARK: - Writes (scout side)

    /// Records one sighting of each hit. Runs inside the scout's write
    /// transaction, hence the raw `Database`. Returns how many were new.
    ///
    /// A repeat sighting keeps the row's status whatever it is — a dismissal
    /// stays dismissed, an acceptance accepted — and folds in what it learned:
    /// one more sighting, perhaps a new day, the better of the two scores and
    /// the wording that earned it, and a task if the row had none.
    @discardableResult
    static func record(
        _ hits: [DeadlineScout.Hit], source: DeadlineScout.Source, db: Database,
        now: Int64, calendar: Calendar = .current
    ) throws -> Int {
        var created = 0
        for hit in hits {
            if var existing = try DeadlineProposal
                .filter(Column("key") == hit.key).fetchOne(db) {
                // A sighting no newer than the last one counted is a replay
                // — `--rebuild`, `scan --all` — and has been counted already.
                // It may still bring better wording; it may not make the row
                // look more seen than it was, or a rebuild alone could lift
                // a normal row into the tiers that earn a banner.
                if source.seenAt > existing.lastSeen {
                    existing.sightings += 1
                    if !calendar.isDate(
                        Date(timeIntervalSince1970: Double(existing.lastSeen) / 1_000),
                        inSameDayAs: Date(timeIntervalSince1970: Double(source.seenAt) / 1_000)) {
                        existing.seenDays += 1
                    }
                    existing.lastSeen = source.seenAt
                }
                existing.firstSeen = min(existing.firstSeen, source.seenAt)
                // Once the model has judged a row its wording and tier are
                // settled; later sightings only count.
                if hit.score > existing.baseScore && !existing.judged {
                    existing.baseScore = hit.score
                    existing.title = hit.title
                    existing.context = hit.context ?? existing.context
                    existing.evidence = hit.evidence
                    existing.category = hit.category
                    existing.sourceApp = source.appBundle
                    existing.sourceDomain = source.domain ?? existing.sourceDomain
                    // A timed sighting of an all-day row is more information.
                    if !hit.allDay && existing.allDay {
                        existing.dueAt = hit.dueAt
                        existing.allDay = false
                    }
                }
                if existing.taskID == nil { existing.taskID = source.taskID }
                existing.score = existing.baseScore + min(repeatBonusCap, existing.seenDays - 1)
                if !existing.judged { existing.tier = DeadlineScout.Tier.of(score: existing.score) }
                try existing.update(db)
            } else {
                var row = DeadlineProposal(
                    key: hit.key, title: hit.title, context: hit.context, dueAt: hit.dueAt,
                    allDay: hit.allDay, category: hit.category, baseScore: hit.score,
                    score: hit.score, tier: hit.tier, evidence: hit.evidence,
                    sourceApp: source.appBundle, sourceDomain: source.domain, taskID: source.taskID,
                    sightings: 1, seenDays: 1, firstSeen: source.seenAt, lastSeen: source.seenAt,
                    status: .new, deadlineID: nil, notifiedAt: nil, judged: false, createdAt: now)
                try row.insert(db)
                created += 1
            }
        }
        return created
    }

    /// Proposals whose day has passed without a decision drop out of the
    /// queue. Not deleted: the key still blocks the same line from returning
    /// as news, and `--all` can still show what was spotted.
    @discardableResult
    public static func expire(
        database: ShifuDatabase, now: Int64, calendar: Calendar = .current
    ) throws -> Int {
        let today = calendar.startOfDay(for: Date(timeIntervalSince1970: Double(now) / 1_000))
        let cutoff = Int64(today.timeIntervalSince1970 * 1_000)
        return try database.queue.write { db in
            try db.execute(
                sql: "UPDATE deadline_proposals SET status = 'expired' WHERE status = 'new' AND due_at < ?",
                arguments: [cutoff])
            return db.changesCount
        }
    }

    // MARK: - Reads

    private static let openOrder = "ORDER BY tier DESC, due_at, score DESC, id"

    /// What is open, most pressing first: tier, then date. The queue every
    /// surface draws from.
    public static func pending(
        database: ShifuDatabase, minimumTier: DeadlineScout.Tier = .low
    ) throws -> [DeadlineProposal] {
        try database.queue.read { db in
            try DeadlineProposal.fetchAll(db, sql: """
                SELECT * FROM deadline_proposals WHERE status = 'new' AND tier >= ? \(openOrder)
                """, arguments: [minimumTier.rawValue])
        }
    }

    /// Everything ever spotted, open first.
    public static func all(database: ShifuDatabase) throws -> [DeadlineProposal] {
        try database.queue.read { db in
            try DeadlineProposal.fetchAll(db, sql: """
                SELECT * FROM deadline_proposals ORDER BY status != 'new', tier DESC, due_at, id
                """)
        }
    }

    public static func find(_ proposalID: Int64, database: ShifuDatabase) throws -> DeadlineProposal? {
        try database.queue.read { db in try DeadlineProposal.fetchOne(db, key: proposalID) }
    }

    /// Open proposals the model has not yet judged, best first — the judge's
    /// batch.
    public static func unjudged(
        database: ShifuDatabase, limit: Int
    ) throws -> [DeadlineProposal] {
        try database.queue.read { db in
            try DeadlineProposal.fetchAll(db, sql: """
                SELECT * FROM deadline_proposals WHERE status = 'new' AND judged = 0
                ORDER BY score DESC, due_at, id LIMIT ?
                """, arguments: [limit])
        }
    }

    // MARK: - User actions

    /// Accepting mints the deadline — in the user's words if they changed
    /// them — and links the two. `targetMs` is the one thing a proposal can
    /// never carry: how much work the user means to put in.
    @discardableResult
    public static func accept(
        _ proposalID: Int64, title: String? = nil, dueAt: Int64? = nil, allDay: Bool? = nil,
        taskID: Int64? = nil, targetMs: Int64? = nil,
        now: Int64 = Int64(Date().timeIntervalSince1970 * 1_000),
        database: ShifuDatabase
    ) throws -> Deadline? {
        guard let proposal = try find(proposalID, database: database) else { return nil }
        let deadline = try DeadlineStore.create(
            title: title ?? proposal.title, dueAt: dueAt ?? proposal.dueAt,
            allDay: allDay ?? proposal.allDay, taskID: taskID ?? proposal.taskID,
            targetMs: targetMs, now: now, database: database)
        try database.queue.write { db in
            try db.execute(sql: """
                UPDATE deadline_proposals SET status = 'accepted', deadline_id = ? WHERE id = ?
                """, arguments: [deadline.id, proposalID])
        }
        return deadline
    }

    public static func dismiss(_ proposalID: Int64, database: ShifuDatabase) throws {
        try database.queue.write { db in
            try db.execute(
                sql: "UPDATE deadline_proposals SET status = 'dismissed' WHERE id = ? AND status = 'new'",
                arguments: [proposalID])
        }
    }

    /// "None of these" — with the same permanence as dismissing each.
    @discardableResult
    public static func dismissAll(database: ShifuDatabase) throws -> Int {
        try database.queue.write { db in
            try db.execute(sql: "UPDATE deadline_proposals SET status = 'dismissed' WHERE status = 'new'")
            return db.changesCount
        }
    }

    // MARK: - Ledgers

    /// Marks proposals as named in a notification. Written after the post,
    /// like `DeadlineStore.stamp`, and only ever from NULL — a proposal is
    /// announced once.
    static func stampNotified(_ proposalIDs: [Int64], now: Int64, database: ShifuDatabase) throws {
        guard !proposalIDs.isEmpty else { return }
        try database.queue.write { db in
            for proposalID in proposalIDs {
                try db.execute(sql: """
                    UPDATE deadline_proposals SET notified_at = ? WHERE id = ? AND notified_at IS NULL
                    """, arguments: [now, proposalID])
            }
        }
    }

    /// The judge's verdict on one proposal: a veto drops it to dismissed
    /// (remembered, so the next sighting stays quiet), otherwise the model's
    /// wording and tier adjustment land and the row is marked judged.
    static func applyJudgment(
        _ judgment: DeadlineScoutJudge.Judgment, db: Database
    ) throws {
        guard var row = try DeadlineProposal.fetchOne(db, key: judgment.id), row.status == .new
        else { return }
        row.judged = true
        if !judgment.keep {
            row.status = .dismissed
            try row.update(db)
            return
        }
        if let title = judgment.title, !title.isEmpty { row.title = title }
        if let category = judgment.category { row.category = category }
        let nudged = max(DeadlineScout.Tier.low.rawValue,
                         min(DeadlineScout.Tier.critical.rawValue, row.tier.rawValue + judgment.tierShift))
        row.tier = DeadlineScout.Tier(rawValue: nudged) ?? row.tier
        try row.update(db)
    }
}
