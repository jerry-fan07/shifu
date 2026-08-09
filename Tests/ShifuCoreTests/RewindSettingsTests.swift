import Foundation
import ShifuCore
import Testing

/// The dials that decide what Rewind costs (design.md §3.6).
///
/// The two-rate buffer is arithmetic before it is behaviour: one clock drives
/// the recorder, one cutoff bounds the high-fidelity head, and one bucket
/// thins the tail. The recorder, the decimator and the page head all derive
/// theirs from this struct, so a disagreement about "what rate are we running
/// at" is a bug that can only be caught here.
@Suite struct RewindSettingsTests {
    /// The head's rate is the recorder's clock while there is a head. This is
    /// the §3.4 overrun made explicit: 8 fps is a 125 ms timer, forty times the
    /// tick rate the flat buffer ran at.
    @Test func theHotWindowSetsTheCaptureClock() {
        let settings = RewindSettings(
            recording: true, bufferMinutes: 30, frameSeconds: 5, hotMinutes: 5, hotFPS: 8)

        #expect(settings.hasHotWindow)
        #expect(settings.captureInterval == 0.125)
        #expect(settings.hotMs == 300_000)
        #expect(settings.tailBucketMs == 5_000)
    }

    /// The documented way back inside the CPU budget. Zero minutes of head is
    /// not "a head of length zero" — it is the flat, in-budget buffer, and the
    /// recorder must fall all the way back to the tail cadence.
    @Test func aZeroLengthHeadRestoresTheFlatCadence() {
        let settings = RewindSettings(
            recording: true, bufferMinutes: 30, frameSeconds: 5, hotMinutes: 0, hotFPS: 8)

        #expect(!settings.hasHotWindow)
        #expect(settings.captureInterval == 5)
        #expect(settings.hotMs == 0)
    }

    /// 1 fps is the tail cadence's own floor, not a head — treating it as one
    /// would run decimation over a buffer that has nothing to thin.
    @Test func aSingleFramePerSecondIsNotAHead() {
        let settings = RewindSettings(
            recording: true, bufferMinutes: 30, frameSeconds: 5, hotMinutes: 5, hotFPS: 1)

        #expect(!settings.hasHotWindow)
        #expect(settings.captureInterval == 5)
    }

    /// A head longer than the buffer is a buffer with no tail. It must clamp
    /// rather than hand the recorder a cutoff older than the window itself,
    /// which would decimate frames the trim had already promised to keep.
    @Test func aHeadLongerThanTheBufferClampsToIt() {
        let settings = RewindSettings(
            recording: true, bufferMinutes: 5, frameSeconds: 5, hotMinutes: 30, hotFPS: 8)

        #expect(settings.hotMs == settings.bufferMs)
        #expect(settings.hotMs == 300_000)
    }

    /// The page head names both tiers. Promising "30 min at 8 fps" would claim
    /// the head's fidelity for the 25 minutes that no longer have it — and the
    /// depth has to read as the *total*, since "5 min at 8 fps, then 30 min at
    /// one frame every 5s" invites the reader to add them up to 35.
    @Test func theFidelityLineNamesBothTiers() {
        let two = RewindSettings(
            recording: true, bufferMinutes: 30, frameSeconds: 5, hotMinutes: 5, hotFPS: 8)
        #expect(
            two.fidelityLine
                == "5 min at 8 fps, then one frame every 5s out to 30 min, 960 px wide")

        let flat = RewindSettings(
            recording: true, bufferMinutes: 30, frameSeconds: 5, hotMinutes: 0, hotFPS: 8)
        #expect(flat.fidelityLine == "30 min at one frame every 5s, 960 px wide")
    }
}
