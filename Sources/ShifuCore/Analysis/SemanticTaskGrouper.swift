import Foundation
import GRDB

/// Semantic task grouping (design.md §5.3): an LLM assigns activity blocks to
/// intent-level tasks — "booking flights for the SF trip", "applying to YC
/// afterparties" — instead of the mechanical topic/domain/app key, so a task
/// reads as the goal the user was pursuing rather than a list of websites.
///
/// The pass writes `activities.sem_key` (`"sem:<slug>"`), which `TaskGrouper`
/// prefers over its mechanical key. Everything is fail-soft: no backend, a
/// failed call, or an unconfident model leaves `sem_key` NULL and the block
/// grouped mechanically (§10). Assignments are expensive derived state, so
/// `LedgerBuilder` carries them across rebuilds by span identity, and blocks
/// the model declines to place burn one of `maxAttempts` credits — mirroring
/// `AmbiguousClassifier` — so an unchanged window stops billing.
public enum SemanticTaskGrouper {
    public static let confidenceFloor = 0.6
    public static let maxAttempts = 3
    /// Blocks shorter than this stay mechanically grouped — a 40-second glance
    /// carries too little intent to be worth tokens.
    public static let minBlockMs: Int64 = 60_000
    /// Cap on candidate blocks per run; the rest wait for the next hour.
    public static let candidateLimit = 60
    /// Existing tasks offered for reuse: the most recently active semantic
    /// tasks of the last `rosterWindowDays`.
    public static let rosterLimit = 40
    public static let rosterWindowDays = 14
    public static let textSampleChars = 300
    public static let responseTokenReserve = 2_000
    public static let keyPrefix = "sem:"

    /// The evidence for one block, as sent to the model. All of it is
    /// post-redaction: titles and text come from `observations`, which
    /// `ObservationRecorder` redacted before disk.
    public struct BlockSample: Sendable {
        public var id: Int64
        public var startedAt: Int64
        public var endedAt: Int64
        public var appBundle: String
        public var domain: String?
        public var topic: String?
        public var titles: [String]
        public var textSample: String

        public init(id: Int64, startedAt: Int64, endedAt: Int64, appBundle: String,
                    domain: String?, topic: String?, titles: [String], textSample: String) {
            self.id = id
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.appBundle = appBundle
            self.domain = domain
            self.topic = topic
            self.titles = titles
            self.textSample = textSample
        }
    }

    /// One reusable task offered to the model ("t3: Booking flights — …").
    public struct RosterEntry: Sendable {
        public var key: String
        public var name: String
        public var gist: String?

        public init(key: String, name: String, gist: String?) {
            self.key = key
            self.name = name
            self.gist = gist
        }
    }

    /// One block → task proposal from the model.
    public struct Assignment: Equatable, Sendable {
        public var id: Int64
        public var task: String     // "t<n>" (roster) or "n<n>" (new)
        public var confidence: Double
    }

    /// A task the model wants to mint for this batch.
    public struct NewTask: Equatable, Sendable {
        public var handle: String
        public var title: String
        public var gist: String?
    }

    /// The model's parsed answer for one batch. Like the classifier's
    /// verdicts, this is a *proposal*: `apply` drops assignments for ids
    /// outside the batch, unknown handles, and sub-floor confidence.
    public struct Verdict: Equatable, Sendable {
        public var assignments: [Assignment]
        public var newTasks: [NewTask]
    }

    public struct Summary: Equatable, Sendable {
        public var assigned: Int
        public var tasksCreated: Int

        public init(assigned: Int = 0, tasksCreated: Int = 0) {
            self.assigned = assigned
            self.tasksCreated = tasksCreated
        }
    }

    // MARK: - Prompt (pure, testable)

    static func prompt(roster: [RosterEntry], blocks: [BlockSample],
                       calendar: Calendar = .current) -> String {
        var lines: [String] = [
            "Group screen-time blocks into the user's high-level tasks — the goal being",
            "pursued, phrased as the user would (\"Applying to YC Startup School",
            "afterparties\", \"Booking flights and planning travel\") — never an app or",
            "website name.",
            "",
            "Existing tasks — reuse one whenever a block continues it:"
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
        lines.append("Blocks, chronological (id, local time, minutes, app, domain, titles, text):")
        let times = timeFormatter(calendar)
        for block in blocks {
            let minutes = max(1, (block.endedAt - block.startedAt) / 60_000)
            let start = Date(timeIntervalSince1970: Double(block.startedAt) / 1_000)
            var desc = "id=\(block.id) \(times.string(from: start)) \(minutes)m"
            desc += " app=\(shortBundle(block.appBundle))"
            if let domain = block.domain { desc += " domain=\(domain)" }
            if let topic = block.topic { desc += " topic=\(topic)" }
            if !block.titles.isEmpty {
                desc += " titles=\(block.titles.prefix(4).joined(separator: " | "))"
            }
            lines.append(desc)
            if !block.textSample.isEmpty { lines.append("  text: \(block.textSample)") }
        }
        lines.append(contentsOf: [
            "",
            "Assign each block to one task: existing (t1…) or new (n1, n2…).",
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

    /// Parses the model's JSON object (tolerating surrounding prose/fences).
    /// `newEntriesKey` lets ThemeClusterer reuse this for its `"new_themes"`
    /// wire key — the shapes are otherwise identical.
    static func parse(_ response: String, newEntriesKey: String = "new_tasks") -> Verdict {
        let empty = Verdict(assignments: [], newTasks: [])
        guard let start = response.firstIndex(of: "{"),
              let end = response.lastIndex(of: "}"), start < end,
              let data = String(response[start...end]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return empty }
        let assignments = (object["assignments"] as? [[String: Any]] ?? [])
            .compactMap { item -> Assignment? in
                guard let id = (item["id"] as? NSNumber)?.int64Value,
                      let task = item["task"] as? String,
                      let confidence = (item["confidence"] as? NSNumber)?.doubleValue
                else { return nil }
                return Assignment(id: id, task: task, confidence: confidence)
            }
        let newTasks = (object[newEntriesKey] as? [[String: Any]] ?? [])
            .compactMap { item -> NewTask? in
                guard let handle = item["handle"] as? String,
                      let title = item["title"] as? String,
                      !title.trimmingCharacters(in: .whitespaces).isEmpty
                else { return nil }
                return NewTask(handle: handle,
                               title: String(title.prefix(80)),
                               gist: (item["gist"] as? String).map { String($0.prefix(200)) })
            }
        return Verdict(assignments: assignments, newTasks: newTasks)
    }

    static func shortBundle(_ bundle: String) -> String {
        bundle.split(separator: ".").last.map(String.init) ?? bundle
    }

    private static func timeFormatter(_ calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE HH:mm"
        formatter.timeZone = calendar.timeZone
        return formatter
    }
}

// MARK: - Pipeline

extension SemanticTaskGrouper {
    /// Unassigned, evidence-bearing blocks in the window, oldest first.
    /// Evidence means a topic, a window title, or captured text — a bare
    /// metadata block gives the model nothing beyond the app name, which the
    /// mechanical key already encodes.
    public static func pendingSamples(
        database: ShifuDatabase, from: Int64, to: Int64, limit: Int = candidateLimit
    ) throws -> [BlockSample] {
        try database.queue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, started_at, ended_at, app_bundle, domain, topic
                FROM activities
                WHERE ended_at > ? AND started_at < ? AND category != 'private'
                  AND sem_key IS NULL AND sem_attempts < ?
                  AND ended_at - started_at >= ?
                  AND (topic IS NOT NULL OR EXISTS (
                        SELECT 1 FROM observations o WHERE o.session_id = activities.id
                          AND (o.window_title IS NOT NULL OR o.text IS NOT NULL)))
                ORDER BY started_at DESC LIMIT ?
                """, arguments: [from, to, maxAttempts, minBlockMs, limit])
            return rows.map { row -> BlockSample in
                let id: Int64 = row["id"]
                let observations = (try? Row.fetchAll(db, sql: """
                    SELECT window_title, text FROM observations
                    WHERE session_id = ? AND (window_title IS NOT NULL OR text IS NOT NULL)
                    LIMIT 5
                    """, arguments: [id])) ?? []
                var titles: [String] = []
                var sample = ""
                for observation in observations {
                    if let title: String = observation["window_title"],
                       !title.isEmpty, !titles.contains(title) {
                        titles.append(title)
                    }
                    if sample.count < textSampleChars, let text: String = observation["text"] {
                        sample += text.prefix(200) + " "
                    }
                }
                return BlockSample(
                    id: id, startedAt: row["started_at"], endedAt: row["ended_at"],
                    appBundle: row["app_bundle"], domain: row["domain"], topic: row["topic"],
                    titles: titles,
                    textSample: String(sample.prefix(textSampleChars))
                        .trimmingCharacters(in: .whitespaces))
            }
            .sorted { $0.startedAt < $1.startedAt }
        }
    }

    /// The most recently active semantic tasks, offered for reuse so ongoing
    /// work keeps landing in the same task across runs and days.
    public static func activeRoster(
        database: ShifuDatabase, now: Date = Date()
    ) throws -> [RosterEntry] {
        let cutoff = Int64(now.timeIntervalSince1970 * 1_000)
            - Int64(rosterWindowDays) * 86_400_000
        return try database.queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT key, name, gist FROM tasks
                WHERE key LIKE 'sem:%' AND last_active_at >= ?
                ORDER BY last_active_at DESC LIMIT ?
                """, arguments: [cutoff, rosterLimit]
            ).map { RosterEntry(key: $0["key"], name: $0["name"], gist: $0["gist"]) }
        }
    }

    /// Groups the window's unassigned blocks with the backend. Batches are
    /// sized by rendered-prompt tokens (CLAUDE.md invariant 7) and the roster
    /// grows as batches create tasks, so one run converges on shared tasks.
    /// A mid-run failure keeps earlier batches' writes; the rest stay queued.
    @discardableResult
    public static func run(
        database: ShifuDatabase, backend: any LLMBackend, from: Int64, to: Int64,
        now: Date = Date(), calendar: Calendar = .current
    ) async throws -> Summary {
        let samples = try pendingSamples(database: database, from: from, to: to)
        guard !samples.isEmpty else { return Summary() }
        var roster = try activeRoster(database: database, now: now)
        let budget = max(512, backend.contextWindowTokens - responseTokenReserve)

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
            let outcome = try apply(parse(response), batch: batch, roster: roster,
                                    database: database, now: now)
            summary.assigned += outcome.assigned
            summary.tasksCreated += outcome.created.count
            roster.append(contentsOf: outcome.created)
        }
        return summary
    }

    /// One batch's verdict reduced to writable facts: task key → confident
    /// in-batch block ids, plus the definition of each *referenced* new task.
    struct Resolved {
        var assignmentsByKey: [String: [Int64]] = [:]
        var newTaskByKey: [String: NewTask] = [:]
    }

    /// Pure validation: drops out-of-batch ids, sub-floor confidence, unknown
    /// handles, and new tasks whose titles slug to nothing. A new task nobody
    /// references is dropped too — no empty task rows. `prefix` is the key
    /// namespace — ThemeClusterer reuses this with `"thm:"`.
    static func resolve(
        _ verdict: Verdict, batch ids: [Int64], roster: [RosterEntry],
        prefix: String = keyPrefix
    ) -> Resolved {
        let batchIDs = Set(ids)
        var keyByHandle: [String: String] = [:]
        for (index, entry) in roster.enumerated() { keyByHandle["t\(index + 1)"] = entry.key }
        var newByKey: [String: NewTask] = [:]
        for newTask in verdict.newTasks where keyByHandle[newTask.handle] == nil {
            let slug = TaskGrouper.slug(newTask.title)
            guard !slug.isEmpty else { continue }
            keyByHandle[newTask.handle] = prefix + slug
            newByKey[prefix + slug] = newTask
        }

        var resolved = Resolved()
        for assignment in verdict.assignments {
            guard batchIDs.contains(assignment.id),
                  assignment.confidence >= confidenceFloor,
                  let key = keyByHandle[assignment.task] else { continue }
            resolved.assignmentsByKey[key, default: []].append(assignment.id)
        }
        resolved.newTaskByKey = newByKey.filter { resolved.assignmentsByKey[$0.key] != nil }
        return resolved
    }

    /// Writes one batch: assignments set `sem_key` (upserting task rows);
    /// every other batch id burns an attempt. Returns tasks actually created.
    static func apply(
        _ verdict: Verdict, batch: [BlockSample], roster: [RosterEntry],
        database: ShifuDatabase, now: Date = Date()
    ) throws -> (assigned: Int, created: [RosterEntry]) {
        let resolved = resolve(verdict, batch: batch.map(\.id), roster: roster)
        let batchEnds = Dictionary(uniqueKeysWithValues: batch.map { ($0.id, $0.endedAt) })
        let nowMs = Int64(now.timeIntervalSince1970 * 1_000)
        return try database.queue.write { db in
            var created: [RosterEntry] = []
            var assignedIDs: Set<Int64> = []
            for (key, ids) in resolved.assignmentsByKey.sorted(by: { $0.key < $1.key }) {
                let lastActive = ids.compactMap { batchEnds[$0] }.max() ?? nowMs
                if let entry = try upsertTask(
                    db, key: key, definition: resolved.newTaskByKey[key],
                    createdAt: nowMs, lastActive: lastActive) {
                    created.append(entry)
                }
                for id in ids {
                    try db.execute(sql: "UPDATE activities SET sem_key = ? WHERE id = ?",
                                   arguments: [key, id])
                    assignedIDs.insert(id)
                }
            }
            for id in Set(batchEnds.keys).subtracting(assignedIDs) {
                try db.execute(
                    sql: "UPDATE activities SET sem_attempts = sem_attempts + 1 WHERE id = ?",
                    arguments: [id])
            }
            return (assignedIDs.count, created)
        }
    }

    /// Creates or touches the task row for one key. Existing rows keep their
    /// name (renames stick) and gist; only `last_active_at` advances. Returns
    /// a roster entry when the row is genuinely new.
    private static func upsertTask(
        _ db: Database, key: String, definition: NewTask?,
        createdAt: Int64, lastActive: Int64
    ) throws -> RosterEntry? {
        let existed = try Int64.fetchOne(
            db, sql: "SELECT id FROM tasks WHERE key = ?", arguments: [key]) != nil
        let name = definition?.title ?? humanize(key: key)
        try db.execute(sql: """
            INSERT INTO tasks (key, name, gist, created_at, last_active_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET
                last_active_at = MAX(last_active_at, excluded.last_active_at),
                gist = COALESCE(tasks.gist, excluded.gist)
            """, arguments: [key, name, definition?.gist, createdAt, lastActive])
        return existed ? nil : RosterEntry(key: key, name: name, gist: definition?.gist)
    }

    /// "sem:booking-flights-to-sf" → "booking flights to sf" — the fallback
    /// display name when a task row has to be minted without an LLM title.
    static func humanize(key: String) -> String {
        key.hasPrefix(keyPrefix)
            ? String(key.dropFirst(keyPrefix.count)).replacingOccurrences(of: "-", with: " ")
            : key
    }
}
