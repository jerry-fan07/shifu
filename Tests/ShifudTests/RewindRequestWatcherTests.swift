import Foundation
import ShifuCore
import Testing
@testable import shifud

/// The request watcher (design.md §3.6) — and specifically the one thing it has
/// to refuse.
///
/// The watcher deliberately outlives capture teardown: it is what hears the
/// request, and a watcher torn down by pause could never hear the one that
/// arrives after. That makes *its own* gate the authoritative one. The app also
/// refuses to ask while paused, but that guard reads a polled copy of the pause
/// file — advisory, and racing a pause that started a moment ago.
@MainActor
@Suite struct RewindRequestWatcherTests {
    private struct Harness {
        let watcher: RewindRequestWatcher
        let recorder: RewindRecorder
        let store: RewindStore
        let home: URL
        let root: URL
        let grabs: Counter
    }

    /// Counts screenshots, and remembers what the last one was asked to frame.
    /// A reference type because most of these assertions are that this number
    /// does not move.
    private final class Counter {
        var taken = 0
        var lastRegion: SnipRegion?
    }

    private func makeHarness(recording: Bool = true) throws -> Harness {
        let database = try ShifuDatabase.inMemory()
        try Settings.set(
            SettingsCatalog.rewindRecording, to: recording ? "on" : "off", database: database)

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("rewind-watcher-\(UUID().uuidString)", isDirectory: true)
        let home = scratch.appendingPathComponent("home", isDirectory: true)
        let root = scratch.appendingPathComponent("rewind", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        let store = RewindStore(database: database, root: root)
        let grabs = Counter()
        let recorder = RewindRecorder(
            store: store, database: database, exclusions: try Exclusions(database: database),
            probe: RewindRecorder.Probe(
                frontmost: { ("com.example.app", 1) }, focusedWindow: { _ in nil },
                title: { _ in nil }, webAreaURL: { _ in nil },
                grab: { _, _ in
                    grabs.taken += 1
                    return RewindShot.Result(data: Data([0x01]), width: 960, height: 600)
                }),
            home: home)
        let watcher = RewindRequestWatcher(
            store: store, database: database, recorder: recorder,
            shot: { region in
                grabs.taken += 1
                grabs.lastRegion = region
                return RewindShot.Result(data: Data([0x02]), width: 2_560, height: 1_600)
            },
            vault: VaultStore(root: scratch.appendingPathComponent("vault", isDirectory: true)),
            home: home)
        return Harness(
            watcher: watcher, recorder: recorder, store: store,
            home: home, root: root, grabs: grabs)
    }

    /// **The one that matters.** A request written *after* a pause begins must
    /// not be served. `stop()` clears whatever was already queued; this is the
    /// case that guard cannot cover, and gating on the recording *setting*
    /// would let it through — the setting says what the user wants, not whether
    /// capture is up.
    @Test func aRequestArrivingDuringAPauseIsRefusedAndDropped() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.home) }
        harness.recorder.start()
        await harness.recorder.frameTask?.value
        let before = harness.grabs.taken

        harness.recorder.stop()                       // what pause does
        try RewindRequest.snip.ask(home: harness.home) // …and a click after it
        harness.watcher.serve()

        #expect(harness.grabs.taken == before)
        #expect(!FileManager.default.fileExists(
            atPath: RewindRequest.snip.file(in: harness.home).path))
        #expect(try harness.store.saved().isEmpty)
    }

    @Test func aRewindRequestDuringAPauseIsRefusedTheSameWay() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.home) }
        harness.recorder.start()
        await harness.recorder.frameTask?.value

        harness.recorder.stop()
        try RewindRequest.rewind.ask(home: harness.home)
        harness.watcher.serve()

        // Nothing filed, and nothing left behind to fire when capture returns.
        #expect(try harness.store.saved().isEmpty)
        #expect(RewindRequest.rewind.claim(home: harness.home) == nil)
    }

    /// With recording off the recorder never starts, so the same gate covers it
    /// — a snip while Rewind is off would be the one frame Shifu wrote without
    /// having been asked to record at all.
    @Test func requestsAreRefusedWhileRewindIsOff() throws {
        let harness = try makeHarness(recording: false)
        defer { try? FileManager.default.removeItem(at: harness.home) }
        harness.recorder.start()

        try RewindRequest.snip.ask(home: harness.home)
        harness.watcher.serve()

        #expect(harness.grabs.taken == 0)
    }

    /// And with capture up, it does the thing.
    @Test func aRewindRequestWithCaptureUpFilesTheBuffer() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.home) }
        harness.recorder.start()
        await harness.recorder.frameTask?.value
        #expect(try !harness.store.bufferFrames().isEmpty)

        try RewindRequest.rewind.ask(home: harness.home)
        harness.watcher.serve()

        let saved = try harness.store.saved()
        #expect(saved.count == 1)
        #expect(saved.first?.kind == .rewind)
    }

    /// The box the user dragged has to reach the grab itself, not be cropped
    /// out afterwards — that is what keeps "only what was selected" a property
    /// of the capture rather than of a step something could skip.
    @Test func aDraggedRegionReachesTheGrab() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.home) }
        harness.recorder.start()
        await harness.recorder.frameTask?.value
        let region = SnipRegion(displayID: 7, left: 120, top: 64, width: 400, height: 300)

        try RewindRequest.snip.ask(home: harness.home, region: region)
        harness.watcher.serve()
        try await Task.sleep(for: .milliseconds(200))

        #expect(harness.grabs.lastRegion == region)
        #expect(try harness.store.saved().first?.kind == .snip)
    }

    /// And a snip asked for without one is still the whole display — the shape
    /// the player's "Keep this frame" writes.
    @Test func aSnipWithoutARegionIsTheWholeDisplay() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.home) }
        harness.recorder.start()
        await harness.recorder.frameTask?.value

        try RewindRequest.snip.ask(home: harness.home)
        harness.watcher.serve()
        try await Task.sleep(for: .milliseconds(200))

        #expect(harness.grabs.lastRegion == nil)
        #expect(try harness.store.saved().first?.kind == .snip)
    }
}
