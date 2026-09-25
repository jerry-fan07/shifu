import AppKit
import ShifuCore

/// Watches the two Rewind request files and does what they ask
/// (design.md §3.6).
///
/// The same `DispatchSource`-on-the-home-directory shape as `PauseController`,
/// for the same reason: creation and deletion both register there, and Shifu
/// has no IPC. The difference is what a request *is* — an event, not a state —
/// so `RewindRequest.claim` refuses a stale one and this watcher never has to
/// reason about how long it was asleep.
@MainActor
final class RewindRequestWatcher {
    private let store: RewindStore
    private let database: ShifuDatabase
    private let recorder: RewindRecorder
    private let shot: (SnipRegion?) async throws -> RewindShot.Result?
    private let vault: VaultStore
    private let home: URL?
    private let now: () -> Date

    private var dirSource: DispatchSourceFileSystemObject?
    private var working = false

    init(
        store: RewindStore, database: ShifuDatabase, recorder: RewindRecorder,
        shot: @escaping (SnipRegion?) async throws -> RewindShot.Result?,
        vault: VaultStore = VaultStore(), home: URL? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.database = database
        self.recorder = recorder
        self.shot = shot
        self.vault = vault
        self.home = home
        self.now = now
    }

    func startWatching() {
        let fd = open((home ?? ShifuPaths.home).path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.serve() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        dirSource = source
        serve()
    }

    /// Claims whatever is pending. One at a time: both requests end in a
    /// screenshot, and two of those at once is the CPU spike §3.4 forbids.
    func serve() {
        guard !working else { return }
        // **`isRunning`, not `isRecording`** — the recorder's timer, not the
        // setting. The setting only says the user wants Rewind on; the timer
        // says capture is *actually up*, because `Daemon.startCapture` and
        // `stopCapture` are its only callers. Gating on the setting would honour
        // a request written after a pause began — the watcher outlives the
        // teardown by design, since it has to hear the request that ends it —
        // and a paused Shifu taking a screenshot is precisely what pause
        // promises cannot happen (invariant 5). A locked screen and another
        // user on the console fold in the same way, for free.
        guard recorder.isRunning else {
            RewindRequest.clearAll(home: home)
            return
        }
        if RewindRequest.rewind.claim(now: now(), home: home) != nil {
            saveRewind()
        }
        if let claim = RewindRequest.snip.claim(now: now(), home: home) {
            takeSnip(region: claim.region)
        }
    }

    // MARK: - Save a rewind

    private func saveRewind() {
        let settings = RewindSettings.load(database: database)
        let end = Int64(now().timeIntervalSince1970 * 1_000)
        let start = end - settings.bufferMs
        let context = RewindContext.current(now: end, database: database)
        do {
            let title = "Rewind — " + Self.clock.string(from: now())
            guard let saved = try store.saveRewind(
                from: start, to: end, title: title,
                note: Self.provenance(context), now: end,
                retentionDays: settings.retentionDays,
                taskID: context.taskID, themeKey: context.themeKey)
            else {
                log("rewind requested but the buffer held no frames — nothing saved")
                return
            }
            log("saved \(title): \(saved.frameCount) frames, \(saved.bytes / 1_024) KB")
        } catch {
            log("saving a rewind failed: \(error)")
        }
    }

    // MARK: - Snip

    /// One frame, kept now, filed with whatever is running.
    ///
    /// Takes a *fresh* screenshot rather than the nearest buffered frame: the
    /// user asked for this moment, and the nearest tick can be seconds and a
    /// window change away. A `region` narrows it to the box the user dragged in
    /// the app's overlay; nil is the whole display, which is what the player's
    /// "Keep this frame" still asks for.
    private func takeSnip(region: SnipRegion?) {
        working = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.working = false }
            do {
                guard let frame = try await self.shot(region) else {
                    log("snip requested but no display was capturable")
                    return
                }
                try self.fileSnip(frame)
            } catch {
                log("snip failed: \(error)")
            }
        }
    }

    private func fileSnip(_ frame: RewindShot.Result) throws {
        let taken = now()
        let takenMs = Int64(taken.timeIntervalSince1970 * 1_000)
        let settings = RewindSettings.load(database: database)
        let context = RewindContext.current(now: takenMs, database: database)
        let front = NSWorkspace.shared.frontmostApplication
        let bundle = front?.bundleIdentifier
        let source = front?.localizedName ?? bundle ?? "the screen"
        let title = "Frame — " + Self.clock.string(from: taken)

        // The row first: the note has to name the frame's path, and the path
        // is not known until the row has an id.
        var saved = try store.saveSnip(
            bitmap: RewindStore.Bitmap(
                data: frame.data, width: frame.width, height: frame.height),
            at: takenMs, title: title,
            // No window title: the watcher has no AX probe, and the app's own
            // name in the window-title column is worse than an empty one.
            source: RewindStore.Source(appBundle: bundle),
            retentionDays: settings.retentionDays, note: Self.provenance(context),
            taskID: context.taskID, themeKey: context.themeKey)

        guard let framePath = try store.frames(ofRewind: saved.id ?? 0).first?
            .url(in: store.root)?.path
        else { return }

        let note = SnipNote(
            title: title, captured: SnipNote.stamp(taken), framePath: framePath,
            source: source, taskKey: context.taskKey, taskName: context.taskName,
            themeKey: context.themeKey)
        let url = vault.root.appendingPathComponent(note.relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try note.serialize().write(to: url, atomically: true, encoding: String.Encoding.utf8)

        saved.notePath = note.relativePath
        let finished = saved
        _ = try database.queue.write { db in try finished.update(db) }
        log("snipped \(title) → \(note.relativePath)")
    }

    /// The one line a saved rewind wears on the shelf: where it came from, in
    /// the ledger's own words. Nil-safe — an unattached rewind says so.
    private static func provenance(_ context: RewindContext) -> String {
        guard let task = context.taskName else {
            return "Saved by hand. Not yet filed under a task — the analyzer had "
                + "not reached these minutes."
        }
        if let theme = context.themeName {
            return "Saved by hand while working on \(task), under \(theme)."
        }
        return "Saved by hand while working on \(task)."
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter
    }()
}
