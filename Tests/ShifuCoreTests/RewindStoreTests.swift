import Foundation
import ShifuCore
import Testing

/// The Rewind buffer's write path (design.md §3.6).
///
/// Rewind is the one feature in Shifu that puts pixels on disk, so the tests
/// that matter are the ones about *what stops existing*: the rolling window, the
/// disk ceiling, the retention schedule, and the switch. A frame that outlives
/// any of those is the bug this suite exists to catch.
@Suite struct RewindStoreTests {
    /// A store over a scratch directory and an in-memory database — nothing
    /// here goes near `SHIFU_HOME` or the real `~/Shifu/rewind`.
    private struct Harness {
        let store: RewindStore
        let root: URL
    }

    private func makeStore() throws -> Harness {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rewind-tests-\(UUID().uuidString)", isDirectory: true)
        let database = try ShifuDatabase.inMemory()
        return Harness(store: RewindStore(database: database, root: root), root: root)
    }

    private func bitmap(_ byteCount: Int = 64) -> RewindStore.Bitmap {
        RewindStore.Bitmap(data: Data(repeating: 0xAB, count: byteCount), width: 960, height: 600)
    }

    @Test func aBufferedFrameLandsOnDiskAndInTheIndexTogether() throws {
        let harness = try makeStore()
        let (store, root) = (harness.store, harness.root)
        defer { try? FileManager.default.removeItem(at: root) }

        let frame = try store.appendToBuffer(
            bitmap: bitmap(), at: 1_000,
            source: .init(appBundle: "com.apple.Safari", windowTitle: "Docs"))

        #expect(frame.rewindID == nil)
        #expect(frame.bytes == 64)
        let file = try #require(frame.url(in: root))
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(try store.bufferFrames().count == 1)
    }

    /// An excluded moment is *recorded*, not skipped. The row says time passed
    /// and nothing was taken — which is what lets the rail draw the gap instead
    /// of showing an unbroken stretch of something never watched.
    @Test func anExcludedMomentIsARowWithNoFile() throws {
        let harness = try makeStore()
        let (store, root) = (harness.store, harness.root)
        defer { try? FileManager.default.removeItem(at: root) }

        let frame = try store.appendToBuffer(
            bitmap: nil, at: 2_000, source: .init(appBundle: "com.apple.Passwords"))

        #expect(frame.excluded)
        #expect(frame.path == nil)
        #expect(frame.bytes == 0)
        #expect(try store.bufferFrames().count == 1)
    }

    @Test func trimmingTakesTheFilesWithTheRows() throws {
        let harness = try makeStore()
        let (store, root) = (harness.store, harness.root)
        defer { try? FileManager.default.removeItem(at: root) }

        let old = try store.appendToBuffer(
            bitmap: bitmap(), at: 1_000, source: .init(appBundle: "app"))
        let fresh = try store.appendToBuffer(
            bitmap: bitmap(), at: 9_000, source: .init(appBundle: "app"))
        let oldFile = try #require(old.url(in: root))

        let dropped = try store.trimBuffer(olderThan: 5_000, ceilingBytes: .max)

        #expect(dropped == 1)
        #expect(!FileManager.default.fileExists(atPath: oldFile.path))
        #expect(try store.bufferFrames().map(\.id) == [fresh.id])
    }

    /// The ceiling is a second, independent bound. A run of very busy screens
    /// can fill it well inside the time window, and a full disk is a worse
    /// failure than a shorter rewind.
    @Test func theCeilingDropsTheOldestEvenInsideTheTimeWindow() throws {
        let harness = try makeStore()
        let (store, root) = (harness.store, harness.root)
        defer { try? FileManager.default.removeItem(at: root) }

        for index in 0..<10 {
            try store.appendToBuffer(
            bitmap: bitmap(100), at: Int64(index) * 1_000, source: .init(appBundle: "app"))
        }

        try store.trimBuffer(olderThan: 0, ceilingBytes: 400)

        let left = try store.bufferFrames()
        #expect(try store.bufferState().bytes <= 400)
        // What survives is the *recent* end — the tail thins before the head.
        #expect(left.allSatisfy { $0.capturedAt >= 6_000 })
    }

    @Test func bufferStateReadsTheSpanAndTheCost() throws {
        let harness = try makeStore()
        let (store, root) = (harness.store, harness.root)
        defer { try? FileManager.default.removeItem(at: root) }

        try store.appendToBuffer(
            bitmap: bitmap(10), at: 1_000, source: .init(appBundle: "app"))
        try store.appendToBuffer(
            bitmap: bitmap(20), at: 61_000, source: .init(appBundle: "app"))

        let state = try store.bufferState()
        #expect(state.frameCount == 2)
        #expect(state.bytes == 30)
        #expect(state.spanMs == 60_000)
    }

    // MARK: - Decimating the tail

    /// The two-rate buffer's whole mechanism: everything is captured at the
    /// head's rate, and the tail is thinned to one frame per bucket behind it.
    @Test func decimationThinsTheTailToOneFramePerBucket() throws {
        let harness = try makeStore()
        let (store, root) = (harness.store, harness.root)
        defer { try? FileManager.default.removeItem(at: root) }

        // 40 frames at 125 ms — five whole 1 s buckets.
        for step in 0..<40 {
            try store.appendToBuffer(
                bitmap: bitmap(), at: Int64(step) * 125, source: .init(appBundle: "app"))
        }

        let dropped = try store.decimateBuffer(olderThan: 10_000, bucketMs: 1_000)

        #expect(dropped == 35)
        let survivors = try store.bufferFrames()
        #expect(survivors.count == 5)
        // One per bucket, and the earliest of each — so the thinned tail is
        // evenly spaced rather than clumped at whichever end won.
        #expect(survivors.map(\.capturedAt) == [0, 1_000, 2_000, 3_000, 4_000])
    }

    /// The rule that makes a thinned tail still worth scrubbing: a bucket
    /// containing an app switch keeps *that* frame, not merely its first.
    @Test func decimationKeepsTheWindowSwitchOverTheTick() throws {
        let harness = try makeStore()
        let (store, root) = (harness.store, harness.root)
        defer { try? FileManager.default.removeItem(at: root) }

        try store.appendToBuffer(bitmap: bitmap(), at: 0, source: .init(appBundle: "app"))
        try store.appendToBuffer(bitmap: bitmap(), at: 250, source: .init(appBundle: "app"))
        try store.appendToBuffer(
            bitmap: bitmap(), at: 500, source: .init(appBundle: "other"), trigger: "window")
        try store.appendToBuffer(bitmap: bitmap(), at: 750, source: .init(appBundle: "other"))

        try store.decimateBuffer(olderThan: 10_000, bucketMs: 1_000)

        let survivors = try store.bufferFrames()
        #expect(survivors.count == 1)
        #expect(survivors.first?.capturedAt == 500)
        #expect(survivors.first?.trigger == "window")
    }

    /// Decimation is bounded by the same cutoff the recorder computes from
    /// `hot_minutes`: the high-fidelity head is exactly the part it must not
    /// touch, or the feature would thin away the frames it exists to keep.
    @Test func decimationLeavesTheHighFidelityHeadAlone() throws {
        let harness = try makeStore()
        let (store, root) = (harness.store, harness.root)
        defer { try? FileManager.default.removeItem(at: root) }

        for step in 0..<8 {
            try store.appendToBuffer(
                bitmap: bitmap(), at: Int64(step) * 125, source: .init(appBundle: "app"))
        }
        for step in 0..<8 {
            try store.appendToBuffer(
                bitmap: bitmap(), at: 60_000 + Int64(step) * 125, source: .init(appBundle: "app"))
        }

        // Only the first second is old enough to thin.
        let dropped = try store.decimateBuffer(olderThan: 30_000, bucketMs: 1_000)

        #expect(dropped == 7)
        #expect(try store.bufferFrames().count == 9)
    }

    /// The same exemption every other reaper honours: saving a rewind is what
    /// takes its frames out of the rolling buffer's reach, decimation included.
    @Test func decimationNeverThinsASavedRewind() throws {
        let harness = try makeStore()
        let (store, root) = (harness.store, harness.root)
        defer { try? FileManager.default.removeItem(at: root) }

        for step in 0..<8 {
            try store.appendToBuffer(
                bitmap: bitmap(), at: Int64(step) * 125, source: .init(appBundle: "app"))
        }
        let saved = try #require(
            try store.saveRewind(
                from: 0, to: 1_000, title: "kept", now: 2_000, retentionDays: 14))

        try store.decimateBuffer(olderThan: 10_000, bucketMs: 1_000)

        #expect(try store.frames(ofRewind: #require(saved.id)).count == 8)
    }

    // MARK: - Saving

    /// A saved rewind **copies** its frames. The buffer keeps rolling
    /// underneath, so one that pointed at buffer files would lose its oldest
    /// frames minutes after it was made — which is the whole thing the user
    /// asked not to happen.
    @Test func savingCopiesFramesSoTheRollingTrimCannotReachThem() throws {
        let harness = try makeStore()
        let (store, root) = (harness.store, harness.root)
        defer { try? FileManager.default.removeItem(at: root) }

        for index in 0..<5 {
            try store.appendToBuffer(
            bitmap: bitmap(50), at: Int64(index) * 1_000, source: .init(appBundle: "com.apple.dt.Xcode"))
        }

        let saved = try #require(try store.saveRewind(
            from: 0, to: 4_000, title: "Rewind — 6:38 PM", now: 10_000, retentionDays: 14))

        // The buffer is then trimmed to nothing…
        try store.trimBuffer(olderThan: 9_999, ceilingBytes: .max)
        #expect(try store.bufferFrames().isEmpty)

        // …and the rewind still has all five frames, on disk.
        let frames = try store.frames(ofRewind: try #require(saved.id))
        #expect(frames.count == 5)
        for frame in frames {
            let file = try #require(frame.url(in: root))
            #expect(FileManager.default.fileExists(atPath: file.path))
        }
        #expect(saved.frameCount == 5)
        #expect(saved.bytes == 250)
    }

    /// Nothing to keep means nothing is kept: an empty rewind on the shelf is
    /// worse than the save quietly not happening.
    @Test func savingASpanWithNoFramesKeepsNothing() throws {
        let harness = try makeStore()
        let (store, root) = (harness.store, harness.root)
        defer { try? FileManager.default.removeItem(at: root) }

        try store.appendToBuffer(
            bitmap: nil, at: 1_000, source: .init(appBundle: "com.apple.Passwords"))

        let saved = try store.saveRewind(
            from: 0, to: 5_000, title: "Rewind", now: 6_000, retentionDays: 14)

        #expect(saved == nil)
        #expect(try store.saved().isEmpty)
    }

    @Test func aSnipIsOneFrameWithItsOwnFolder() throws {
        let harness = try makeStore()
        let (store, root) = (harness.store, harness.root)
        defer { try? FileManager.default.removeItem(at: root) }

        let snip = try store.saveSnip(
            bitmap: RewindStore.Bitmap(
                data: Data(repeating: 0xCD, count: 128), width: 2_560, height: 1_600),
            at: 5_000, title: "Frame — pricing table",
            source: .init(appBundle: "com.apple.Safari"), retentionDays: 14)

        #expect(snip.kind == .snip)
        #expect(snip.frameCount == 1)
        #expect(snip.durationMs == 0)
        let frames = try store.frames(ofRewind: try #require(snip.id))
        #expect(frames.count == 1)
        #expect(frames[0].trigger == "snip")
        #expect(FileManager.default.fileExists(
            atPath: try #require(frames[0].url(in: root)).path))
    }

    // MARK: - Retention

    @Test func expiryReapsWhatIsDueAndLeavesWhatIsNot() throws {
        let harness = try makeStore()
        let (store, root) = (harness.store, harness.root)
        defer { try? FileManager.default.removeItem(at: root) }

        try store.appendToBuffer(
            bitmap: bitmap(), at: 1_000, source: .init(appBundle: "app"))
        let doomed = try #require(try store.saveRewind(
            from: 0, to: 2_000, title: "old", now: 1_000, retentionDays: 1))
        try store.appendToBuffer(
            bitmap: bitmap(), at: 3_000, source: .init(appBundle: "app"))
        let safe = try #require(try store.saveRewind(
            from: 3_000, to: 4_000, title: "new", now: 3_000, retentionDays: 90))

        let folder = doomed.directoryURL(in: root)
        let reaped = try store.expireSaved(now: 1_000 + 86_400_000)

        #expect(reaped == 1)
        #expect(try store.saved().map(\.id) == [safe.id])
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    /// "Keep forever" is a *state*, not a longer schedule: a NULL expiry is out
    /// of the reaper's query entirely, and nothing here puts one back.
    @Test func keepForeverTakesARewindOutOfTheSchedule() throws {
        let harness = try makeStore()
        let (store, root) = (harness.store, harness.root)
        defer { try? FileManager.default.removeItem(at: root) }

        try store.appendToBuffer(
            bitmap: bitmap(), at: 1_000, source: .init(appBundle: "app"))
        let saved = try #require(try store.saveRewind(
            from: 0, to: 2_000, title: "keep me", now: 1_000, retentionDays: 1))
        #expect(!saved.keptForever)

        let id = try #require(saved.id)
        try store.keepForever(id: id)
        #expect(try store.expireSaved(now: 1_000 + 86_400_000 * 400) == 0)
        let reread = try #require(try store.rewind(id: id))
        #expect(reread.keptForever)
    }

    /// Deleting a rewind takes its frame rows with it — that is the cascade —
    /// and its folder with those.
    @Test func deletingARewindTakesItsFramesAndItsFolder() throws {
        let harness = try makeStore()
        let (store, root) = (harness.store, harness.root)
        defer { try? FileManager.default.removeItem(at: root) }

        try store.appendToBuffer(
            bitmap: bitmap(), at: 1_000, source: .init(appBundle: "app"))
        let saved = try #require(try store.saveRewind(
            from: 0, to: 2_000, title: "gone", now: 2_000, retentionDays: 14))
        let id = try #require(saved.id)
        let folder = saved.directoryURL(in: root)

        try store.delete(id: id)

        #expect(try store.rewind(id: id) == nil)
        #expect(try store.frames(ofRewind: id).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    /// Switching recording off drops the rolling buffer, and **keeps what the
    /// user deliberately saved**. Stopping the recording is not the same act as
    /// throwing away the rewinds already kept.
    @Test func purgingTheBufferSparesTheSavedRewinds() throws {
        let harness = try makeStore()
        let (store, root) = (harness.store, harness.root)
        defer { try? FileManager.default.removeItem(at: root) }

        try store.appendToBuffer(
            bitmap: bitmap(), at: 1_000, source: .init(appBundle: "app"))
        let saved = try #require(try store.saveRewind(
            from: 0, to: 2_000, title: "kept", now: 2_000, retentionDays: 14))
        try store.appendToBuffer(
            bitmap: bitmap(), at: 3_000, source: .init(appBundle: "app"))

        let dropped = try store.purgeBuffer()

        #expect(dropped == 2)
        #expect(try store.bufferFrames().isEmpty)
        #expect(try store.saved().map(\.id) == [saved.id])
        #expect(try store.frames(ofRewind: try #require(saved.id)).count == 1)
    }
}
