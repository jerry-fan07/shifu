import AppKit
import Foundation
import ShifuCore

/// The Rewind place's read model and its four verbs (design.md §3.6).
///
/// The app never takes a frame itself — it can't: the daemon holds the Screen
/// Recording grant, the exclusion list and the buffer, and Shifu has no IPC. So
/// "Save a rewind" and "Snip" are `RewindRequest` control files, exactly like
/// pause, and the acknowledgement is the row appearing in a table the app was
/// already polling.
@MainActor
extension LedgerStore {
    // MARK: - Reading

    var rewindStore: RewindStore? {
        (try? db()).map { RewindStore(database: $0) }
    }

    func refreshRewind() {
        guard let database = try? db() else { return }
        rewindSettings = RewindSettings.load(database: database)
        let store = RewindStore(database: database)
        rewindBuffer = (try? store.bufferState()) ?? RewindStore.BufferState()
        rewindFrames = (try? store.bufferFrames()) ?? []
        savedRewinds = (try? store.saved()) ?? []
    }

    /// Frames of one saved rewind, for its own page.
    func frames(ofRewind rewindID: Int64) -> [RewindFrame] {
        (try? rewindStore?.frames(ofRewind: rewindID)) ?? []
    }

    func savedRewind(_ rewindID: Int64) -> SavedRewind? {
        savedRewinds.first { $0.id == rewindID }
    }

    /// The blocks the ledger has for a span — what the rail's task strip and a
    /// rewind's "Blocks" table draw. Read on demand rather than published: a
    /// rewind's page asks for its own five minutes and nothing else wants it.
    func blocks(from: Int64, to end: Int64) -> [LedgerBuilder.LabeledActivity] {
        labeledActivities(
            from: Date(timeIntervalSince1970: Double(from) / 1_000),
            to: Date(timeIntervalSince1970: Double(end) / 1_000))
    }

    // MARK: - The switch

    /// Turning recording on or off. Written to the same settings row the daemon
    /// reads on its next heartbeat, so the switch here and the switch in
    /// Settings are one switch — there is no second copy of this state.
    func setRewindRecording(_ on: Bool) {
        guard let database = try? db() else { return }
        try? Settings.set(SettingsCatalog.rewindRecording, to: on ? "on" : "off",
                          database: database)
        rewindSettings.recording = on
        // Switching off is the one case the app doesn't wait for the daemon on.
        // The daemon drops the buffer within a heartbeat, but "off" should look
        // off *now* — and if no daemon is running, this is the only thing that
        // will ever clear it.
        if !on { try? RewindStore(database: database).purgeBuffer() }
        refreshRewind()
    }

    // MARK: - Asking the daemon

    /// Save the buffer. The daemon does the work; this only leaves the note.
    func saveRewind() {
        ask(.rewind)
    }

    /// Keep this moment, filed with whatever task is running. A `region` is the
    /// box the user dragged in `SnipOverlay`; nil is the whole display.
    func snip(region: SnipRegion? = nil) {
        ask(.snip, region: region)
    }

    /// Drag a box first, then snip it. The overlay is the app's own window —
    /// nothing here captures anything; the rect rides along on the request and
    /// the daemon does the capturing, exactly as with a whole-screen snip.
    func snipRegion() {
        guard !isPaused, rewindSettings.recording else { return }
        SnipOverlay.shared.present { [weak self] region in
            self?.snip(region: region)
        }
    }

    private func ask(_ request: RewindRequest, region: SnipRegion? = nil) {
        // A paused Shifu must not screenshot, and neither must a Shifu that
        // isn't recording — the daemon refuses both, and refusing here too is
        // what keeps the menu from claiming something happened. Re-checked here
        // rather than only at the overlay: a pause can begin mid-drag.
        guard !isPaused, rewindSettings.recording else { return }
        try? request.ask(region: region)
        // The daemon's directory watcher fires within milliseconds and the row
        // lands right after; two seconds is slack, not a race.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.refreshRewind()
        }
    }

    // MARK: - Acting on one

    func keepForever(rewindID: Int64) {
        try? rewindStore?.keepForever(id: rewindID)
        refreshRewind()
    }

    func deleteRewind(_ rewindID: Int64) {
        try? rewindStore?.delete(id: rewindID)
        refreshRewind()
    }

    func revealInFinder(_ rewind: SavedRewind) {
        NSWorkspace.shared.activateFileViewerSelecting([rewind.directoryURL()])
    }
}
