import Foundation
import GRDB

/// The single write path for observations. Applies the text cap, the redaction
/// choke point (§8), and SimHash dedupe (§3.3) before anything reaches SQLite.
public final class ObservationRecorder {
    /// Cap on extracted text per observation (design.md §3.2).
    public static let maxTextBytes = 8 * 1024

    public enum Outcome: Equatable {
        case inserted(id: Int64)
        /// Near-duplicate of the previous observation for this window;
        /// its `last_seen` was bumped instead of inserting a row.
        case refreshed(id: Int64)
    }

    public struct Candidate {
        public var timestamp: Int64          // unix ms
        public var appBundle: String
        public var windowTitle: String?
        public var url: String?
        public var captureKind: CaptureKind
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
    }

    private let database: ShifuDatabase
    private var lastByWindow: [WindowKey: LastRecord] = [:]

    public init(database: ShifuDatabase) {
        self.database = database
    }

    @discardableResult
    public func record(_ candidate: Candidate) throws -> Outcome {
        // Excluded apps contribute duration only — never content (§8).
        let rawText = candidate.captureKind == .excluded ? nil : candidate.text
        let text = rawText.map { Redactor.redact(Self.truncate($0)) }
        let simhash = text.map { SimHash.hash($0) }

        let key = WindowKey(
            appBundle: candidate.appBundle,
            windowTitle: candidate.windowTitle,
            url: candidate.url
        )

        if let last = lastByWindow[key], last.captureKind == candidate.captureKind,
           isNearDuplicate(last.simhash, simhash) {
            try database.queue.write { db in
                try db.execute(
                    sql: "UPDATE observations SET last_seen = ? WHERE id = ?",
                    arguments: [candidate.timestamp, last.id]
                )
            }
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
        lastByWindow[key] = LastRecord(id: id, captureKind: candidate.captureKind, simhash: simhash)
        return .inserted(id: id)
    }

    /// Bumps `last_seen` of the previous observation for this window without
    /// recording new content (used when a dHash gate says the screen is
    /// unchanged). Returns false if there is no previous observation to touch.
    @discardableResult
    public func touch(appBundle: String, windowTitle: String?, url: String?, timestamp: Int64) throws -> Bool {
        let key = WindowKey(appBundle: appBundle, windowTitle: windowTitle, url: url)
        guard let last = lastByWindow[key] else { return false }
        try database.queue.write { db in
            try db.execute(
                sql: "UPDATE observations SET last_seen = ? WHERE id = ?",
                arguments: [timestamp, last.id]
            )
        }
        return true
    }

    private func isNearDuplicate(_ a: UInt64?, _ b: UInt64?) -> Bool {
        switch (a, b) {
        case (nil, nil):
            return true  // both content-free (meta/excluded): same window, just bump last_seen
        case let (a?, b?):
            return SimHash.isNearDuplicate(a, b)
        default:
            return false
        }
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
