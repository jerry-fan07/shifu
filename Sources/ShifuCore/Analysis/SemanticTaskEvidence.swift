import Foundation
import GRDB

/// Everything the semantic grouper *shows* the model, and how it is rendered:
/// the roster of existing tasks with their history, the already-grouped blocks
/// on either side of a batch, and each pending block's sampled evidence
/// (design.md §5.3). The pipeline half — batching, parsing, writing — stays in
/// `SemanticTaskGrouper.swift`.
///
/// The shape follows what a human observer actually uses to say "that's still
/// the thesis": a *weighted* prior over known tasks (time spent, days active,
/// where the time went) rather than a flat list of names, and the stickiness
/// cue — whatever was happening a minute ago is probably still happening —
/// fenced so a two-minute detour into messaging doesn't get absorbed into the
/// work it interrupted.
extension SemanticTaskGrouper {
    // MARK: - Prompt (pure, testable)

    /// Renders one batch. `roster` is already sized by the caller (`run`
    /// compacts it for small-context backends), so roster indices here are the
    /// `t<n>` handles `resolve` reads back — the two must never disagree.
    /// `detail` decides only how much history each roster line carries.
    static func prompt(roster: [RosterEntry], blocks: [BlockSample],
                       neighbors: [NeighborBlock] = [], detail: RosterDetail = .full,
                       calendar: Calendar = .current) -> String {
        var handleByKey: [String: String] = [:]
        for (index, entry) in roster.enumerated() { handleByKey[entry.key] = "t\(index + 1)" }
        let times = timeFormatter(calendar)

        var lines: [String] = [
            "Group screen-time blocks into the user's high-level tasks — the goal being",
            "pursued, phrased as the user would (\"Applying to YC Startup School",
            "afterparties\", \"Booking flights and planning travel\") — never an app or",
            "website name.",
            "",
            detail == .full
                ? "Existing tasks — reuse one whenever a block continues it "
                    + "(time logged over \(rosterWindowDays) days, then where it went):"
                : "Existing tasks — reuse one whenever a block continues it:"
        ]
        if roster.isEmpty { lines.append("(none yet)") }
        for (index, entry) in roster.enumerated() {
            lines.append(rosterLine(handle: "t\(index + 1)", entry: entry, detail: detail))
        }

        if !neighbors.isEmpty {
            lines.append("")
            lines.append("Already grouped, around this batch (context — these are not yours to assign):")
            let shown = neighbors.suffix(detail == .full ? neighborLimit : compactNeighborLimit)
            lines.append(contentsOf: shown.map {
                neighborLine($0, handleByKey: handleByKey, times: times)
            })
        }

        lines.append("")
        lines.append("Blocks, chronological (id, local time, minutes, app, pages, titles, text):")
        for block in blocks {
            lines.append(blockLine(block, times: times))
            if !block.textSample.isEmpty { lines.append("  text: \(block.textSample)") }
        }

        lines.append(contentsOf: [
            "",
            "Assign each block to one task: existing (t1…) or new (n1, n2…).",
            "Work is sticky: consecutive blocks usually continue the same task, so when a",
            "block's evidence is thin, prefer the task running on either side of it.",
            "Interruptions are the exception: a short messaging, social, or entertainment",
            "detour between two stretches of one task is a break from it, never part of it —",
            "leave it out. The return to the task is the continuity, not the detour.",
            "A new task needs a specific goal-level title (3-8 words) and a one-sentence gist.",
            "Omit blocks that fit no task (idle browsing, one-off glances).",
            "Confidence is 0-1; use low confidence when the evidence is thin.",
            "Respond with ONLY JSON:",
            #"{"assignments": [{"id": 12, "task": "t1", "confidence": 0.9}],"#,
            #" "new_tasks": [{"handle": "n1", "title": "Booking flights for the SF trip","#,
            #"   "gist": "Comparing fares and picking travel dates."}]}"#
        ])
        return lines.joined(separator: "\n")
    }

    /// "~ Thu 09:12 14m overleaf.com → t1 (Writing the thesis)". Deliberately
    /// id-less: the model can only answer about the batch's blocks, and
    /// `resolve` drops every other id anyway.
    private static func neighborLine(
        _ neighbor: NeighborBlock, handleByKey: [String: String], times: DateFormatter
    ) -> String {
        let start = Date(timeIntervalSince1970: Double(neighbor.startedAt) / 1_000)
        let minutes = max(1, (neighbor.endedAt - neighbor.startedAt) / 60_000)
        let label = handleByKey[neighbor.taskKey].map { "\($0) (\(neighbor.taskName))" }
            ?? neighbor.taskName
        return "~ \(times.string(from: start)) \(minutes)m "
            + (neighbor.domain ?? shortBundle(neighbor.appBundle)) + " → " + label
    }

    private static func blockLine(_ block: BlockSample, times: DateFormatter) -> String {
        let minutes = max(1, (block.endedAt - block.startedAt) / 60_000)
        let start = Date(timeIntervalSince1970: Double(block.startedAt) / 1_000)
        var desc = "id=\(block.id) \(times.string(from: start)) \(minutes)m"
        desc += " app=\(shortBundle(block.appBundle))"
        // The pages already carry the block's host, so the bare domain would
        // just be repeating itself.
        if !block.urls.isEmpty {
            desc += " pages=\(block.urls.prefix(urlSampleLimit).joined(separator: " | "))"
        } else if let domain = block.domain {
            desc += " domain=\(domain)"
        }
        if let topic = block.topic { desc += " topic=\(topic)" }
        if !block.titles.isEmpty {
            desc += " titles=\(block.titles.prefix(4).joined(separator: " | "))"
        }
        return desc
    }

    /// "t3: Booking flights — … · 2.4h over 3d · last 2d ago · united.com, kayak.com".
    /// The numbers are the prior's weights: a block matches the task that
    /// already spends its hours there, not merely the one whose name reads
    /// closest. Tasks minted mid-run have no logged history yet, so they show
    /// as a bare name until the next run.
    static func rosterLine(handle: String, entry: RosterEntry, detail: RosterDetail) -> String {
        var line = "\(handle): \(entry.name)"
        if let gist = entry.gist, !gist.isEmpty { line += " — \(gist)" }
        guard detail == .full, entry.daysActive > 0 else { return line }
        var facts = ["\(durationLabel(minutes: entry.minutes)) over \(entry.daysActive)d"]
        facts.append(entry.lastActiveDays <= 0 ? "last today" : "last \(entry.lastActiveDays)d ago")
        if !entry.topSources.isEmpty {
            facts.append(entry.topSources.prefix(sourceLimit).joined(separator: ", "))
        }
        return line + " · " + facts.joined(separator: " · ")
    }

    /// Trims a roster to what a small context window can afford, keeping the
    /// tasks with the most time behind them — the heaviest prior mass — in the
    /// original (most-recent-first) order.
    static func compacted(_ roster: [RosterEntry], limit: Int = compactRosterLimit) -> [RosterEntry] {
        guard roster.count > limit else { return roster }
        let keep = Set(roster.indices
            .sorted { (roster[$0].minutes, -$0) > (roster[$1].minutes, -$1) }
            .prefix(limit))
        return roster.indices.filter(keep.contains).map { roster[$0] }
    }

    static func durationLabel(minutes: Int) -> String {
        minutes >= 90 ? String(format: "%.1fh", Double(minutes) / 60) : "\(minutes)m"
    }

    /// "com.apple.dt.Xcode" → "Xcode". A trailing wrapper word is skipped:
    /// "com.conductor.app" is *conductor*, and an evidence line reading
    /// "app, ghostty, github.com" names one of the three.
    static let bundleWrapperTails: Set<String> = ["app", "desktop", "mac", "macos", "osx"]

    static func shortBundle(_ bundle: String) -> String {
        let parts = bundle.split(separator: ".").map(String.init)
        guard let last = parts.last else { return bundle }
        if parts.count > 2, bundleWrapperTails.contains(last.lowercased()) {
            return parts[parts.count - 2]
        }
        return last
    }

    private static func timeFormatter(_ calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE HH:mm"
        formatter.timeZone = calendar.timeZone
        return formatter
    }

    /// "https://www.github.com/org/repo/pull/12?tab=files#c3" → "github.com/org/repo".
    ///
    /// The full URL has always been captured; only the derived domain ever
    /// reached the model, so a repo, a doc, and a checkout flow all looked
    /// alike. Query and fragment are dropped — search terms and tokens live
    /// there — and the result goes through the redactor: `observations.url` is
    /// stored unredacted (invariant 2 guards extracted *text*), so this is the
    /// pass that keeps a key pasted into a path out of the prompt.
    static func urlToken(_ raw: String) -> String? {
        guard let host = Sessionizer.domain(of: raw) else { return nil }
        let segments = (URL(string: raw)?.path ?? "")
            .split(separator: "/").prefix(urlSegmentLimit)
            .map { String($0.prefix(urlSegmentChars)) }
        let token = ([host] + segments).joined(separator: "/")
        return Redactor.redact(String(token.prefix(urlTokenChars)))
    }

    /// Indices of up to `count` evenly spread items — first, last, and an even
    /// fan between. A `LIMIT 5` described a two-hour block by its opening
    /// minutes; the spread describes the whole span.
    static func spreadIndices(total: Int, count: Int = sampleCount) -> [Int] {
        guard total > count, count > 1 else { return Array(0..<max(0, total)) }
        return (0..<count).map { $0 * (total - 1) / (count - 1) }
    }
}

// MARK: - Queries

extension SemanticTaskGrouper {
    /// Unassigned, evidence-bearing blocks in the window, oldest first.
    /// Evidence means a topic, a window title, or captured text — a bare
    /// metadata block gives the model nothing beyond the app name, which the
    /// mechanical key already encodes. System-shell blocks
    /// (`TaskGrouper.isSystemBundle`) are excluded in SQL, not after: they can
    /// never join a task, and left in they'd hold candidate slots and burn
    /// tokens and attempts on lock screens and auth prompts.
    public static func pendingSamples(
        database: ShifuDatabase, from: Int64, to: Int64, limit: Int = candidateLimit
    ) throws -> [BlockSample] {
        let denied = TaskGrouper.notSystemBundleSQL()
        return try database.queue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, started_at, ended_at, app_bundle, domain, topic
                FROM activities
                WHERE ended_at > ? AND started_at < ? AND category != 'private'
                  AND sem_key IS NULL AND sem_attempts < ?
                  AND ended_at - started_at >= ?
                  AND \(denied.clause)
                  AND (topic IS NOT NULL OR EXISTS (
                        SELECT 1 FROM observations o WHERE o.session_id = activities.id
                          AND (o.window_title IS NOT NULL OR o.text IS NOT NULL)))
                ORDER BY started_at DESC LIMIT ?
                """, arguments: [from, to, maxAttempts, minBlockMs]
                    + StatementArguments(denied.arguments) + [limit])
            return try rows.map { row -> BlockSample in
                let id: Int64 = row["id"]
                let evidence = try blockEvidence(db, blockID: id)
                return BlockSample(
                    id: id, startedAt: row["started_at"], endedAt: row["ended_at"],
                    appBundle: row["app_bundle"], domain: row["domain"], topic: row["topic"],
                    titles: evidence.titles, urls: evidence.urls, textSample: evidence.text)
            }
            .sorted { $0.startedAt < $1.startedAt }
        }
    }

    /// What the sampled observations of one block yielded.
    private struct BlockEvidence {
        var titles: [String] = []
        var urls: [String] = []
        var text = ""
    }

    /// One block's evidence, sampled across its whole span. Ids are fetched
    /// first (cheap) so only the handful of rows actually sampled pay for
    /// their OCR text.
    private static func blockEvidence(_ db: Database, blockID: Int64) throws -> BlockEvidence {
        let ids = try Int64.fetchAll(db, sql: """
            SELECT id FROM observations
            WHERE session_id = ?
              AND (window_title IS NOT NULL OR text IS NOT NULL OR url IS NOT NULL)
            ORDER BY started_at
            """, arguments: [blockID])
        let picked = spreadIndices(total: ids.count).map { ids[$0] }
        guard !picked.isEmpty else { return BlockEvidence() }
        let rows = try Row.fetchAll(db, sql: """
            SELECT window_title, text, url FROM observations
            WHERE id IN (\(databaseQuestionMarks(count: picked.count)))
            ORDER BY started_at
            """, arguments: StatementArguments(picked))

        var evidence = BlockEvidence()
        var sample = ""
        for row in rows {
            if let title: String = row["window_title"], !title.isEmpty,
               !evidence.titles.contains(title) {
                evidence.titles.append(title)
            }
            if evidence.urls.count < urlSampleLimit, let raw: String = row["url"],
               let token = urlToken(raw), !evidence.urls.contains(token) {
                evidence.urls.append(token)
            }
            if sample.count < textSampleChars, let text: String = row["text"] {
                sample += text.prefix(200) + " "
            }
        }
        evidence.text = String(sample.prefix(textSampleChars))
            .trimmingCharacters(in: .whitespaces)
        return evidence
    }

    /// The most recently active semantic tasks, offered for reuse so ongoing
    /// work keeps landing in the same task across runs and days — each with
    /// the history that makes it a weighted prior rather than a name in a list.
    public static func activeRoster(
        database: ShifuDatabase, now: Date = Date()
    ) throws -> [RosterEntry] {
        let nowMs = Int64(now.timeIntervalSince1970 * 1_000)
        let cutoff = nowMs - Int64(rosterWindowDays) * 86_400_000
        return try database.queue.read { db in
            // One `task_logs` row per (task, day), so counting them counts days.
            let rows = try Row.fetchAll(db, sql: """
                SELECT t.id, t.key, t.name, t.gist, t.last_active_at,
                       COALESCE(SUM(l.duration_ms), 0) AS logged_ms,
                       COUNT(l.id) AS days_active
                FROM tasks t
                LEFT JOIN task_logs l ON l.task_id = t.id AND l.day_start >= ?
                WHERE t.key LIKE 'sem:%' AND t.last_active_at >= ?
                GROUP BY t.id
                ORDER BY t.last_active_at DESC LIMIT ?
                """, arguments: [cutoff, cutoff, rosterLimit])
            return try rows.map { row in
                let lastActive: Int64 = row["last_active_at"]
                return RosterEntry(
                    key: row["key"], name: row["name"], gist: row["gist"],
                    minutes: Int((row["logged_ms"] as Int64) / 60_000),
                    daysActive: row["days_active"],
                    lastActiveDays: Int(max(0, nowMs - lastActive) / 86_400_000),
                    topSources: try topSources(db, taskID: row["id"], since: cutoff))
            }
        }
    }

    /// Where a task's time actually went, most first — the likelihood half of
    /// the prior: a `partiful.com` block matches the task that already lives
    /// there even when its name says nothing about the site.
    private static func topSources(
        _ db: Database, taskID: Int64, since: Int64
    ) throws -> [String] {
        try Row.fetchAll(db, sql: """
            SELECT domain, app_bundle, SUM(ended_at - started_at) AS ms
            FROM activities
            WHERE task_id = ? AND ended_at >= ? AND category != 'private'
            GROUP BY COALESCE(domain, app_bundle)
            ORDER BY ms DESC LIMIT ?
            """, arguments: [taskID, since, sourceLimit]
        ).map { row in
            (row["domain"] as String?) ?? shortBundle(row["app_bundle"])
        }
    }

    /// Already-grouped blocks around `anchor`, chronological. This is the
    /// stickiness evidence: what the user was doing on either side of the
    /// batch, which is the strongest cue a human observer has — switches are
    /// punctuated events, not the default. Re-read per batch, so a batch sees
    /// what the previous one just wrote.
    static func assignedNeighbors(
        database: ShifuDatabase, around anchor: Int64, limit: Int = neighborLimit
    ) throws -> [NeighborBlock] {
        try database.queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT a.started_at, a.ended_at, a.app_bundle, a.domain, a.sem_key,
                       t.name AS task_name
                FROM activities a LEFT JOIN tasks t ON t.key = a.sem_key
                WHERE a.sem_key IS NOT NULL AND a.category != 'private'
                  AND a.ended_at > ? AND a.started_at < ?
                ORDER BY ABS(a.started_at - ?) LIMIT ?
                """, arguments: [anchor - neighborWindowMs, anchor + neighborWindowMs,
                                 anchor, limit]
            ).map { row -> NeighborBlock in
                let key: String = row["sem_key"]
                return NeighborBlock(
                    startedAt: row["started_at"], endedAt: row["ended_at"],
                    appBundle: row["app_bundle"], domain: row["domain"],
                    taskKey: key, taskName: (row["task_name"] as String?) ?? humanize(key: key))
            }
            .sorted { $0.startedAt < $1.startedAt }
        }
    }
}
