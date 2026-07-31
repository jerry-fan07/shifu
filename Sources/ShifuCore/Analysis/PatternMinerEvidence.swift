import Foundation
import GRDB

/// The database half of the miner (design.md §6.1): turning the ledger into
/// automation dossiers. Split from `PatternMiner.swift` the way
/// `SemanticTaskEvidence` is split from its grouper — everything there is pure
/// and unit-tested over rows, everything here is SQL over the real tables.
///
/// The whole pre-filter lives in this pass. The analyzer used to hand the
/// miner "every block that isn't private" and let it find repetition anywhere;
/// that is how search engines and browser chrome came to dominate the tab.
/// Now nothing that isn't a recurring, substantial, non-leisure task (or a
/// genuine polling loop) is ever mined at all.
extension PatternMiner {
    /// Reserved slots so a polling loop — small in minutes, large in
    /// annoyance — is never crowded out by twelve fat tasks.
    public static let pollingCandidateLimit = 3

    /// Every automation candidate in the window, ranked and capped.
    ///
    /// Glances that are *already* part of a named task are not an alerting
    /// gap — the work has a name, so the suggestion should be about the work,
    /// and minting both would bill twice for one workflow. Note this is asked
    /// per block, not per domain: `github.com` can hold a week of real work
    /// and, in the same fortnight, 150 refreshes of one repo that has nothing
    /// to do with it.
    public static func mine(
        database: ShifuDatabase, from: Int64, to: Int64, calendar: Calendar = .current
    ) throws -> [Candidate] {
        // Whole local days, and the *same* window for every query below:
        // `task_logs` is keyed by local midnight, so a mid-afternoon `from`
        // would count a day's log whose blocks the block queries then drop —
        // "over 4 days" over evidence from three.
        let start = Int64(calendar.startOfDay(
            for: Date(timeIntervalSince1970: Double(from) / 1_000)).timeIntervalSince1970 * 1_000)
        let tasks = try taskCandidates(database: database, from: start, to: to,
                                       calendar: calendar)
        let gaps = try pollingCandidates(
            database: database, from: start, to: to,
            insideTasks: Set(tasks.map(\.taskKey)), calendar: calendar)
        return ranked(tasks, limit: candidateLimit - gaps.count) + gaps
    }

    // MARK: - Tasks

    /// Recurring, substantial, non-leisure tasks, most time first. `task_logs`
    /// (one row per task-day, so counting rows counts days) narrows the field
    /// cheaply; every gate that decides is applied to the blocks themselves in
    /// `taskDossier`.
    static func taskCandidates(
        database: ShifuDatabase, from: Int64, to: Int64, calendar: Calendar = .current
    ) throws -> [Candidate] {
        try database.queue.read { db in
            // `task_logs` is only the cheap sieve here — its numbers can be
            // stale (a merge repoints activities without rewriting older
            // days), so the gates that decide are re-applied to the blocks in
            // `taskDossier`. What SQL rules out has to be the *weakest*
            // necessary condition, or a real candidate never gets looked at.
            //
            // The `namesIntent` namespaces are filtered in SQL, not after: the
            // heaviest rows in a real ledger are all containers, so a LIMIT
            // applied before the filter spends its whole budget on them and
            // the actual workflows never even reach the ranking.
            let rows = try Row.fetchAll(db, sql: """
                SELECT t.id, t.key, t.name, t.gist,
                       COUNT(l.id) AS days_active, SUM(l.duration_ms) AS logged_ms
                FROM tasks t JOIN task_logs l ON l.task_id = t.id
                WHERE l.day_start >= ? AND l.day_start < ?
                  AND (t.key LIKE 'sem:%' OR t.key LIKE 'topic:%')
                GROUP BY t.id
                HAVING days_active >= ? AND logged_ms >= ?
                ORDER BY logged_ms DESC LIMIT ?
                """, arguments: [from, to, substantialDaysActive,
                                 Int64(minTotalMinutes * 60_000), candidateLimit * 3])
            // Rows arrive heaviest-first, which is `ranked`'s own order, so
            // building dossiers stops as soon as the cap is full: the query
            // over-fetches only because the per-candidate gates below can
            // reject a row, not because the extra dossiers are wanted.
            var candidates: [Candidate] = []
            for row in rows {
                if let dossier = try taskDossier(db, row: row, from: from, to: to,
                                                 calendar: calendar) {
                    candidates.append(dossier)
                }
                if candidates.count == candidateLimit { break }
            }
            return candidates
        }
    }

    /// One task's dossier, or nil when it fails a gate the SQL couldn't apply.
    private static func taskDossier(
        _ db: Database, row: Row, from: Int64, to: Int64, calendar: Calendar
    ) throws -> Candidate? {
        // `namesIntent` is the rule; the query's two LIKE prefixes are its
        // mirror, kept there so the LIMIT ranks eligible rows. This guard is
        // what stops the two from drifting apart silently.
        let key: String = row["key"]
        guard namesIntent(taskKey: key) else { return nil }
        let taskID: Int64 = row["id"]
        let blocks = try taskBlocks(db, taskID: taskID, from: from, to: to)
        guard let dominant = dominantCategory(blocks), !isLeisure(dominant) else { return nil }

        // Counted from the blocks, not from `task_logs`, and the gates are
        // re-applied to the result: the logs include the private time and the
        // legacy lock-screen blocks that `taskBlocks` drops, so taking their
        // sum would print "5.8h over 5 days" above a source list adding up to
        // 3.3h — and hand that inflated figure to the honesty cap on what the
        // describer may claim to save.
        let minutes = Double(blocks.reduce(Int64(0)) { $0 + $1.durationMs }) / 60_000
        let daysActive = daysActive(blocks.map(\.startedAt), calendar: calendar)
        guard qualifies(daysActive: daysActive, totalMinutes: minutes) else { return nil }
        let sample = try sampled(db, observationIDs: try observationIDs(
            db, joinPredicate: "a.task_id = ?", arguments: [taskID], from: from, to: to))
        return Candidate(
            key: "task:" + key, kind: .task, name: row["name"], gist: row["gist"],
            daysActive: daysActive, totalMinutes: minutes, occurrences: daysActive,
            schedule: scheduleLine(starts: blocks.map(\.startedAt), calendar: calendar),
            sources: topSources(blocks, limit: sourceMemoryLimit),
            signals: [alternationSignal(blocks)].compactMap { $0 },
            logSummaries: try logSummaries(db, taskID: taskID, from: from),
            titles: sample.titles, textSample: sample.text)
    }

    /// The task's blocks, minus private time.
    ///
    /// `category != 'private'` is not decoration: private blocks are counted
    /// opaquely and never inspected (§8), and this dossier's sources, titles
    /// and text sample are shipped to the cloud describer. Every other
    /// LLM-facing query in the pipeline carries the same clause.
    private static func taskBlocks(
        _ db: Database, taskID: Int64, from: Int64, to: Int64
    ) throws -> [Block] {
        try Row.fetchAll(db, sql: """
            SELECT started_at, ended_at, app_bundle, domain, category
            FROM activities
            WHERE task_id = ? AND ended_at > ? AND started_at < ?
              AND category != 'private'
            ORDER BY started_at
            """, arguments: [taskID, from, to]).map(block)
    }

    private static func block(_ row: Row) -> Block {
        let started: Int64 = row["started_at"]
        let ended: Int64 = row["ended_at"]
        let domain = (row["domain"] as String?).flatMap { isRealSite($0) ? $0 : nil }
        return Block(
            startedAt: started, durationMs: ended - started,
            // Browser chrome falls back to the app: "Chrome", not
            // "omnibox-popup.top-chrome", is where that time actually went.
            label: domain ?? SemanticTaskGrouper.shortBundle(row["app_bundle"]),
            category: Category(rawValue: row["category"]) ?? .unclassified)
    }

    /// The task's own recent day-log lines — the ledger's own summary of what
    /// this work looked like, in the words `TaskGrouper.summaryLine` wrote.
    private static func logSummaries(
        _ db: Database, taskID: Int64, from: Int64
    ) throws -> [String] {
        try String.fetchAll(db, sql: """
            SELECT summary FROM task_logs
            WHERE task_id = ? AND day_start >= ?
            ORDER BY day_start DESC LIMIT ?
            """, arguments: [taskID, from, logSummaryLimit])
    }

    // MARK: - Polling

    /// Domains opened over and over for seconds at a time: the alerting gap
    /// (§6.1). This is the one candidate kind that isn't a task, because by
    /// construction it never accrues the minutes to become one — and it is
    /// also the one the old miner got structurally wrong, since counting short
    /// visits rewards search engines and browsers above everything else.
    static func pollingCandidates(
        database: ShifuDatabase, from: Int64, to: Int64,
        insideTasks: Set<String> = [], calendar: Calendar = .current
    ) throws -> [Candidate] {
        let minVisits = Int(pollingVisitsPerDay * Double(windowDays))
        return try database.queue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT domain, COUNT(*) AS visits
                FROM activities
                WHERE domain IS NOT NULL AND category != 'private'
                  AND ended_at > ? AND started_at < ? AND ended_at - started_at < ?
                GROUP BY domain
                HAVING visits >= ?
                ORDER BY visits DESC
                """, arguments: [from, to, pollingMaxVisitMs, minVisits])
            // Ordered by visits, and each accepted domain costs another scan,
            // so stop at the reserved slots rather than dossier-ing every
            // qualifying domain to keep three.
            var candidates: [Candidate] = []
            for row in rows {
                let domain: String = row["domain"]
                guard isRealSite(domain), !isSearchDomain(domain),
                      try !isInsideATask(db, domain: domain, from: from, to: to,
                                         candidateKeys: insideTasks) else { continue }
                if let dossier = try pollingDossier(db, domain: domain, from: from, to: to,
                                                    calendar: calendar) {
                    candidates.append(dossier)
                }
                if candidates.count == pollingCandidateLimit { break }
            }
            return candidates
        }
    }

    /// True when most of a domain's glances are already filed under one of
    /// this run's task candidates — the polling *is* that task's work, seen
    /// from the domain side.
    private static func isInsideATask(
        _ db: Database, domain: String, from: Int64, to: Int64, candidateKeys: Set<String>
    ) throws -> Bool {
        guard !candidateKeys.isEmpty else { return false }
        let rows = try Row.fetchAll(db, sql: """
            SELECT t.key AS task_key, COUNT(*) AS glances
            FROM activities a LEFT JOIN tasks t ON t.id = a.task_id
            WHERE a.domain = ? AND a.ended_at > ? AND a.started_at < ?
              AND a.category != 'private' AND a.ended_at - a.started_at < ?
            GROUP BY t.key
            """, arguments: [domain, from, to, pollingMaxVisitMs])
        let total = rows.reduce(0) { $0 + ($1["glances"] as Int) }
        guard total > 0 else { return false }
        let claimed = rows.reduce(0) { sum, row in
            candidateKeys.contains((row["task_key"] as String?) ?? "")
                ? sum + (row["glances"] as Int) : sum
        }
        return Double(claimed) / Double(total) >= pollingClaimedShare
    }

    private static func pollingDossier(
        _ db: Database, domain: String, from: Int64, to: Int64, calendar: Calendar
    ) throws -> Candidate? {
        // Judged over *all* of the domain's time, not just the glances: a site
        // with three hours of watching behind its hundred quick checks is
        // leisure, however twitchy the checking looks on its own.
        let all = try Row.fetchAll(db, sql: """
            SELECT started_at, ended_at, app_bundle, domain, category
            FROM activities
            WHERE domain = ? AND ended_at > ? AND started_at < ?
              AND category != 'private'
            ORDER BY started_at
            """, arguments: [domain, from, to]).map(block)
        guard let dominant = dominantCategory(all), !isLeisure(dominant) else { return nil }

        let glances = all.filter { $0.durationMs < pollingMaxVisitMs }
        guard !glances.isEmpty else { return nil }
        let minutes = Double(glances.reduce(Int64(0)) { $0 + $1.durationMs }) / 60_000
        let days = daysActive(glances.map(\.startedAt), calendar: calendar)
        // Per *active* day, not per calendar day: "19 times a day" is what the
        // user would recognize, and it is the number the evidence line's own
        // "154 visits over 8 days" divides out to.
        let perDay = Double(glances.count) / Double(max(1, days))
        let sample = try sampled(db, observationIDs: try observationIDs(
            db, joinPredicate: "a.domain = ?", arguments: [domain], from: from, to: to))
        return Candidate(
            key: "freq:" + domain, kind: .polling, name: domain,
            daysActive: days, totalMinutes: minutes, occurrences: glances.count,
            schedule: scheduleLine(starts: glances.map(\.startedAt), calendar: calendar),
            // Only what the evidence line doesn't already say: the rate, and
            // the reading of it. The counts live one line above in the prompt.
            signals: ["~\(Int(perDay.rounded())) visits on each of those days, every one "
                + "of them a glance — checked, never worked in"],
            titles: sample.titles, textSample: sample.text)
    }

    // MARK: - Samples

    /// Ids of the evidence-bearing observations behind a candidate's blocks,
    /// chronological. Fetched separately from their content (cheap) so only
    /// the handful actually sampled pays for its OCR text.
    private static func observationIDs(
        _ db: Database, joinPredicate: String, arguments: StatementArguments,
        from: Int64, to: Int64
    ) throws -> [Int64] {
        try Int64.fetchAll(db, sql: """
            SELECT o.id FROM observations o JOIN activities a ON o.session_id = a.id
            WHERE \(joinPredicate) AND a.category != 'private'
              AND o.started_at >= ? AND o.started_at < ?
              AND (o.window_title IS NOT NULL OR o.text IS NOT NULL)
            ORDER BY o.started_at
            """, arguments: arguments + [from, to])
    }

    /// Titles and one text sample, spread across the whole window rather than
    /// scraped off its first minutes (`SemanticTaskGrouper.spreadIndices`).
    /// Everything here is post-redaction — it comes from `observations`, which
    /// `ObservationRecorder` redacted before it ever reached disk — and it is
    /// the context §6.2 always specified and never had: without it the model
    /// can only free-associate from a domain name.
    private static func sampled(
        _ db: Database, observationIDs ids: [Int64]
    ) throws -> (titles: [String], text: String) {
        let picked = SemanticTaskGrouper.spreadIndices(total: ids.count, count: sampleCount)
            .map { ids[$0] }
        guard !picked.isEmpty else { return ([], "") }
        let rows = try Row.fetchAll(db, sql: """
            SELECT window_title, text FROM observations
            WHERE id IN (\(databaseQuestionMarks(count: picked.count)))
            ORDER BY started_at
            """, arguments: StatementArguments(picked))

        var titles: [String] = []
        var text = ""
        for row in rows {
            if titles.count < titleSampleLimit, let title: String = row["window_title"],
               !title.isEmpty, !titles.contains(title) {
                titles.append(title)
            }
            if text.count < textSampleChars, let sample: String = row["text"] {
                text += sample.prefix(200) + " "
            }
        }
        return (titles, String(text.prefix(textSampleChars))
            .trimmingCharacters(in: .whitespaces))
    }
}
