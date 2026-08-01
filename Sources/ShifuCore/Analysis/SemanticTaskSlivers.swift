import Foundation
import GRDB

// Sub-minute runs (design.md §5.3): how glance-sized blocks reach the model.
// Split from SemanticTaskEvidence.swift for length only, the way
// ThemeInheritance.swift is split from ThemeClusterer.swift.
//
// One glance is not worth tokens (`minBlockMs`), but the same app glanced at
// a dozen times in a quarter hour is one act of attention that never shows up
// as a long block — a hop-style tool (Conductor in the dogfood ledger) *only*
// produces slivers, so without pooling, its whole day bottoms out at a
// container `app:` task. Runs pool them: same app and domain, gaps up to
// `sliverRunGapMs`, other apps' blocks freely in between, and the pooled
// active time must clear the same `minBlockMs` one block must. The 48 h
// dogfood window collapsed ~1.4k sliver candidates into ~105 runs this way;
// the single glances left behind are exactly what `minBlockMs` exists for.
//
// A run is assigned all-or-nothing, so hops straddling two intents land on
// one key — bought back by the gap cut, which ends a run at any quarter-hour
// lull. Declines self-heal member by member (`apply`): every constituent
// burns an attempt, exhausted members drop out of the next sweep, and the
// run re-forms smaller — no stored run identity, nothing to carry across
// rebuilds.

extension SemanticTaskGrouper {
    /// Max gap between one glance's end and the next one's start before the
    /// run is cut. 15 min covered 683 of the dogfood window's ~1.4k slivers
    /// (105 runs); 5 min covered 373.
    public static let sliverRunGapMs: Int64 = 15 * 60_000

    /// One sub-minute unplaced block, as read for coalescing.
    struct SliverRow {
        var id: Int64
        var startedAt: Int64
        var endedAt: Int64
        var appBundle: String
        var domain: String?
        var topic: String?

        var durationMs: Int64 { endedAt - startedAt }
    }

    /// Folds slivers into runs: same (app, domain), each glance at most
    /// `gapMs` after the previous one's end, other buckets' blocks freely in
    /// between. Pure, so the cut rule is testable on a literal array.
    static func coalesce(
        _ rows: [SliverRow], gapMs: Int64 = sliverRunGapMs
    ) -> [[SliverRow]] {
        struct Bucket: Hashable {
            var app: String
            var domain: String?
        }
        var runs: [[SliverRow]] = []
        var openRun: [Bucket: Int] = [:]
        for row in rows.sorted(by: { $0.startedAt < $1.startedAt }) {
            let bucket = Bucket(app: row.appBundle, domain: row.domain)
            if let index = openRun[bucket], let last = runs[index].last,
               row.startedAt - last.endedAt <= gapMs {
                runs[index].append(row)
            } else {
                runs.append([row])
                openRun[bucket] = runs.count - 1
            }
        }
        return runs
    }

    /// The window's sub-minute runs as candidates — heaviest pooled time
    /// first, at most `limit`, evidence fetched only for the runs that ship.
    /// Titles and text fan across the whole run through the same
    /// `sampleCount` spread one block gets, so a 20-block run costs the
    /// model no more tokens than one block does.
    static func sliverRuns(
        _ db: Database, from: Int64, to: Int64, limit: Int
    ) throws -> [BlockSample] {
        guard limit > 0 else { return [] }
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, started_at, ended_at, app_bundle, domain, topic
            FROM activities
            WHERE \(candidateClause)
              AND ended_at - started_at < ?
            ORDER BY started_at
            """, arguments: [from, to, to - Sessionizer.gapThresholdMs,
                             maxAttempts, minBlockMs]
        ).map { row in
            SliverRow(id: row["id"], startedAt: row["started_at"],
                      endedAt: row["ended_at"], appBundle: row["app_bundle"],
                      domain: row["domain"], topic: row["topic"])
        }
        typealias PooledRun = (run: [SliverRow], activeMs: Int64)
        let runs: [PooledRun] = coalesce(rows)
            .map { run in
                (run: run, activeMs: run.reduce(Int64(0)) { $0 + $1.durationMs })
            }
            .filter { $0.activeMs >= minBlockMs }
        // Heaviest first *only* to choose which runs make the quota — then
        // back into time order. Returning them by weight used to matter,
        // because long blocks were picked newest-first and runs by weight, so
        // the two quotas interleaved into a sample that jumped around the
        // window. What a batch is shown has to read as a stretch of a day.
        let byWeight = runs.sorted { left, right in
            left.activeMs != right.activeMs
                ? left.activeMs > right.activeMs
                : left.run[0].startedAt < right.run[0].startedAt
        }
        let pooled = byWeight.prefix(limit)
            .sorted { $0.run[0].startedAt < $1.run[0].startedAt }
        return try pooled.map { pooledRun -> BlockSample in
            let run = pooledRun.run
            let members = run.map(\.id)
            let evidence = try blockEvidence(db, blockIDs: members)
            return BlockSample(
                id: run[0].id, startedAt: run[0].startedAt,
                endedAt: run[run.count - 1].endedAt,
                appBundle: run[0].appBundle, domain: run[0].domain,
                topic: run.compactMap(\.topic).first,
                titles: evidence.titles, urls: evidence.urls,
                textSample: evidence.text,
                memberIDs: members, activeMs: pooledRun.activeMs)
        }
    }
}
