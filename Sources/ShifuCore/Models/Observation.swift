import Foundation
import GRDB

/// How an observation's content was obtained (design.md §3.2 capture ladder).
public enum CaptureKind: String, Codable, Sendable {
    case meta       // metadata only: app, title, url
    case ax         // accessibility-tree text extraction
    case ocr        // screenshot → on-device OCR (bitmap discarded)
    case excluded   // app/domain on the exclusion list; no content captured
}

/// One raw screen observation (design.md §3.5).
public struct Observation: Codable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "observations"

    public var id: Int64?
    public var startedAt: Int64        // unix ms
    public var lastSeen: Int64         // unix ms
    public var appBundle: String
    public var windowTitle: String?
    public var url: String?
    public var captureKind: CaptureKind
    public var text: String?
    public var textSimhash: Int64?
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
