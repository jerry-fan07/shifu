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
/// `CardBuilder` — so an unchanged window stops billing.
///
/// What the model is shown — the weighted roster, the already-grouped blocks
/// around a batch, and each block's sampled evidence — lives in
/// `SemanticTaskEvidence.swift`; this file is the pipeline around it.
public enum SemanticTaskGrouper {
    public static let confidenceFloor = 0.6
    /// Minting a task is held to a higher bar than joining one: the hourly
    /// pass runs on the fast slot, and a mistaken join is one mislabeled
    /// block while a mistaken mint is a roster entry every later batch is
    /// invited to reuse. Below this, the block waits — the daily
    /// reconciliation (TaskReconciler) audits what does get minted.
    public static let newTaskConfidenceFloor = 0.75
    public static let maxAttempts = 3
    /// Blocks shorter than this stay mechanically grouped — a 40-second glance
    /// carries too little intent to be worth tokens.
    public static let minBlockMs: Int64 = 60_000
    /// Cap on candidate blocks per run; the rest wait for the next hour.
    public static let candidateLimit = 60
    /// Cap on blocks per *call*, under the token budget. Long runs of
    /// same-shaped assignment lines make the model's verdicts unstable —
    /// measured 2026-07-31 by replaying one real 60-block prompt: identical
    /// replays agreed on 26% (Qwen3.5-4B) / 49% (9B — one replay assigned all
    /// 60 blocks to a single task) of per-block assignments; batches of 24
    /// stabilized both at 72% / 66% while 12 overfragmented (near-duplicate
    /// minted tasks, hallucinated ids). Applied to every backend: the latch
    /// is a property of generating many uniform lines, not of model size.
    public static let batchBlockLimit = 24
    /// Existing tasks offered for reuse: the most recently active semantic
    /// tasks of the last `rosterWindowDays`.
    public static let rosterLimit = 40
    public static let rosterWindowDays = 14
    /// Roster size on backends too small for the full distribution.
    public static let compactRosterLimit = 12
    /// Backends with at least this much context get the full roster history;
    /// smaller ones (on-device Foundation Models is 4k for prompt *and*
    /// response, invariant 7) get names and gists only.
    public static let fullRosterMinContextTokens = 16_000
    /// Already-grouped blocks shown around a batch as stickiness context.
    static let neighborLimit = 6
    static let compactNeighborLimit = 3
    static let neighborWindowMs: Int64 = 6 * 3_600_000
    /// Observations sampled per block, spread across its whole span.
    static let sampleCount = 5
    static let sourceLimit = 3
    static let urlSampleLimit = 3
    static let urlSegmentLimit = 2
    static let urlSegmentChars = 40
    static let urlTokenChars = 96
    public static let textSampleChars = 300
    public static let responseTokenReserve = 2_000
    public static let keyPrefix = "sem:"

    /// How much history each roster line carries — see
    /// `fullRosterMinContextTokens`.
    public enum RosterDetail: Sendable { case full, compact }

    /// The evidence for one block, as sent to the model. Titles and text come
    /// from `observations`, which `ObservationRecorder` redacted before disk;
    /// `urls` are re-redacted on the way out (`urlToken`). A block with a
    /// `card` carries no titles or text at all — the card *is* its evidence,
    /// ~40 tokens where the raw sampling cost ~180, and cleaner signal.
    public struct BlockSample: Sendable {
        public var id: Int64
        public var startedAt: Int64
        public var endedAt: Int64
        public var appBundle: String
        public var domain: String?
        public var topic: String?
        /// `activities.card` JSON (v20), when CardBuilder has distilled this
        /// block. Rendered via `BlockCard.promptFacts` in place of raw text.
        public var card: String?
        public var titles: [String]
        /// Sanitized "host/seg/seg" page identities — `github.com/org/repo`
        /// says what the domain alone never could.
        public var urls: [String]
        public var textSample: String
        /// Every activity this candidate speaks for. Usually just `[id]`; a
        /// coalesced sub-minute run (SemanticTaskSlivers.swift) carries all
        /// its members, with `id` — the earliest — as the model's handle.
        public var memberIDs: [Int64]
        /// Time actually spent, summed over `memberIDs`. For a run this is
        /// far less than `endedAt - startedAt`, the wall-clock span the
        /// glances hopped across.
        public var activeMs: Int64

        public init(id: Int64, startedAt: Int64, endedAt: Int64, appBundle: String,
                    domain: String?, topic: String?, card: String? = nil,
                    titles: [String], urls: [String] = [], textSample: String,
                    memberIDs: [Int64]? = nil, activeMs: Int64? = nil) {
            self.id = id
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.appBundle = appBundle
            self.domain = domain
            self.topic = topic
            self.card = card
            self.titles = titles
            self.urls = urls
            self.textSample = textSample
            self.memberIDs = memberIDs ?? [id]
            self.activeMs = activeMs ?? (endedAt - startedAt)
        }
    }

    /// One reusable task offered to the model ("t3: Booking flights — …"),
    /// carrying the history that turns the roster from a list into a weighted
    /// prior. The counters cover `rosterWindowDays`; a task minted mid-run has
    /// no logged history yet and reports zeroes until the next run.
    public struct RosterEntry: Sendable {
        public var key: String
        public var name: String
        public var gist: String?
        public var minutes: Int
        public var daysActive: Int
        /// Whole days since the task was last worked; 0 is today.
        public var lastActiveDays: Int
        /// Domains (else app names) the task's time went to, most first.
        public var topSources: [String]

        public init(key: String, name: String, gist: String?, minutes: Int = 0,
                    daysActive: Int = 0, lastActiveDays: Int = 0, topSources: [String] = []) {
            self.key = key
            self.name = name
            self.gist = gist
            self.minutes = minutes
            self.daysActive = daysActive
            self.lastActiveDays = lastActiveDays
            self.topSources = topSources
        }
    }

    /// One already-grouped block near a batch, shown read-only so the model
    /// can see the work the batch sits inside.
    struct NeighborBlock: Sendable {
        var startedAt: Int64
        var endedAt: Int64
        var appBundle: String
        var domain: String?
        var taskKey: String
        var taskName: String
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

    // MARK: - Parsing

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
                // A title that is only the prompt's `<…>` slot slugs to
                // nothing and `resolve` drops the task; a gist has no key to
                // bottom out on, so it is filtered here.
                let gist = (item["gist"] as? String)
                    .flatMap { TaskGrouper.isPlaceholder($0) ? nil : $0 }
                return NewTask(handle: handle,
                               title: String(title.prefix(80)),
                               gist: gist.map { String($0.prefix(200)) })
            }
        return Verdict(assignments: assignments, newTasks: newTasks)
    }
}

// MARK: - Pipeline

extension SemanticTaskGrouper {
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
        let detail: RosterDetail =
            backend.contextWindowTokens >= fullRosterMinContextTokens ? .full : .compact
        // Trimmed once, here rather than in `prompt`: roster indices *are* the
        // `t<n>` handles `resolve` reads back, so the list the model sees and
        // the list the verdict resolves against have to be the same list.
        var roster = try activeRoster(database: database, now: now)
        if detail == .compact { roster = compacted(roster) }
        let budget = max(
            512, backend.contextWindowTokens - backend.responseReserve(responseTokenReserve))

        var summary = Summary()
        var cursor = 0
        while cursor < samples.count {
            let neighbors = try assignedNeighbors(
                database: database, around: samples[cursor].startedAt)
            var batch: [BlockSample] = []
            while cursor < samples.count, batch.count < batchBlockLimit {
                batch.append(samples[cursor])
                cursor += 1
                if batch.count > 1,
                   LLMTokens.estimate(prompt(roster: roster, blocks: batch,
                                             neighbors: neighbors, detail: detail,
                                             calendar: calendar)) > budget {
                    batch.removeLast()
                    cursor -= 1
                    break
                }
            }
            let response = try await backend.complete(
                prompt: prompt(roster: roster, blocks: batch, neighbors: neighbors,
                               detail: detail, calendar: calendar),
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
                  let key = keyByHandle[assignment.task] else { continue }
            let floor = newByKey[key] != nil ? newTaskConfidenceFloor : confidenceFloor
            guard assignment.confidence >= floor else { continue }
            resolved.assignmentsByKey[key, default: []].append(assignment.id)
        }
        resolved.newTaskByKey = newByKey.filter { resolved.assignmentsByKey[$0.key] != nil }
        return resolved
    }

    /// Writes one batch: assignments set `sem_key` (upserting task rows);
    /// every other batch candidate burns an attempt. Both writes cover every
    /// member row of a candidate — one for a plain block, all of them for a
    /// coalesced run. Returns tasks actually created; `assigned` counts rows
    /// written, so the analyzer's "blocks assigned" line stays honest.
    static func apply(
        _ verdict: Verdict, batch: [BlockSample], roster: [RosterEntry],
        database: ShifuDatabase, now: Date = Date()
    ) throws -> (assigned: Int, created: [RosterEntry]) {
        let resolved = resolve(verdict, batch: batch.map(\.id), roster: roster)
        let byHandle = Dictionary(uniqueKeysWithValues: batch.map { ($0.id, $0) })
        let nowMs = Int64(now.timeIntervalSince1970 * 1_000)
        return try database.queue.write { db in
            var created: [RosterEntry] = []
            var assignedHandles: Set<Int64> = []
            var assignedRows = 0
            for (key, ids) in resolved.assignmentsByKey.sorted(by: { $0.key < $1.key }) {
                let lastActive = ids.compactMap { byHandle[$0]?.endedAt }.max() ?? nowMs
                if let entry = try upsertTask(
                    db, key: key, definition: resolved.newTaskByKey[key],
                    createdAt: nowMs, lastActive: lastActive) {
                    created.append(entry)
                }
                for id in ids {
                    let rows = byHandle[id]?.memberIDs ?? [id]
                    try db.execute(sql: """
                        UPDATE activities SET sem_key = ?
                        WHERE id IN (\(databaseQuestionMarks(count: rows.count)))
                        """, arguments: [key] + StatementArguments(rows))
                    assignedHandles.insert(id)
                    assignedRows += rows.count
                }
            }
            // A declined run burns an attempt on every constituent: exhausted
            // members drop out of the next sweep and the run re-forms
            // smaller — no stored run identity, nothing to carry across
            // rebuilds.
            for sample in batch where !assignedHandles.contains(sample.id) {
                try db.execute(sql: """
                    UPDATE activities SET sem_attempts = sem_attempts + 1
                    WHERE id IN (\(databaseQuestionMarks(count: sample.memberIDs.count)))
                    """, arguments: StatementArguments(sample.memberIDs))
            }
            return (assignedRows, created)
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
