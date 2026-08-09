import Combine
import Foundation
import Testing
@testable import ShifuApp

/// The transport's clock — the one part of playback that is a live timer
/// rather than arithmetic, so the one part `RewindPlaybackTests` cannot reach.
///
/// It runs the main run loop rather than sleeping: this harness starves
/// `Task.sleep`, and a timer that never fires would otherwise pass as a timer
/// that fires perfectly.
@Suite struct RewindClockTests {
    @MainActor @Test func playingPulsesAndPausingStops() {
        let clock = RewindClock()
        var pulses = 0
        var elapsed: [TimeInterval] = []
        let subscription = clock.pulse.sink { seconds in
            pulses += 1
            elapsed.append(seconds)
        }
        defer { subscription.cancel() }

        #expect(!clock.isPlaying)
        clock.play()
        #expect(clock.isPlaying)
        RunLoop.main.run(until: Date().addingTimeInterval(0.34))
        // 30 Hz for a third of a second. Asserted as "several" rather than an
        // exact count — a busy run loop is allowed to be late, and a test that
        // pins the tick count would fail on a loaded machine rather than on a
        // broken clock.
        #expect(pulses >= 3, "the transport did not tick: \(pulses) pulses")
        // Measured wall time, not the nominal interval — playback speed is a
        // lie if the tick reports 1/30 s while taking twice that.
        #expect(elapsed.allSatisfy { $0 > 0 && $0 < 1 })

        clock.pause()
        #expect(!clock.isPlaying)
        let after = pulses
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        #expect(pulses == after, "the transport kept ticking after pause")
    }

    /// Play is idempotent — a second one must not leave a second timer behind
    /// running the footage at double speed with nothing to cancel it.
    @MainActor @Test func playingTwiceLeavesOneTimer() {
        let clock = RewindClock()
        var pulses = 0
        let subscription = clock.pulse.sink { _ in pulses += 1 }
        defer { subscription.cancel() }

        clock.play()
        clock.play()
        RunLoop.main.run(until: Date().addingTimeInterval(0.34))
        clock.pause()
        let single = pulses
        #expect(single >= 3)

        pulses = 0
        clock.play()
        RunLoop.main.run(until: Date().addingTimeInterval(0.34))
        clock.pause()
        // Within a factor of two of one timer's worth, not exactly equal:
        // the point is that the doubled call did not double the rate.
        #expect(Double(single) < Double(pulses) * 2)
    }

    @MainActor @Test func seekingAndRateSurviveTheTransport() {
        let clock = RewindClock()
        #expect(clock.moment == nil)
        #expect(clock.rate == 1)

        clock.seek(to: 1_234)
        clock.cycleRate()
        clock.play()
        defer { clock.pause() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        // Pressing play changes neither — the clock reports the transport, and
        // the page moves the playhead.
        #expect(clock.moment == 1_234)
        #expect(clock.rate == 2)
    }
}
