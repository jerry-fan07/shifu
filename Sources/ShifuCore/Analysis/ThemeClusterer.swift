import Foundation
import GRDB

/// Theme layer (design.md §5.3): a second, *independent* LLM clustering of
/// activity blocks into 3–8 broad initiatives spanning weeks — "YC Startup
/// School", "Shifu development", "Travel" — one level of abstraction above
/// semantic tasks. Assignment is per block, so a task's blocks may straddle
/// themes; the Vault tab's Themes mode reads `activities.theme_key`.
///
/// **The model files, it does not found** (v17): blocks flow into themes that
/// already exist, but an initiative the model *invents* is written to
/// `ThemeProposals` for the user to accept or dismiss. Themes are the user's
/// own way of carving up their life, and the clusterer minting them silently
/// meant the grid filled with the model's opinions faster than anyone could
/// correct them.
///
/// The machinery deliberately mirrors `SemanticTaskGrouper` (and reuses its
/// verdict parsing/validation): confidence floor 0.6, `theme_attempts` cap,
/// token-budgeted batches, roster reuse, rebuild carry by span identity,
/// fail-soft everywhere. The block evidence is leaner — task name + titles +
/// topic, no raw text — because coarse clustering doesn't need it.
public enum ThemeClusterer {
    public static let maxAttempts = 3
    public static let minBlockMs: Int64 = 60_000
    public static let candidateLimit = 80
    /// Themes span weeks, so the reuse roster looks further back than tasks.
    public static let rosterLimit = 20
    public static let rosterWindowDays = 30
    public static let responseTokenReserve = 2_000
    public static let keyPrefix = "thm:"

    /// One block's evidence. Titles/topic are post-redaction; the task name
    /// is Shifu's own derived label. A card-bearing block (v20) drops titles
    /// for the card's topic and gist — fewer tokens, cleaner signal.
    public struct BlockSample: Sendable {
        public var id: Int64
        public var startedAt: Int64
        public var endedAt: Int64
        public var appBundle: String
        public var domain: String?
        public var topic: String?
        public var card: String?
        public var taskName: String?
        public var titles: [String]

        public init(id: Int64, startedAt: Int64, endedAt: Int64, appBundle: String,
                    domain: String?, topic: String?, card: String? = nil,
                    taskName: String?, titles: [String]) {
            self.id = id
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.appBundle = appBundle
            self.domain = domain
            self.topic = topic
            self.card = card
            self.taskName = taskName
            self.titles = titles
        }
    }

    public struct Summary: Equatable, Sendable {
        public var assigned: Int
        /// New initiatives written to the proposal queue — nothing appears in
        /// the Themes grid until the user accepts one.
        public var themesProposed: Int

        public init(assigned: Int = 0, themesProposed: Int = 0) {
            self.assigned = assigned
            self.themesProposed = themesProposed
        }
    }

    // MARK: - Prompt (pure, testable)

    static func prompt(roster: [SemanticTaskGrouper.RosterEntry], blocks: [BlockSample],
                       calendar: Calendar = .current) -> String {
        var lines: [String] = [
            "Cluster screen-time blocks into the user's broad ongoing initiatives —",
            "3 to 8 life areas spanning weeks (\"YC Startup School\", \"Shifu development\",",
            "\"College applications\", \"Travel\"). Coarser than single tasks: never a",
            "website, an app, or a one-off errand.",
            "",
            "Known initiatives — strongly prefer joining one:"
        ]
        if roster.isEmpty {
            lines.append("(none yet)")
        }
        for (index, entry) in roster.enumerated() {
            var line = "t\(index + 1): \(entry.name)"
            if let gist = entry.gist, !gist.isEmpty { line += " — \(gist)" }
            lines.append(line)
        }
        lines.append("")
        lines.append("Blocks, chronological (id, time, minutes, app, domain, task, "
            + "card gist or topic+titles):")
        let times = timeFormatter(calendar)
        for block in blocks {
            let minutes = max(1, (block.endedAt - block.startedAt) / 60_000)
            let start = Date(timeIntervalSince1970: Double(block.startedAt) / 1_000)
            var desc = "id=\(block.id) \(times.string(from: start)) \(minutes)m"
            desc += " app=\(SemanticTaskGrouper.shortBundle(block.appBundle))"
            if let domain = block.domain { desc += " domain=\(domain)" }
            if let taskName = block.taskName { desc += " task=\(taskName)" }
            if let card = BlockCard.parse(block.card) {
                // The card's topic and gist replace titles — coarse clustering
                // needs the intent, not the window chrome.
                desc += " topic=\(card.topic) gist=\(card.gist)"
            } else {
                if let topic = block.topic { desc += " topic=\(topic)" }
                if !block.titles.isEmpty {
                    desc += " titles=\(block.titles.prefix(2).joined(separator: " | "))"
                }
            }
            lines.append(desc)
        }
        lines.append(contentsOf: [
            "",
            "Assign each block to one initiative: existing (t1…) or new (n1, n2…).",
            "A new initiative needs a broad title (2-6 words) and a one-sentence gist.",
            "Omit blocks that fit nothing. Confidence is 0-1.",
            "Respond with ONLY JSON:",
            #"{"assignments": [{"id": 12, "task": "t1", "confidence": 0.9}],"#,
            #" "new_themes": [{"handle": "n1", "title": "YC Startup School","#,
            #"   "gist": "Program sessions, applications, and events around it."}]}"#
        ])
        return lines.joined(separator: "\n")
    }

    private static func timeFormatter(_ calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE HH:mm"
        formatter.timeZone = calendar.timeZone
        return formatter
    }
}

// MARK: - Assignment pipeline

extension ThemeClusterer {
    /// Unassigned blocks in the window, oldest first. No evidence gate: after
    /// TaskGrouper every block has at least a task name, which is enough for
    /// coarse clustering. Closed blocks only (`ended_at` a sessionizer gap
    /// before `to`) — a growing block's verdict dies with the next rebuild.
    public static func pendingSamples(
        database: ShifuDatabase, from: Int64, to: Int64, limit: Int = candidateLimit
    ) throws -> [BlockSample] {
        try database.queue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT a.id, a.started_at, a.ended_at, a.app_bundle, a.domain, a.topic,
                       a.card, t.name AS task_name
                FROM activities a LEFT JOIN tasks t ON t.id = a.task_id
                WHERE a.ended_at > ? AND a.started_at < ? AND a.ended_at <= ?
                  AND a.category != 'private'
                  AND a.theme_key IS NULL AND a.theme_attempts < ?
                  AND a.ended_at - a.started_at >= ?
                ORDER BY a.started_at DESC LIMIT ?
                """, arguments: [from, to, to - Sessionizer.gapThresholdMs,
                                 maxAttempts, minBlockMs, limit])
            return rows.map { row -> BlockSample in
                let id: Int64 = row["id"]
                let card: String? = row["card"]
                let titles = card != nil ? [] : (try? String.fetchAll(db, sql: """
                    SELECT DISTINCT window_title FROM observations
                    WHERE session_id = ? AND window_title IS NOT NULL
                      AND LENGTH(window_title) > 3 LIMIT 2
                    """, arguments: [id])) ?? []
                return BlockSample(
                    id: id, startedAt: row["started_at"], endedAt: row["ended_at"],
                    appBundle: row["app_bundle"], domain: row["domain"],
                    topic: row["topic"], card: card,
                    taskName: row["task_name"], titles: titles)
            }
            .sorted { $0.startedAt < $1.startedAt }
        }
    }

    /// Recently active themes, offered for reuse in every batch.
    public static func activeRoster(
        database: ShifuDatabase, now: Date = Date()
    ) throws -> [SemanticTaskGrouper.RosterEntry] {
        let cutoff = Int64(now.timeIntervalSince1970 * 1_000)
            - Int64(rosterWindowDays) * 86_400_000
        return try database.queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT key, name, gist FROM themes
                WHERE last_active_at >= ? ORDER BY last_active_at DESC LIMIT ?
                """, arguments: [cutoff, rosterLimit]
            ).map { row in
                SemanticTaskGrouper.RosterEntry(key: row["key"], name: row["name"],
                                                gist: row["gist"])
            }
        }
    }

    /// Everything a batch may join: the user's active themes, then the
    /// proposals already waiting on them, up to `rosterLimit` names total.
    ///
    /// Showing open proposals is what keeps the queue readable. Without them
    /// the model re-invents the same initiative from scratch every run and
    /// every batch, and small wording drift ("YC Startup School" → "Startup
    /// School program") slugs to a different key, so one initiative arrives as
    /// three suggestions. Shown the handle, it reuses it.
    static func joinableRoster(
        database: ShifuDatabase, now: Date = Date()
    ) throws -> [SemanticTaskGrouper.RosterEntry] {
        var entries = try activeRoster(database: database, now: now)
        if entries.count < rosterLimit {
            let remaining = rosterLimit - entries.count
            entries += try database.queue.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT key, name, gist FROM theme_proposals
                    WHERE status = 'new' ORDER BY created_at DESC LIMIT ?
                    """, arguments: [remaining]
                ).map { row in
                    SemanticTaskGrouper.RosterEntry(key: row["key"], name: row["name"],
                                                    gist: row["gist"])
                }
            }
        }
        // Key order for the same reason the task roster uses it: an unchanged
        // roster renders byte-identically across runs (recency still decided
        // which entries made the list).
        return entries.sorted { $0.key < $1.key }
    }

    /// Clusters the window's unassigned blocks. Same batching-and-growing-
    /// roster loop as SemanticTaskGrouper.run; a mid-run failure keeps
    /// earlier batches and leaves the rest queued (design.md §10).
    @discardableResult
    public static func run(
        database: ShifuDatabase, backend: any LLMBackend, from: Int64, to: Int64,
        now: Date = Date(), calendar: Calendar = .current
    ) async throws -> Summary {
        let samples = try pendingSamples(database: database, from: from, to: to)
        guard !samples.isEmpty else { return Summary() }
        var roster = try joinableRoster(database: database, now: now)
        let budget = max(
            512, backend.contextWindowTokens - backend.responseReserve(responseTokenReserve))

        var summary = Summary()
        var cursor = 0
        while cursor < samples.count {
            var batch: [BlockSample] = []
            while cursor < samples.count {
                batch.append(samples[cursor])
                cursor += 1
                if batch.count > 1,
                   LLMTokens.estimate(prompt(roster: roster, blocks: batch,
                                             calendar: calendar)) > budget {
                    batch.removeLast()
                    cursor -= 1
                    break
                }
            }
            let response = try await backend.complete(
                prompt: prompt(roster: roster, blocks: batch, calendar: calendar),
                maxTokens: responseTokenReserve)
            let verdict = SemanticTaskGrouper.parse(response, newEntriesKey: "new_themes")
            let outcome = try apply(verdict, batch: batch, roster: roster,
                                    database: database, now: now)
            summary.assigned += outcome.assigned
            summary.themesProposed += outcome.proposed.count
            roster.append(contentsOf: outcome.proposed)
        }
        return summary
    }

    /// Writes one batch. A key that names a theme the user has takes its
    /// blocks (`theme_key`); a key that doesn't becomes a proposal instead,
    /// carrying those block ids so accepting it files them. Every batch id
    /// that didn't land in a real theme burns an attempt — including the ones
    /// behind a proposal: the model *has* said where they go, and re-sending
    /// them every hour until the user answers would pay for that verdict
    /// again and again. The proposal remembers them, so an accept a week later
    /// still files the lot.
    static func apply(
        _ verdict: SemanticTaskGrouper.Verdict, batch: [BlockSample],
        roster: [SemanticTaskGrouper.RosterEntry],
        database: ShifuDatabase, now: Date = Date()
    ) throws -> (assigned: Int, proposed: [SemanticTaskGrouper.RosterEntry]) {
        let resolved = SemanticTaskGrouper.resolve(
            verdict, batch: batch.map(\.id), roster: roster, prefix: keyPrefix)
        let batchEnds = Dictionary(uniqueKeysWithValues: batch.map { ($0.id, $0.endedAt) })
        let rosterByKey = Dictionary(roster.map { ($0.key, $0) }) { first, _ in first }
        let nowMs = Int64(now.timeIntervalSince1970 * 1_000)
        return try database.queue.write { db in
            var proposed: [SemanticTaskGrouper.RosterEntry] = []
            var assignedIDs: Set<Int64> = []
            for (key, ids) in resolved.assignmentsByKey.sorted(by: { $0.key < $1.key }) {
                let exists = try Int64.fetchOne(
                    db, sql: "SELECT id FROM themes WHERE key = ?", arguments: [key]) != nil
                guard exists else {
                    // Either a name the model just invented, or an open
                    // proposal it was shown in the roster — the definition is
                    // only present in the first case.
                    let definition = resolved.newTaskByKey[key]
                    let candidate = SemanticTaskGrouper.RosterEntry(
                        key: key,
                        name: definition?.title ?? rosterByKey[key]?.name
                            ?? SemanticTaskGrouper.humanize(key: key),
                        gist: definition?.gist ?? rosterByKey[key]?.gist)
                    if try ThemeProposals.record(db, theme: candidate,
                                                 blockIDs: ids, now: nowMs) {
                        proposed.append(candidate)
                    }
                    continue
                }
                // The Themes list orders by recency; adopting blocks can only
                // make a theme more recently active, never less. Names and
                // gists are the user's — nothing here overwrites them.
                let lastActive = ids.compactMap { batchEnds[$0] }.max() ?? nowMs
                try db.execute(sql: """
                    UPDATE themes SET last_active_at = MAX(last_active_at, ?) WHERE key = ?
                    """, arguments: [lastActive, key])
                for id in ids {
                    try db.execute(sql: "UPDATE activities SET theme_key = ? WHERE id = ?",
                                   arguments: [key, id])
                    assignedIDs.insert(id)
                }
            }
            for id in Set(batchEnds.keys).subtracting(assignedIDs) {
                try db.execute(
                    sql: "UPDATE activities SET theme_attempts = theme_attempts + 1 WHERE id = ?",
                    arguments: [id])
            }
            return (assignedIDs.count, proposed)
        }
    }
}

// MARK: - Running narrative (hash-gated, ~one generation per theme per day)

extension ThemeClusterer {
    static let narrativeResponseTokens = 320

    /// Day lines for one theme over its *completed* local days — the current
    /// partial day is excluded on purpose, so the hash changes at most once
    /// per day and the narrative never regenerates hourly.
    static func completedDayLines(
        db: Database, themeKey: String, todayStart: Int64, calendar: Calendar
    ) throws -> [String] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT started_at, ended_at, app_bundle, domain, topic FROM activities
            WHERE theme_key = ? AND ended_at <= ? AND category != 'private'
            ORDER BY started_at
            """, arguments: [themeKey, todayStart])
        struct DayAgg {
            var ms: Int64 = 0
            var sources: [String] = []
            var topics: [String] = []
        }
        var perDay: [Int64: DayAgg] = [:]
        var order: [Int64] = []
        for row in rows {
            let started: Int64 = row["started_at"]
            let day = calendar.startOfDay(
                for: Date(timeIntervalSince1970: Double(started) / 1_000))
            let dayMs = Int64(day.timeIntervalSince1970 * 1_000)
            if perDay[dayMs] == nil { order.append(dayMs) }
            var agg = perDay[dayMs] ?? DayAgg()
            agg.ms += (row["ended_at"] as Int64) - started
            let bundle: String = row["app_bundle"]
            let source = (row["domain"] as String?)
                ?? (bundle.split(separator: ".").last.map(String.init) ?? bundle)
            if !agg.sources.contains(source) { agg.sources.append(source) }
            if let topic = row["topic"] as String?, !agg.topics.contains(topic) {
                agg.topics.append(topic)
            }
            perDay[dayMs] = agg
        }
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        dayFormatter.timeZone = calendar.timeZone
        return order.compactMap { dayMs in
            guard let agg = perDay[dayMs] else { return nil }
            let day = dayFormatter.string(
                from: Date(timeIntervalSince1970: Double(dayMs) / 1_000))
            let hours = String(format: "%.1f", Double(agg.ms) / 3_600_000)
            let line = TaskGrouper.summaryLine(sources: agg.sources, topics: agg.topics)
            return "\(day) (\(hours)h): \(line)"
        }
    }

    static func narrativePrompt(name: String, gist: String?, dayLines: [String]) -> String {
        """
        Write the running story of the initiative "\(name)"\(gist.map { " — \($0)" } ?? "").
        Day entries, oldest first:
        \(dayLines.joined(separator: "\n"))

        3-5 sentences: what this initiative is, what has happened so far, and where
        it stands now. Plain prose, no headers or bullets. Respond with ONLY the text.
        """
    }

    /// Regenerates the running summary for active themes whose completed-day
    /// content changed. Returns how many narratives were (re)written.
    @discardableResult
    public static func refreshNarratives(
        database: ShifuDatabase, backend: any LLMBackend,
        now: Date = Date(), calendar: Calendar = .current
    ) async throws -> Int {
        let cutoff = Int64(now.timeIntervalSince1970 * 1_000)
            - Int64(rosterWindowDays) * 86_400_000
        let todayStart = Int64(calendar.startOfDay(for: now).timeIntervalSince1970 * 1_000)

        struct PendingNarrative {
            var themeID: Int64
            var name: String
            var gist: String?
            var hash: Int64
            var dayLines: [String]
        }
        let pending: [PendingNarrative] = try await database.queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, key, name, gist, summary_hash FROM themes
                WHERE last_active_at >= ? ORDER BY last_active_at DESC LIMIT ?
                """, arguments: [cutoff, rosterLimit]
            ).compactMap { row in
                let lines = try completedDayLines(
                    db: db, themeKey: row["key"], todayStart: todayStart, calendar: calendar)
                guard !lines.isEmpty else { return nil }
                let hash = VaultIndexer.contentHash(lines.joined(separator: "\n"))
                guard hash != (row["summary_hash"] as Int64) else { return nil }
                return PendingNarrative(themeID: row["id"], name: row["name"],
                                        gist: row["gist"], hash: hash, dayLines: lines)
            }
        }

        var written = 0
        for item in pending {
            // Budget (invariant 7): drop oldest days rather than fail.
            var lines = item.dayLines
            var text = narrativePrompt(name: item.name, gist: item.gist, dayLines: lines)
            while lines.count > 1,
                LLMTokens.estimate(text) + backend.responseReserve(narrativeResponseTokens)
                > backend.contextWindowTokens {
                lines.removeFirst()
                text = narrativePrompt(name: item.name, gist: item.gist, dayLines: lines)
            }
            let summary = try await backend
                .complete(prompt: text, maxTokens: narrativeResponseTokens)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !summary.isEmpty else { continue }
            try await database.queue.write { db in
                try db.execute(
                    sql: "UPDATE themes SET summary = ?, summary_hash = ? WHERE id = ?",
                    arguments: [summary, item.hash, item.themeID])
            }
            written += 1
        }
        return written
    }
}
