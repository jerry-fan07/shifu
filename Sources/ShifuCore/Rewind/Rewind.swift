import Foundation
import GRDB

/// The Rewind buffer's models (design.md §3.6).
///
/// Rewind is the one part of Shifu that writes pixels to disk, and the shape
/// of these two records is where that is bounded. A `RewindFrame` is a single
/// low-resolution still with the window identity that was frontmost when it
/// was taken; a `SavedRewind` is the user having asked for a span of them (or
/// one of them) to survive the rolling window.
///
/// Everything else about the feature — the ladder that produces frames, the
/// player that reads them — is wiring over these.

/// One frame. In the rolling buffer while `rewindID` is nil, in a saved
/// rewind once it is set.
public struct RewindFrame: Codable, FetchableRecord, MutablePersistableRecord,
                           Identifiable, Sendable, Equatable {
    public static let databaseTableName = "rewind_frames"

    public var id: Int64?
    public var capturedAt: Int64
    public var rewindID: Int64?
    /// Relative to `ShifuPaths.rewind`. **Nil for an excluded moment** — the
    /// row records that time passed and nothing was taken, which is what the
    /// rail draws as a hatched band. Exclusions are enforced before the
    /// screenshot, never by deleting one afterwards (CLAUDE.md invariant 3).
    public var path: String?
    public var appBundle: String?
    public var windowTitle: String?
    public var url: String?
    public var excluded: Bool
    public var width: Int
    public var height: Int
    public var bytes: Int64
    /// What asked for this frame: `tick`, `window`, or `snip`.
    public var trigger: String

    public init(
        id: Int64? = nil, capturedAt: Int64, rewindID: Int64? = nil, path: String? = nil,
        appBundle: String? = nil, windowTitle: String? = nil, url: String? = nil,
        excluded: Bool = false, width: Int = 0, height: Int = 0, bytes: Int64 = 0,
        trigger: String = "tick"
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.rewindID = rewindID
        self.path = path
        self.appBundle = appBundle
        self.windowTitle = windowTitle
        self.url = url
        self.excluded = excluded
        self.width = width
        self.height = height
        self.bytes = bytes
        self.trigger = trigger
    }

    enum CodingKeys: String, CodingKey {
        case id
        case capturedAt = "captured_at"
        case rewindID = "rewind_id"
        case path
        case appBundle = "app_bundle"
        case windowTitle = "window_title"
        case url
        case excluded
        case width
        case height
        case bytes
        case trigger
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    /// The file on disk, or nil for an excluded moment.
    public func url(in root: URL = ShifuPaths.rewind) -> URL? {
        path.map { root.appendingPathComponent($0) }
    }
}

/// A rewind or a snip the user asked to keep.
public struct SavedRewind: Codable, FetchableRecord, MutablePersistableRecord,
                           Identifiable, Sendable, Equatable {
    public static let databaseTableName = "rewinds"

    /// A span of frames, or one frame kept by hand. The shelf lists both —
    /// they are the same act at two lengths, and separating them into two
    /// places would mean looking in two places for "what did I keep today".
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case rewind
        case snip
    }

    public var id: Int64?
    public var kind: Kind
    public var title: String
    public var note: String?
    public var createdAt: Int64
    public var startedAt: Int64
    public var endedAt: Int64
    /// Relative to `ShifuPaths.rewind`.
    public var directory: String
    public var bytes: Int64
    public var frameCount: Int
    public var taskID: Int64?
    public var themeKey: String?
    /// **Nil is "keep forever."** Taking a rewind out of the retention
    /// schedule is the only thing that clears this, and nothing else puts it
    /// back — an expiry that could be re-derived would make "keep forever"
    /// a wish rather than a state.
    public var expiresAt: Int64?
    /// The vault note a snip wrote, relative to `ShifuPaths.vault`.
    public var notePath: String?

    public init(
        id: Int64? = nil, kind: Kind, title: String, note: String? = nil,
        createdAt: Int64, startedAt: Int64, endedAt: Int64, directory: String,
        bytes: Int64 = 0, frameCount: Int = 0, taskID: Int64? = nil,
        themeKey: String? = nil, expiresAt: Int64? = nil, notePath: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.note = note
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.directory = directory
        self.bytes = bytes
        self.frameCount = frameCount
        self.taskID = taskID
        self.themeKey = themeKey
        self.expiresAt = expiresAt
        self.notePath = notePath
    }

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case title
        case note
        case createdAt = "created_at"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case directory
        case bytes
        case frameCount = "frame_count"
        case taskID = "task_id"
        case themeKey = "theme_key"
        case expiresAt = "expires_at"
        case notePath = "note_path"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public var keptForever: Bool { expiresAt == nil }

    public var durationMs: Int64 { max(0, endedAt - startedAt) }

    public func directoryURL(in root: URL = ShifuPaths.rewind) -> URL {
        root.appendingPathComponent(directory, isDirectory: true)
    }
}
