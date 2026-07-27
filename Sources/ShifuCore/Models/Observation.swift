import Foundation
import GRDB

/// How an observation's content was obtained (design.md §3.2 capture ladder).
public enum CaptureKind: String, Codable, Sendable {
    case meta       // metadata only: app, title, url
    case ax         // accessibility-tree text extraction
    case ocr        // screenshot → on-device OCR (bitmap discarded)
    case excluded   // app/domain on the exclusion list; no content captured
}

/// One raw screen observation (design.md §3.5) — the daemon's only output and
/// the input to everything downstream.
///
/// A row is not one capture trigger. Consecutive near-duplicate captures of
/// the same window collapse into one row whose `lastSeen` keeps advancing, so
/// an unbroken stretch on one page is a single observation — but only while
/// captures keep arriving inside `ObservationRecorder.dedupeTTLMs` (120 s) of
/// each other. The 60 s heartbeat comfortably clears that during active use;
/// once the user goes idle the heartbeat suspends (`Daemon.idleThreshold`,
/// 300 s), so returning after a break starts a *new* row rather than
/// stretching the old one across time nobody worked through.
/// `ObservationRecorder` owns that logic and is the only writer.
public struct Observation: Codable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "observations"

    public var id: Int64?
    /// Unix ms of the first capture folded into this row.
    public var startedAt: Int64
    /// Unix ms of the most recent capture folded into this row. Equal to
    /// `startedAt` for a row that was never refreshed; `lastSeen - startedAt`
    /// is the observation's duration.
    public var lastSeen: Int64
    /// Bundle identifier, or `unknown.<pid>` for a process without one.
    public var appBundle: String
    /// Nil when Accessibility is unavailable or the app exposes no title.
    public var windowTitle: String?
    /// Browsers only, and only after the exclusion check passed.
    public var url: String?
    /// Which capture-ladder rung produced this row (design.md §3.2).
    public var captureKind: CaptureKind
    /// Extracted text: already redacted and capped at
    /// `ObservationRecorder.maxTextBytes`. Always nil for `.excluded`, and
    /// nulled in place once the row passes the retention window (`Retention`).
    public var text: String?
    /// SimHash of `text`, for near-duplicate detection. Stored as `Int64` via
    /// `Int64(bitPattern:)` because SQLite integers are signed.
    public var textSimhash: Int64?
    /// The `activities.id` this observation was folded into, set by
    /// `LedgerBuilder`. Nil until the analyzer has processed it, and reassigned
    /// on every idempotent rebuild.
    public var sessionId: Int64?

    enum CodingKeys: String, CodingKey {
        case id
        case startedAt = "started_at"
        case lastSeen = "last_seen"
        case appBundle = "app_bundle"
        case windowTitle = "window_title"
        case url
        case captureKind = "capture_kind"
        case text
        case textSimhash = "text_simhash"
        case sessionId = "session_id"
    }

    public init(
        id: Int64? = nil,
        startedAt: Int64,
        lastSeen: Int64? = nil,
        appBundle: String,
        windowTitle: String? = nil,
        url: String? = nil,
        captureKind: CaptureKind,
        text: String? = nil,
        textSimhash: Int64? = nil,
        sessionId: Int64? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.lastSeen = lastSeen ?? startedAt
        self.appBundle = appBundle
        self.windowTitle = windowTitle
        self.url = url
        self.captureKind = captureKind
        self.text = text
        self.textSimhash = textSimhash
        self.sessionId = sessionId
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
