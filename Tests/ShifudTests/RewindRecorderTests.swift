import ApplicationServices
import Foundation
import ShifuCore
import Testing
@testable import shifud

/// The Rewind recorder (design.md §3.6) — the one thing in Shifu that puts
/// pixels on disk.
///
/// Every test here is about a screenshot that must **not** be taken. The
/// recorder's happy path is one timer and one file write; what needs pinning is
/// the set of conditions under which the grab is never reached at all, because
/// each of those is a promise the app makes on its own privacy banner.
@MainActor
@Suite struct RewindRecorderTests {
    /// Records what the recorder asked the outside world for, and — the point
    /// of the whole seam — whether it ever asked for pixels.
    private final class Spy {
        var bundle = "com.apple.dt.Xcode"
        var title: String?
        var url: String?
        var window: AXUIElement? = AXUIElementCreateApplication(getpid())
        var grabCount = 0
        var lastExcludedBundles: Set<String> = []
        var shot: RewindShot.Result? = RewindShot.Result(
            data: Data(repeating: 0x11, count: 128), width: 960, height: 600)

        func probe() -> RewindRecorder.Probe {
            RewindRecorder.Probe(
                frontmost: { (self.bundle, 1_234) },
                focusedWindow: { _ in self.window },
                title: { _ in self.title },
                webAreaURL: { _ in self.url },
                grab: { _, excluded in
                    self.grabCount += 1
                    self.lastExcludedBundles = excluded
                    return self.shot
                })
        }
    }

    private final class FakeClock {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        func advance(_ seconds: TimeInterval) { now.addTimeInterval(seconds) }
    }

    private struct Harness {
        let recorder: RewindRecorder
        let store: RewindStore
        let spy: Spy
        let clock: FakeClock
        let root: URL
        let home: URL
        let database: ShifuDatabase
    }

    /// `hotMinutes` defaults to 0 — the flat, one-rate buffer. Most of what
    /// this suite asserts (exclusions, the switch, teardown) is about the
    /// capture path and is indifferent to the rate, and pinning the default
    /// here keeps those tests reading as the plain statements they are. The
    /// two-rate behaviour is asked for explicitly by the tests that are about
    /// it.
    private func makeHarness(
        recording: Bool = true, excludingBundles: [String] = [],
        excludingDomains: [String] = [], bufferMinutes: Int = 5,
        hotMinutes: Int = 0, hotFPS: Int = 8
    ) throws -> Harness {
        let database = try ShifuDatabase.inMemory()
        try database.queue.write { db in
            for bundle in excludingBundles {
                try db.execute(sql: "INSERT INTO exclusions (kind, value) VALUES ('bundle', ?)",
                               arguments: [bundle])
            }
            for domain in excludingDomains {
                try db.execute(sql: "INSERT INTO exclusions (kind, value) VALUES ('domain', ?)",
                               arguments: [domain])
            }
        }
        try Settings.set(
            SettingsCatalog.rewindRecording, to: recording ? "on" : "off", database: database)
        try Settings.set(SettingsCatalog.rewindBufferMinutes, to: bufferMinutes, database: database)
        try Settings.set(SettingsCatalog.rewindHotMinutes, to: hotMinutes, database: database)
        try Settings.set(SettingsCatalog.rewindHotFPS, to: hotFPS, database: database)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rewind-recorder-\(UUID().uuidString)", isDirectory: true)
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("rewind-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let store = RewindStore(database: database, root: root)
        let spy = Spy()
        let clock = FakeClock()
        return Harness(
            recorder: RewindRecorder(
                store: store, database: database,
                exclusions: try Exclusions(database: database),
                probe: spy.probe(), home: home, now: { clock.now },
                schedulesOnRunLoop: false),
            store: store, spy: spy, clock: clock, root: root, home: home, database: database)
    }

    /// Awaits the in-flight grab, which is a `Task` the recorder kicks off.
    private func settle(_ harness: Harness) async {
        await harness.recorder.frameTask?.value
    }

    // MARK: - The switch

    /// The master switch is not a filter on the output — nothing is asked for
    /// at all. A recorder that grabbed and then discarded would still be a
    /// process reading your screen every five seconds.
    @Test func recordingOffNeverReachesTheScreen() async throws {
        let harness = try makeHarness(recording: false)
        defer { try? FileManager.default.removeItem(at: harness.root) }

        harness.recorder.start()
        harness.recorder.captureFrame(trigger: "tick")
        await settle(harness)

        #expect(harness.spy.grabCount == 0)
        #expect(!harness.recorder.isRunning)
        #expect(try harness.store.bufferFrames().isEmpty)
    }

    @Test func recordingOnWritesAFrameWithItsWindowIdentity() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        harness.spy.title = "InstrumentMarks.swift"

        harness.recorder.start()
        await settle(harness)

        let frames = try harness.store.bufferFrames()
        #expect(frames.count == 1)
        #expect(frames[0].appBundle == "com.apple.dt.Xcode")
        #expect(frames[0].windowTitle == "InstrumentMarks.swift")
        #expect(frames[0].path != nil)
        #expect(FileManager.default.fileExists(
            atPath: try #require(frames[0].url(in: harness.root)).path))
    }

    /// Flipping the switch off is not "stop taking new ones" — the buffer stops
    /// existing. Leaving five minutes of frames to age out would mean the
    /// switch didn't do what its label says for another five minutes.
    @Test func switchingOffDropsTheBufferImmediately() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        harness.recorder.start()
        await settle(harness)
        #expect(try !harness.store.bufferFrames().isEmpty)

        try Settings.set(SettingsCatalog.rewindRecording, to: "off", database: harness.database)
        harness.recorder.reloadSettings()

        #expect(try harness.store.bufferFrames().isEmpty)
        #expect(!harness.recorder.isRunning)
    }

    // MARK: - Exclusions, before the screenshot (invariant 3)

    /// The assertion that matters: an excluded app reaches **no grab at all**.
    /// Not a frame that is thrown away, not a frame that is redacted — the
    /// screenshot never happens.
    @Test func anExcludedBundleIsNeverScreenshotted() async throws {
        let harness = try makeHarness(excludingBundles: ["com.apple.Passwords"])
        defer { try? FileManager.default.removeItem(at: harness.root) }
        harness.spy.bundle = "com.apple.Passwords"

        harness.recorder.start()
        await settle(harness)

        #expect(harness.spy.grabCount == 0)
        // …and the gap is still recorded, so the rail can draw it honestly.
        let frames = try harness.store.bufferFrames()
        #expect(frames.count == 1)
        #expect(frames[0].excluded)
        #expect(frames[0].path == nil)
    }

    @Test func aPrivateBrowserWindowIsNeverScreenshotted() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        harness.spy.bundle = "com.apple.Safari"
        harness.spy.title = "Private Browsing"

        harness.recorder.start()
        await settle(harness)

        #expect(harness.spy.grabCount == 0)
        #expect(try harness.store.bufferFrames()[0].excluded)
    }

    @Test func anExcludedDomainIsNeverScreenshotted() async throws {
        let harness = try makeHarness(excludingDomains: ["mybank.com"])
        defer { try? FileManager.default.removeItem(at: harness.root) }
        harness.spy.bundle = "com.apple.Safari"
        harness.spy.url = "https://www.mybank.com/accounts"

        harness.recorder.start()
        await settle(harness)

        #expect(harness.spy.grabCount == 0)
        #expect(try harness.store.bufferFrames()[0].excluded)
    }

    /// The display grab sees more than the frontmost window, so the excluded
    /// bundles go *into the capture filter* — an excluded app sitting behind
    /// the one you're using is never in the bitmap either.
    @Test func theGrabIsToldWhichApplicationsToLeaveOut() async throws {
        let harness = try makeHarness(excludingBundles: ["com.apple.Passwords"])
        defer { try? FileManager.default.removeItem(at: harness.root) }

        harness.recorder.start()
        await settle(harness)

        #expect(harness.spy.grabCount == 1)
        #expect(harness.spy.lastExcludedBundles.contains("com.apple.Passwords"))
    }

    // MARK: - Cadence

    /// "…or sooner if a window trigger occurs" — the switch itself is what a
    /// rewind most needs a frame of.
    @Test func aWindowTriggerTakesAFrameWithoutWaitingForTheTick() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        harness.recorder.start()
        await settle(harness)

        harness.clock.advance(2)
        harness.recorder.noteTrigger()
        await settle(harness)

        #expect(try harness.store.bufferFrames().count == 2)
    }

    /// Title churn arrives in bursts at the 500 ms debounce. A display grab per
    /// burst member is several per second on the daemon's main actor, which is
    /// the §3.4 CPU budget's worst enemy.
    @Test func triggersInsideTheFloorDoNotStackUpFrames() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        harness.recorder.start()
        await settle(harness)

        for _ in 0..<5 {
            harness.clock.advance(0.1)
            harness.recorder.noteTrigger()
            await settle(harness)
        }

        #expect(harness.spy.grabCount == 1)
    }

    /// With the high-fidelity head on, the same floor would swallow every
    /// switch — a tick is never more than 125 ms old at 8 fps, so a 1 s floor
    /// means `noteTrigger` always bails and nothing is ever labelled `"window"`.
    /// Tail decimation keeps a bucket *by* that label, so the flat floor would
    /// quietly cost the thinned tail its context switches.
    @Test func aWindowSwitchStillEarnsItsOwnFrameAtTheHotRate() async throws {
        let harness = try makeHarness(hotMinutes: 5, hotFPS: 8)
        defer { try? FileManager.default.removeItem(at: harness.root) }
        harness.recorder.start()
        await settle(harness)

        // Past one capture interval (125 ms), inside the flat 1 s floor.
        harness.clock.advance(0.2)
        harness.recorder.noteTrigger()
        await settle(harness)

        #expect(harness.spy.grabCount == 2)
        let frames = try harness.store.bufferFrames()
        #expect(frames.count == 2)
        #expect(frames.last?.trigger == "window")
    }

    /// The head is still a floor, not an invitation: title churn arriving
    /// faster than the capture rate must not stack grabs on the main actor.
    @Test func theHotRateIsStillAFloorAgainstChurn() async throws {
        let harness = try makeHarness(hotMinutes: 5, hotFPS: 8)
        defer { try? FileManager.default.removeItem(at: harness.root) }
        harness.recorder.start()
        await settle(harness)

        for _ in 0..<5 {
            harness.clock.advance(0.02)
            harness.recorder.noteTrigger()
            await settle(harness)
        }

        #expect(harness.spy.grabCount == 1)
    }

    /// The rolling window is what makes this "the last five minutes" rather
    /// than "everything since the daemon started".
    @Test func framesOlderThanTheWindowAreGoneByTheNextFrame() async throws {
        let harness = try makeHarness(bufferMinutes: 1)
        defer { try? FileManager.default.removeItem(at: harness.root) }

        harness.recorder.start()
        await settle(harness)
        let first = try harness.store.bufferFrames()
        let firstFile = try #require(first[0].url(in: harness.root))

        harness.clock.advance(120)
        harness.recorder.captureFrame(trigger: "tick")
        await settle(harness)

        let left = try harness.store.bufferFrames()
        #expect(left.count == 1)
        #expect(left[0].capturedAt > first[0].capturedAt)
        #expect(!FileManager.default.fileExists(atPath: firstFile.path))
    }

    /// Stopping clears any request the app had queued: a "save a rewind" click
    /// a moment before a pause must not survive the pause.
    @Test func stoppingDropsPendingRequests() async throws {
        let harness = try makeHarness()
        defer {
            try? FileManager.default.removeItem(at: harness.root)
            try? FileManager.default.removeItem(at: harness.home)
        }
        harness.recorder.start()

        try RewindRequest.rewind.ask(home: harness.home)
        harness.recorder.stop()

        #expect(RewindRequest.rewind.claim(home: harness.home) == nil)
        #expect(!harness.recorder.isRunning)
    }
}
