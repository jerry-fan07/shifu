import Foundation
import ShifuCore
import Testing
@testable import ShifuApp

/// The menu bar item's second hand. Worth its own suite because the obvious
/// implementation — a `TimelineView`, like every on-screen surface uses — is
/// silently wrong here: a `MenuBarExtra` label is built once, the timeline
/// fires, and nothing redraws, so the item wears the reading it was born with
/// for the rest of the session. Nothing about that fails a build.
@Suite struct FocusStopwatchTests {
    @MainActor @Test func offUntilThereIsASession() {
        let stopwatch = FocusStopwatch()
        #expect(stopwatch.elapsed == nil)
        stopwatch.follow(startedAt: nil)
        #expect(stopwatch.elapsed == nil)
    }

    /// The reading is available the moment the switch is flipped — waiting for
    /// the first tick would show the mark alone for a second, then jump.
    @MainActor @Test func aSessionReadsImmediately() throws {
        let stopwatch = FocusStopwatch()
        stopwatch.follow(startedAt: Date().addingTimeInterval(-90))
        let elapsed = try #require(stopwatch.elapsed)
        #expect(elapsed >= 90 && elapsed < 92)
    }

    /// Switching off stops the hand *and* clears the number: an item still
    /// wearing a stopwatch is claiming a session that isn't running.
    @MainActor @Test func switchingOffClearsTheReading() {
        let stopwatch = FocusStopwatch()
        stopwatch.follow(startedAt: Date())
        stopwatch.follow(startedAt: nil)
        #expect(stopwatch.elapsed == nil)
    }

    /// `refresh()` republishes the same start many times a minute — from the
    /// window's poll, from every menu open, from every control-file write. If
    /// each one restarted the timer the second hand would never reach a full
    /// second on a busy launch, and the reading would sit still.
    @MainActor @Test func followingTheSameSessionTwiceKeepsTheHandRunning() throws {
        let stopwatch = FocusStopwatch()
        let startedAt = Date().addingTimeInterval(-10)
        stopwatch.follow(startedAt: startedAt)
        let first = try #require(stopwatch.elapsed)

        // Re-announced part-way through the second, the way a menu open does.
        try pump(seconds: 0.6)
        stopwatch.follow(startedAt: startedAt)
        try pump(seconds: 0.8)

        let later = try #require(stopwatch.elapsed)
        #expect(later > first)
    }

    /// A stopped stopwatch keeps no timer: the item is still a still image
    /// whenever Focus Mode is off, which is most of the time.
    @MainActor @Test func aStoppedHandDoesNotTick() throws {
        let stopwatch = FocusStopwatch()
        stopwatch.follow(startedAt: Date().addingTimeInterval(-10))
        stopwatch.follow(startedAt: nil)
        try pump(seconds: 1.3)
        #expect(stopwatch.elapsed == nil)
    }

    /// The timer is on the main run loop, so a test that only sleeps never
    /// lets it fire — the loop has to actually turn.
    @MainActor private func pump(seconds: TimeInterval) throws {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
}
