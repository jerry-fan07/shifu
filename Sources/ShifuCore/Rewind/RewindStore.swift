import Foundation
import GRDB

/// The single write path for everything Rewind puts on disk (design.md §3.6).
///
/// Every frame file and every row goes through here, for the reason
/// `ObservationRecorder` is the only writer of `observations`: a feature that
/// writes pixels needs exactly one place where "what is on disk" and "what the
/// database says is on disk" are made to agree. The two can only drift in one
/// direction — a file with no row is unreachable garbage, a row with no file is
/// a hole in the player — so every operation here **writes the file first and
/// the row second, and deletes the row first and the file second**.
///
/// The store does not decide *when* to capture, or what a frame looks like.
/// It is handed encoded bytes (`RewindRecorder` in `shifud` produces them) and
/// told what was on screen. That split is what keeps this testable without a
/// window server.
public struct RewindStore: Sendable {
    /// Frame files are JPEG: the buffer is a video-shaped thing at 0.2 fps and
    /// PNG would cost roughly 6× the bytes for detail nobody is going to read
    /// off a 960-wide still.
    public static let frameExtension = "jpg"

    private let database: ShifuDatabase
    /// The folder every frame path is relative to. Public so a caller that has
    /// to hand an absolute path to something outside Shifu — the snip note's
    /// link — resolves it the same way the store does.
    public let root: URL

    public init(database: ShifuDatabase, root: URL = ShifuPaths.rewind) {
        self.database = database
        self.root = root
    }

    public var bufferDirectory: URL { root.appendingPathComponent("buffer", isDirectory: true) }
    public var savedDirectory: URL { root.appendingPathComponent("saved", isDirectory: true) }

    /// An encoded frame and the size it came out at — one value because the
    /// bytes and their dimensions are never separately true.
    public struct Bitmap: Sendable, Equatable {
        public var data: Data
        public var width: Int
        public var height: Int

        public init(data: Data, width: Int = 0, height: Int = 0) {
            self.data = data
            self.width = width
            self.height = height
        }
    }

    /// What was on screen when a frame was taken — the three fields a frame row
    /// keeps about its window, passed together because they are one fact about
    /// one moment and get read back as one.
    public struct Source: Sendable, Equatable {
        public var appBundle: String?
        public var windowTitle: String?
        public var url: String?

        public init(
            appBundle: String? = nil, windowTitle: String? = nil, url: String? = nil
        ) {
            self.appBundle = appBundle
            self.windowTitle = windowTitle
            self.url = url
        }
    }

    // MARK: - The rolling buffer

    /// Writes one frame into the buffer.
    ///
    /// A nil `bitmap` records an *excluded moment* — time passed and nothing
    /// was taken, because the frontmost window was on the exclusion list. The
    /// row exists so the rail can draw the gap honestly rather than showing an
    /// unbroken stretch of something that was never watched. Exclusions are
    /// still enforced by the caller before the screenshot (CLAUDE.md
    /// invariant 3); this is the record of that, not the enforcement.
    @discardableResult
    public func appendToBuffer(
        bitmap: Bitmap?, at capturedAt: Int64, source: Source = Source(),
        trigger: String = "tick"
    ) throws -> RewindFrame {
        var frame = RewindFrame(
            capturedAt: capturedAt, appBundle: source.appBundle,
            windowTitle: source.windowTitle, url: source.url, excluded: bitmap == nil,
            width: bitmap?.width ?? 0, height: bitmap?.height ?? 0, trigger: trigger)

        if let data = bitmap?.data {
            let name = "\(capturedAt).\(Self.frameExtension)"
            let relative = "buffer/\(name)"
            try FileManager.default.createDirectory(
                at: bufferDirectory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try data.write(to: bufferDirectory.appendingPathComponent(name), options: .atomic)
            frame.path = relative
            frame.bytes = Int64(data.count)
        }
        try database.queue.write { db in try frame.insert(db) }
        return frame
    }

    /// Drops everything that has aged out of the rolling window, then anything
    /// still over the disk ceiling — oldest first.
    ///
    /// Returns how many frames went. Saved frames are never touched: the whole
    /// point of saving one is that it stops being subject to this.
    @discardableResult
    public func trimBuffer(
        olderThan cutoff: Int64, ceilingBytes: Int64
    ) throws -> Int {
        var dropped = try dropBufferFrames(matching: "captured_at < ?", arguments: [cutoff])

        // The ceiling is a second, independent bound: a run of very busy
        // screens can fill it well inside the time window, and running out of
        // disk is a worse failure than a shorter buffer.
        while try bufferBytes() > ceilingBytes {
            let oldest = try database.queue.read { db in
                try RewindFrame
                    .filter(sql: "rewind_id IS NULL")
                    .order(sql: "captured_at ASC")
                    .limit(32)
                    .fetchAll(db)
            }
            guard !oldest.isEmpty else { break }
            dropped += try delete(frames: oldest)
        }
        return dropped
    }

    /// Thins the buffer's tail to one frame per `bucketMs`, for frames that
    /// have aged past `olderThan` (design.md §3.6).
    ///
    /// This is what makes a two-rate buffer possible without a second capture
    /// path: everything is recorded at the head's rate, and the tail is thinned
    /// behind it as it ages out of the high-fidelity window. Frames stay where
    /// they are; only the surplus goes.
    ///
    /// **Which frame of a bucket survives is not arbitrary.** A bucket keeps
    /// its first *trigger* frame if it has one — the app and window switches
    /// the ladder took deliberately, which are the moments a rewind is usually
    /// looking for — and otherwise its earliest frame. So thinning the tail
    /// never costs a context switch, which would be the one thing worth having
    /// kept. Saved frames are never touched, the same as `trimBuffer`.
    ///
    /// Returns how many frames went.
    @discardableResult
    public func decimateBuffer(olderThan cutoff: Int64, bucketMs: Int64) throws -> Int {
        guard bucketMs > 0 else { return 0 }
        let stale = try database.queue.read { db in
            try RewindFrame
                .filter(sql: "rewind_id IS NULL AND captured_at < ?", arguments: [cutoff])
                .order(sql: "captured_at ASC")
                .fetchAll(db)
        }
        guard !stale.isEmpty else { return 0 }

        var keep: [Int64: RewindFrame] = [:]
        for frame in stale {
            let bucket = frame.capturedAt / bucketMs
            guard let held = keep[bucket] else {
                keep[bucket] = frame
                continue
            }
            // Ordered by time, so `held` is already the earliest seen. It only
            // loses its slot to the bucket's first trigger frame.
            if held.trigger == "tick", frame.trigger != "tick" { keep[bucket] = frame }
        }

        let survivors = Set(keep.values.compactMap(\.id))
        return try delete(frames: stale.filter { $0.id.map { !survivors.contains($0) } ?? false })
    }

    /// The buffer's frames, oldest first, from `since` (nil for all of it).
    public func bufferFrames(since: Int64? = nil) throws -> [RewindFrame] {
        try database.queue.read { db in
            var request = RewindFrame.filter(sql: "rewind_id IS NULL")
            if let since { request = request.filter(sql: "captured_at >= ?", arguments: [since]) }
            return try request.order(sql: "captured_at ASC").fetchAll(db)
        }
    }

    /// What the player's head-up display reads: how much is rewindable right
    /// now, and what it costs.
    public struct BufferState: Sendable, Equatable {
        public var frameCount = 0
        public var bytes: Int64 = 0
        public var earliest: Int64?
        public var latest: Int64?

        public init(
            frameCount: Int = 0, bytes: Int64 = 0,
            earliest: Int64? = nil, latest: Int64? = nil
        ) {
            self.frameCount = frameCount
            self.bytes = bytes
            self.earliest = earliest
            self.latest = latest
        }

        public var spanMs: Int64 {
            guard let earliest, let latest else { return 0 }
            return max(0, latest - earliest)
        }
    }

    public func bufferState() throws -> BufferState {
        try database.queue.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS frames, COALESCE(SUM(bytes), 0) AS bytes,
                       MIN(captured_at) AS earliest, MAX(captured_at) AS latest
                FROM rewind_frames WHERE rewind_id IS NULL
                """)
            else { return BufferState() }
            return BufferState(
                frameCount: row["frames"], bytes: row["bytes"],
                earliest: row["earliest"], latest: row["latest"])
        }
    }

    private func bufferBytes() throws -> Int64 {
        try database.queue.read { db in
            try Int64.fetchOne(db, sql: """
                SELECT COALESCE(SUM(bytes), 0) FROM rewind_frames WHERE rewind_id IS NULL
                """) ?? 0
        }
    }

    // MARK: - Saving

    /// Copies a span of the buffer into a rewind of its own.
    ///
    /// **Copies rather than moves**, and that is not a detail: the buffer keeps
    /// rolling underneath, so a saved rewind that pointed at buffer files would
    /// lose its oldest frames minutes after it was made. Nil when the span
    /// holds no frame with a file — there is nothing to keep, and an empty
    /// rewind on the shelf is worse than the save quietly not happening.
    public func saveRewind(
        from: Int64, to end: Int64, title: String, note: String? = nil, now: Int64,
        retentionDays: Int, taskID: Int64? = nil, themeKey: String? = nil
    ) throws -> SavedRewind? {
        let frames = try database.queue.read { db in
            try RewindFrame
                .filter(sql: "rewind_id IS NULL AND captured_at >= ? AND captured_at <= ?",
                        arguments: [from, end])
                .order(sql: "captured_at ASC")
                .fetchAll(db)
        }
        guard frames.contains(where: { $0.path != nil }) else { return nil }

        var rewind = SavedRewind(
            kind: .rewind, title: title, note: note, createdAt: now,
            startedAt: frames.first?.capturedAt ?? from,
            endedAt: frames.last?.capturedAt ?? end,
            directory: "saved/pending", taskID: taskID, themeKey: themeKey,
            expiresAt: Self.expiry(from: now, retentionDays: retentionDays))
        try database.queue.write { db in try rewind.insert(db) }
        guard let rewindID = rewind.id else { return nil }

        // The folder is named by the row id, so it cannot collide with a
        // rewind saved in the same second by another process.
        rewind.directory = "saved/\(rewindID)"
        let folder = root.appendingPathComponent(rewind.directory, isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])

        var bytes: Int64 = 0
        var kept = 0
        for frame in frames {
            var copy = frame
            copy.id = nil
            copy.rewindID = rewindID
            if let source = frame.url(in: root) {
                let name = "\(frame.capturedAt).\(Self.frameExtension)"
                let destination = folder.appendingPathComponent(name)
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.copyItem(at: source, to: destination)
                copy.path = "\(rewind.directory)/\(name)"
                bytes += frame.bytes
                kept += 1
            }
            try database.queue.write { db in try copy.insert(db) }
        }
        rewind.bytes = bytes
        rewind.frameCount = kept
        let finished = rewind
        try database.queue.write { db in try finished.update(db) }
        return finished
    }

    /// Keeps one frame by hand — the snip. `data` is the fresh screenshot, not
    /// a buffer frame: a snip is worth full quality, and the user asked for
    /// *this* moment rather than the nearest tick to it.
    public func saveSnip(
        bitmap: Bitmap, at capturedAt: Int64, title: String, source: Source = Source(),
        retentionDays: Int, note: String? = nil, taskID: Int64? = nil,
        themeKey: String? = nil, notePath: String? = nil
    ) throws -> SavedRewind {
        let data = bitmap.data
        var rewind = SavedRewind(
            kind: .snip, title: title, note: note, createdAt: capturedAt,
            startedAt: capturedAt, endedAt: capturedAt, directory: "saved/pending",
            bytes: Int64(data.count), frameCount: 1, taskID: taskID, themeKey: themeKey,
            expiresAt: Self.expiry(from: capturedAt, retentionDays: retentionDays),
            notePath: notePath)
        try database.queue.write { db in try rewind.insert(db) }
        guard let rewindID = rewind.id else { return rewind }

        rewind.directory = "saved/\(rewindID)"
        let folder = root.appendingPathComponent(rewind.directory, isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let name = "\(capturedAt).\(Self.frameExtension)"
        try data.write(to: folder.appendingPathComponent(name), options: .atomic)

        var frame = RewindFrame(
            capturedAt: capturedAt, rewindID: rewindID,
            path: "\(rewind.directory)/\(name)", appBundle: source.appBundle,
            windowTitle: source.windowTitle, url: source.url,
            width: bitmap.width, height: bitmap.height,
            bytes: Int64(data.count), trigger: "snip")
        let finished = rewind
        try database.queue.write { db in
            try frame.insert(db)
            try finished.update(db)
        }
        return finished
    }

    /// Nil retention (0 days or fewer) is "keep forever" — the same encoding a
    /// kept rewind uses, so the two states are one column.
    static func expiry(from now: Int64, retentionDays: Int) -> Int64? {
        guard retentionDays > 0 else { return nil }
        return now + Int64(retentionDays) * 86_400_000
    }

    // MARK: - The shelf

    /// Everything kept, newest first.
    public func saved(limit: Int = 200) throws -> [SavedRewind] {
        try database.queue.read { db in
            try SavedRewind.order(sql: "created_at DESC").limit(limit).fetchAll(db)
        }
    }

    public func rewind(id: Int64) throws -> SavedRewind? {
        try database.queue.read { db in try SavedRewind.fetchOne(db, key: id) }
    }

    public func frames(ofRewind rewindID: Int64) throws -> [RewindFrame] {
        try database.queue.read { db in
            try RewindFrame
                .filter(sql: "rewind_id = ?", arguments: [rewindID])
                .order(sql: "captured_at ASC")
                .fetchAll(db)
        }
    }

    /// Out of the retention schedule, permanently. Nothing puts an expiry back.
    public func keepForever(id: Int64) throws {
        _ = try database.queue.write { db in
            try db.execute(sql: "UPDATE rewinds SET expires_at = NULL WHERE id = ?",
                           arguments: [id])
        }
    }

    /// Deletes a rewind, its frame rows and its folder. Row first, then the
    /// files: an orphaned file is garbage, an orphaned row is a hole.
    public func delete(id: Int64) throws {
        guard let rewind = try rewind(id: id) else { return }
        _ = try database.queue.write { db in
            // The frame rows go with it by ON DELETE CASCADE.
            try SavedRewind.deleteOne(db, key: id)
        }
        try? FileManager.default.removeItem(at: rewind.directoryURL(in: root))
    }

    /// Reaps rewinds past their expiry. Runs in the analyzer beside
    /// `Retention.scrubExpiredText` — the daemon owns the *rolling* buffer,
    /// this owns what outlived it. Returns how many went.
    @discardableResult
    public func expireSaved(now: Int64) throws -> Int {
        let due = try database.queue.read { db in
            try SavedRewind
                .filter(sql: "expires_at IS NOT NULL AND expires_at <= ?", arguments: [now])
                .fetchAll(db)
        }
        for rewind in due {
            guard let id = rewind.id else { continue }
            try delete(id: id)
        }
        return due.count
    }

    /// Removes every frame and folder Rewind has ever written, and the rows
    /// with them — what switching recording off, and `shifu forget --rewind`,
    /// both mean. Idempotent.
    public func purgeEverything() throws {
        _ = try database.queue.write { db in
            try db.execute(sql: "DELETE FROM rewind_frames")
            try db.execute(sql: "DELETE FROM rewinds")
        }
        try? FileManager.default.removeItem(at: root)
    }

    /// Drops the rolling buffer alone, keeping everything saved. This is what
    /// switching recording *off* does — a user who stops recording has not
    /// asked to lose the rewinds they deliberately kept.
    @discardableResult
    public func purgeBuffer() throws -> Int {
        try dropBufferFrames(matching: "1 = 1", arguments: [])
    }

    // MARK: - Deleting frames

    private func dropBufferFrames(matching clause: String, arguments: StatementArguments) throws
        -> Int {
        let doomed = try database.queue.read { db in
            try RewindFrame
                .filter(sql: "rewind_id IS NULL AND (\(clause))", arguments: arguments)
                .fetchAll(db)
        }
        return try delete(frames: doomed)
    }

    private func delete(frames: [RewindFrame]) throws -> Int {
        guard !frames.isEmpty else { return 0 }
        let ids = frames.compactMap(\.id)
        _ = try database.queue.write { db in
            try RewindFrame.deleteAll(db, keys: ids)
        }
        for frame in frames {
            if let file = frame.url(in: root) { try? FileManager.default.removeItem(at: file) }
        }
        return frames.count
    }
}
