import Foundation
import GRDB

/// The single write path for observations. Applies the text cap, the redaction
/// choke point (§8), and SimHash dedupe (§3.3) before anything reaches SQLite.
public final class ObservationRecorder {
    /// Cap on extracted text per observation (design.md §3.2).
    public static let maxTextBytes = 8 * 1024

    /// How long a window's dedupe/touch state survives with no activity
    /// before it is treated as gone. Pinned to `Sessionizer.gapThresholdMs`
    /// (not just matched by value): a gap that long already splits an
    /// activity block downstream (design.md §4.1), so letting this state
    /// outlive it would let `record()`/`touch()` bump a row's `last_seen`
    /// across a gap the sessionizer has already decided is discontinuous —
    /// one row would then read as continuous work spanning a gap nobody
    /// worked through. Sharing the constant also bounds `lastByWindow`'s
    /// memory to recently-active windows instead of the daemon's whole
    /// lifetime (design.md §3.4), with no separate size cap needed.
    static let dedupeTTLMs: Int64 = Sessionizer.gapThresholdMs

    /// What `record` did with a candidate. Both cases carry the row now
    /// representing this window, so a caller can tell "new observation" from
    /// "same thing, still going" — the distinction the capture-cost budget in
    /// design.md §3.4 depends on.
    public enum Outcome: Equatable {
        case inserted(id: Int64)
        /// Near-duplicate of the previous observation for this window;
        /// its `last_seen` was bumped instead of inserting a row.
        case refreshed(id: Int64)
    }

    /// A proposed observation, before the write path has had its say.
    ///
    /// This is pre-redaction, pre-cap, pre-dedupe input — `text` here is raw
    /// captured content and must not be persisted, logged, or forwarded by
    /// anyone but `record`. What actually lands on disk is the `Observation`
    /// that `record` builds, and only after `Redactor.redact` has run.
    public struct Candidate {
        /// Unix ms of the capture that produced this candidate. Also drives
        /// dedupe-state expiry, so it must be a real capture time — not a
        /// backdated or replayed value from an unrelated clock.
        public var timestamp: Int64
        public var appBundle: String
        public var windowTitle: String?
        public var url: String?
        public var captureKind: CaptureKind
        /// Raw extracted text, or nil for content-free rungs. Dropped entirely
        /// when `captureKind` is `.excluded`, before redaction even runs.
        public var text: String?

        public init(
            timestamp: Int64,
            appBundle: String,
            windowTitle: String? = nil,
            url: String? = nil,
            captureKind: CaptureKind,
            text: String? = nil
        ) {
            self.timestamp = timestamp
            self.appBundle = appBundle
            self.windowTitle = windowTitle
            self.url = url
            self.captureKind = captureKind
            self.text = text
        }
    }

    private struct WindowKey: Hashable {
        let appBundle: String
        let windowTitle: String?
        let url: String?
    }

    private struct LastRecord {
        let id: Int64
        let captureKind: CaptureKind
        let simhash: UInt64?
        /// Unix ms of the most recent activity on this window: the initial
        /// insert, a `record()` dedupe hit, or a `touch()`. Refreshed on
        /// every one of those so an actively-observed window's TTL keeps
        /// sliding forward and the entry never goes stale mid-observation
        /// (design.md §10 "one observation for the whole movie").
        let updatedAt: Int64
    }

    private let database: ShifuDatabase
    private var lastByWindow: [WindowKey: LastRecord] = [:]
    /// Unix ms `lastByWindow` was last swept of expired entries; see `sweepIfDue`.
    private var lastSweepAt: Int64 = 0

    public init(database: ShifuDatabase) {
        self.database = database
    }

    /// Windows currently tracked for dedupe/touch state, including any past
    /// their TTL but not yet swept. Test-only window into the design.md
    /// §3.4 memory bound.
    var trackedWindowCount: Int { lastByWindow.count }

    @discardableResult
    public func record(_ candidate: Candidate) throws -> Outcome {
        // Age out anything past the TTL before processing this candidate —
        // see `sweepIfDue`.
        sweepIfDue(now: candidate.timestamp)

        // Excluded apps contribute duration only — never content (§8).
        let rawText = candidate.captureKind == .excluded ? nil : candidate.text
        let text = rawText.map { Redactor.redact(Self.truncate($0)) }
        let simhash = text.map { SimHash.hash($0) }

        let key = WindowKey(
            appBundle: candidate.appBundle,
            windowTitle: candidate.windowTitle,
            url: candidate.url
        )

        if let last = liveRecord(for: key, at: candidate.timestamp), last.captureKind == candidate.captureKind,
           isNearDuplicate(last.simhash, simhash) {
            try database.queue.write { db in
                try db.execute(
                    sql: "UPDATE observations SET last_seen = ? WHERE id = ?",
                    arguments: [candidate.timestamp, last.id]
                )
            }
            // Renew: this window is still active, so slide its TTL forward
            // instead of letting it expire out from under a live session.
            lastByWindow[key] = LastRecord(
                id: last.id, captureKind: last.captureKind, simhash: last.simhash, updatedAt: candidate.timestamp
            )
            return .refreshed(id: last.id)
        }

        var observation = Observation(
            startedAt: candidate.timestamp,
            appBundle: candidate.appBundle,
            windowTitle: candidate.windowTitle,
            url: candidate.url,
            captureKind: candidate.captureKind,
            text: text,
            textSimhash: simhash.map { Int64(bitPattern: $0) }
        )
        try database.queue.write { db in
            try observation.insert(db)
        }
        guard let id = observation.id else {
            fatalError("insert returned no rowID")
        }
        lastByWindow[key] = LastRecord(
            id: id, captureKind: candidate.captureKind, simhash: simhash, updatedAt: candidate.timestamp
        )
        return .inserted(id: id)
    }

    /// Bumps `last_seen` of the previous observation for this window without
    /// recording new content (used when a dHash gate says the screen is
    /// unchanged). Returns false if there is no live previous observation to
    /// touch — either none was ever recorded, or its dedupe state has aged
    /// out past `dedupeTTLMs`.
    @discardableResult
    public func touch(appBundle: String, windowTitle: String?, url: String?, timestamp: Int64) throws -> Bool {
        let key = WindowKey(appBundle: appBundle, windowTitle: windowTitle, url: url)
        guard let last = liveRecord(for: key, at: timestamp) else { return false }
        try database.queue.write { db in
            try db.execute(
                sql: "UPDATE observations SET last_seen = ? WHERE id = ?",
                arguments: [timestamp, last.id]
            )
        }
        // Renew, same as the record() dedupe-hit path: still active, so keep sliding the TTL.
        lastByWindow[key] = LastRecord(
            id: last.id, captureKind: last.captureKind, simhash: last.simhash, updatedAt: timestamp
        )
        return true
    }

    private func isNearDuplicate(_ lhs: UInt64?, _ rhs: UInt64?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true  // both content-free (meta/excluded): same window, just bump last_seen
        case let (lhsVal?, rhsVal?):
            return SimHash.isNearDuplicate(lhsVal, rhsVal)
        default:
            return false
        }
    }

    /// Looks up `key`'s dedupe state, treating it as absent once its last
    /// activity is `dedupeTTLMs` or more behind `timestamp` — even though the
    /// entry may still be physically present in `lastByWindow` until the next
    /// `sweepIfDue`. This read-time check alone cannot bound memory (a window
    /// that is never looked up again would never be noticed as stale); it
    /// only stops a stale entry from being reused. `sweepIfDue` is what
    /// actually removes it (design.md §3.4).
    private func liveRecord(for key: WindowKey, at timestamp: Int64) -> LastRecord? {
        guard let record = lastByWindow[key], isLive(record, at: timestamp) else { return nil }
        return record
    }

    private func isLive(_ record: LastRecord, at timestamp: Int64) -> Bool {
        timestamp - record.updatedAt < Self.dedupeTTLMs
    }

    /// Drops expired entries from `lastByWindow`, at most once per
    /// `dedupeTTLMs`. Driven off candidate/touch timestamps rather than wall
    /// clock, so replaying the synthetic feed or a test's fabricated
    /// timestamps is deterministic (design.md §3.4). An O(n) pass no more
    /// than once per TTL window is cheap enough that a fancier structure
    /// (heap, LRU list) isn't worth it here (minimalism rule).
    private func sweepIfDue(now: Int64) {
        guard now - lastSweepAt >= Self.dedupeTTLMs else { return }
        lastByWindow = lastByWindow.filter { isLive($0.value, at: now) }
        lastSweepAt = now
    }

    static func truncate(_ text: String) -> String {
        guard text.utf8.count > maxTextBytes else { return text }
        var result = text
        while result.utf8.count > maxTextBytes {
            result.removeLast()
        }
        return result
    }
}
