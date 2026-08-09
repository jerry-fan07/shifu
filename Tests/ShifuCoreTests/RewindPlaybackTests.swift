import Foundation
import Testing
@testable import ShifuCore

/// The transport's arithmetic (design.md §3.6).
///
/// Tested here rather than by running a player, because the thing worth
/// asserting is the *model*: a playhead that walks footage time instead of
/// frame indices. Every bug this file guards against is invisible to a test
/// that only checks the transport moved — it moved at the wrong speed, or past
/// the present, or a minute at a time after the app came back from sleep.
@Suite struct RewindPlaybackTests {
    private let start: Int64 = 1_000_000
    private let end: Int64 = 1_000_000 + 300_000  // five minutes of footage

    // MARK: - Rate

    @Test func oneTimesIsOneSecondOfScreenPerSecondOfWallClock() {
        let step = RewindPlayback.advance(
            from: Double(start), rate: 1, elapsed: 0.5, start: start, end: end)
        #expect(step.moment == Double(start) + 500)
        #expect(!step.reachedEnd)
    }

    /// The whole reason the playhead is a moment: the buffer is 8 fps for its
    /// hot head and one frame per five seconds for its tail, so a rate applied
    /// to *indices* would run the tail forty times faster and call it 1×. Time
    /// is the same currency on both sides of that boundary.
    @Test func rateScalesFootageTimeNotFrames() {
        for rate in RewindPlayback.rates {
            let step = RewindPlayback.advance(
                from: Double(start), rate: rate, elapsed: 0.25, start: start, end: end)
            #expect(step.moment == Double(start) + 250 * rate)
        }
    }

    @Test func rateCyclesAndWraps() {
        var rate = RewindPlayback.rates[0]
        for _ in RewindPlayback.rates { rate = RewindPlayback.nextRate(after: rate) }
        #expect(rate == RewindPlayback.rates[0])
        // A rate that isn't on the dial — a stale published value, a future
        // dial — lands back on normal speed rather than nowhere.
        #expect(RewindPlayback.nextRate(after: 3.7) == 1)
    }

    @Test func rateLabelsDropTheTrailingZero() {
        #expect(RewindPlayback.rateLabel(1) == "1×")
        #expect(RewindPlayback.rateLabel(16) == "16×")
        #expect(RewindPlayback.rateLabel(0.5) == "0.5×")
    }

    // MARK: - Bounds

    @Test func playingIntoTheLiveEndStops() {
        let step = RewindPlayback.advance(
            from: Double(end) - 100, rate: 1, elapsed: 0.5, start: start, end: end)
        #expect(step.reachedEnd)
        #expect(step.moment == Double(end))
    }

    /// Playing from a playhead parked at the live end starts the footage over,
    /// the way pressing play on a finished video does — the alternative is a
    /// play button that visibly does nothing.
    @Test func playingFromLiveStartsOver() {
        let step = RewindPlayback.advance(
            from: nil, rate: 1, elapsed: 0.5, start: start, end: end)
        #expect(step.moment == Double(start) + 500)
        #expect(!step.reachedEnd)
    }

    /// A buffer with one frame in it, or none: there is nothing to play, and
    /// the transport has to be told so rather than dividing by the span.
    @Test func footageWithNoLengthIsAlreadyOver() {
        let step = RewindPlayback.advance(
            from: nil, rate: 1, elapsed: 0.5, start: start, end: start)
        #expect(step.reachedEnd)
    }

    /// The app was in the background, the machine slept, the run loop was
    /// blocked laying the page out. Whatever the reason, one tick may not
    /// teleport the playhead across the buffer.
    @Test func aStalledTickIsChargedAtMostOneCap() {
        let step = RewindPlayback.advance(
            from: Double(start), rate: 1, elapsed: 45, start: start, end: end)
        #expect(step.moment == Double(start) + RewindPlayback.maxTickSeconds * 1_000)
    }

    @Test func negativeElapsedNeverRunsBackwards() {
        let step = RewindPlayback.advance(
            from: Double(start) + 1_000, rate: 1, elapsed: -3, start: start, end: end)
        #expect(step.moment == Double(start) + 1_000)
    }

    // MARK: - Skipping

    @Test func skippingBackFromLiveLeavesTheLiveEnd() {
        let step = RewindPlayback.skip(
            from: nil, seconds: -RewindPlayback.skipSeconds, start: start, end: end)
        #expect(step.moment == Double(end) - 10_000)
        #expect(!step.reachedEnd)
    }

    @Test func skippingPastEitherEndClamps() {
        let back = RewindPlayback.skip(from: nil, seconds: -9_999, start: start, end: end)
        #expect(back.moment == Double(start))
        #expect(!back.reachedEnd)

        let forward = RewindPlayback.skip(
            from: Double(start), seconds: 9_999, start: start, end: end)
        #expect(forward.reachedEnd)
        #expect(forward.moment == Double(end))
    }

    // MARK: - Readout

    @Test func durationsReadLikeAPlayersClock() {
        #expect(RewindPlayback.duration(ms: 0) == "0:00")
        #expect(RewindPlayback.duration(ms: 9_400) == "0:09")
        #expect(RewindPlayback.duration(ms: 305_000) == "5:05")
        #expect(RewindPlayback.duration(ms: 3_725_000) == "1:02:05")
        // A trimmed buffer can hand back a negative span for one pass.
        #expect(RewindPlayback.duration(ms: -1_000) == "0:00")
    }
}
