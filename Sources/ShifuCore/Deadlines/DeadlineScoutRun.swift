import Foundation
import GRDB

/// The scout as an analyzer stage (design.md §4.7): read what the daemon has
/// captured since the last pass, scan it, record the sightings, retire the
/// proposals whose day has gone.
///
/// Deterministic and free — no model, no network — so it runs on every pass
/// whether or not an LLM backend is configured. The judge (`DeadlineScoutJudge`)
/// is a separate, optional stage over what this one wrote.
public enum DeadlineScoutRun {
    /// Settings key holding the highest `observations.id` already scanned.
    /// Observation ids are stable across ledger rebuilds (a rebuild reassigns
    /// `session_id`, never the row), which is why the watermark is on them and
    /// not on blocks.
    public static let watermarkKey = "deadline_scout.last_observation_id"
    /// Rows per read; a normal hour is ~1,300, a `--rebuild` is the whole
    /// retention window.
    static let chunk = 2_000

    public struct Summary: Equatable, Sendable {
        public var observationsRead = 0
        public var hits = 0
        public var created = 0
        public var expired = 0

        public init() {}
    }

    /// One sighting, as read from the database.
    public struct Sighting: Sendable {
        public var observationID: Int64
        public var source: DeadlineScout.Source
        public var text: String?
        /// `observations.last_seen`: a row still inside the dedupe TTL may yet
        /// grow, so it — and everything after it — waits for the next pass.
        public var lastSeen: Int64
    }

    /// The rows of one read that are safe to scan, and the watermark to leave
    /// behind. Reading stops at the first row the daemon may still be folding
    /// into, *whatever its id*: ids and `last_seen` do not move together, so
    /// a long-lived dashboard row can be older by id than a glance that
    /// closed after it — skipping it and advancing past it would lose it for
    /// good.
    struct Page {
        var ready: [Sighting]
        var watermark: Int64
        /// True when a row was held back, so the caller stops paging.
        var held: Bool
    }

    static func page(_ sightings: [Sighting], after watermark: Int64, now: Int64) -> Page {
        let cutoff = now - ObservationRecorder.dedupeTTLMs
        if let index = sightings.firstIndex(where: { $0.lastSeen >= cutoff }) {
            let ready = Array(sightings[..<index])
            return Page(ready: ready, watermark: sightings[index].observationID - 1, held: true)
        }
        return Page(ready: sightings, watermark: sightings.last?.observationID ?? watermark, held: false)
    }

    /// Scans and records. `reset` starts from the beginning of what is still
    /// in the database — `shifu-analyzer --rebuild` and `shifu due scan --all`.
    @discardableResult
    public static func run(
        database: ShifuDatabase, now: Int64 = Int64(Date().timeIntervalSince1970 * 1_000),
        reset: Bool = false, calendar: Calendar = .current
    ) throws -> Summary {
        var summary = Summary()
        var watermark = reset ? 0 : self.watermark(database: database)
        while true {
            let sightings = try read(database: database, after: watermark)
            guard !sightings.isEmpty else { break }
            let page = page(sightings, after: watermark, now: now)
            summary.observationsRead += page.ready.count
            let scanned = page.ready.map { sighting in
                (sighting, DeadlineScout.scan(text: sighting.text, source: sighting.source, calendar: calendar))
            }
            try database.queue.write { db in
                for (sighting, hits) in scanned where !hits.isEmpty {
                    summary.hits += hits.count
                    summary.created += try DeadlineProposalStore.record(
                        hits, source: sighting.source, db: db, now: now, calendar: calendar)
                }
            }
            watermark = page.watermark
            try Settings.set(watermarkKey, to: String(watermark), database: database)
            if page.held || sightings.count < chunk { break }
        }
        summary.expired = try DeadlineProposalStore.expire(database: database, now: now, calendar: calendar)
        return summary
    }

    /// The scan without the write — what `shifu due scan --dry` prints, and
    /// how the thresholds are re-earned against a dogfood copy.
    public static func preview(
        database: ShifuDatabase, after observationID: Int64 = 0,
        now: Int64 = Int64(Date().timeIntervalSince1970 * 1_000), calendar: Calendar = .current
    ) throws -> [(sighting: Sighting, hit: DeadlineScout.Hit)] {
        var out: [(Sighting, DeadlineScout.Hit)] = []
        var cursor = observationID
        while true {
            let sightings = try read(database: database, after: cursor)
            guard !sightings.isEmpty else { break }
            let page = page(sightings, after: cursor, now: now)
            for sighting in page.ready {
                for hit in DeadlineScout.scan(text: sighting.text, source: sighting.source, calendar: calendar) {
                    out.append((sighting, hit))
                }
            }
            cursor = page.watermark
            if page.held || sightings.count < chunk { break }
        }
        return out
    }

    static func watermark(database: ShifuDatabase) -> Int64 {
        ((try? Settings.get(watermarkKey, database: database)) ?? nil).flatMap(Int64.init) ?? 0
    }

    /// Observations past the watermark, in id order, with the task their
    /// block was filed to if the ledger has placed them. `page` decides which
    /// of them are safe to scan yet.
    static func read(database: ShifuDatabase, after observationID: Int64) throws -> [Sighting] {
        try database.queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT o.id, o.app_bundle, o.window_title, o.url, o.text, o.started_at, o.last_seen, a.task_id
                FROM observations o LEFT JOIN activities a ON a.id = o.session_id
                WHERE o.id > ? AND (o.text IS NOT NULL OR o.window_title IS NOT NULL)
                ORDER BY o.id LIMIT ?
                """, arguments: [observationID, chunk]
            ).map { row in
                Sighting(
                    observationID: row["id"],
                    source: DeadlineScout.Source(
                        appBundle: row["app_bundle"], domain: Sessionizer.domain(of: row["url"]),
                        windowTitle: row["window_title"], taskID: row["task_id"],
                        seenAt: row["started_at"]),
                    text: row["text"], lastSeen: row["last_seen"])
            }
        }
    }
}
