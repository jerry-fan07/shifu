import Foundation
import ShifuCore
import Testing

/// The rail's arithmetic (design.md §3.6) — checked against the buffer states
/// that are awkward to produce on a real machine: one frame, no frames, and
/// nothing but excluded ones.
@Suite struct RewindTimelineTests {
    private let span = RewindTimeline.Span(start: 0, end: 300_000)   // 5 minutes

    private func frame(_ at: Int64, _ bundle: String?, excluded: Bool = false) -> RewindFrame {
        RewindFrame(
            capturedAt: at, path: excluded ? nil : "buffer/\(at).jpg",
            appBundle: bundle, excluded: excluded)
    }

    @Test func anEmptyBufferDrawsNoBands() {
        #expect(RewindTimeline.bands(frames: [], span: span).isEmpty)
    }

    /// One frame is a full rail, not a hairline: what was on screen when it was
    /// taken is what has been on screen since.
    @Test func oneFrameFillsTheRailFromWhereItSits() {
        let bands = RewindTimeline.bands(frames: [frame(150_000, "app")], span: span)

        #expect(bands.count == 1)
        #expect(bands[0].start == 0.5)
        #expect(bands[0].end == 1)
    }

    /// Bands run to the *next* band's start. The seconds between two frames
    /// belong to the app that was there when the earlier one was taken, so the
    /// strip has no gaps in it.
    @Test func consecutiveFramesOfOneAppMergeAndButtTheNextBand() {
        let bands = RewindTimeline.bands(
            frames: [frame(0, "xcode"), frame(60_000, "xcode"), frame(150_000, "safari")],
            span: span)

        #expect(bands.count == 2)
        #expect(bands[0].label == "xcode")
        #expect(bands[0].start == 0)
        #expect(bands[0].end == 0.5)
        #expect(bands[1].label == "safari")
        #expect(bands[1].start == 0.5)
        #expect(bands[1].end == 1)
    }

    /// Excluded stretches are their own band with no label — the hatched gap.
    /// They must never merge with the app on either side of them, or the rail
    /// would claim minutes it never looked at.
    @Test func excludedFramesBecomeTheirOwnUnlabelledBand() {
        let bands = RewindTimeline.bands(
            frames: [
                frame(0, "xcode"),
                frame(100_000, nil, excluded: true),
                frame(200_000, "xcode")
            ],
            span: span)

        #expect(bands.count == 3)
        #expect(bands[1].excluded)
        #expect(bands[1].label == nil)
        #expect(!bands[0].excluded)
        #expect(!bands[2].excluded)
    }

    @Test func aBandRemembersWhichFrameToScrubTo() {
        let bands = RewindTimeline.bands(
            frames: [frame(0, "a"), frame(60_000, "a"), frame(120_000, "b")], span: span)

        #expect(bands[0].frameIndex == 0)
        #expect(bands[1].frameIndex == 2)
    }

    /// The legend prints excluded time rather than dropping it. "1m excluded"
    /// is a fact about the rail worth saying out loud.
    @Test func theLegendCountsExcludedTimeAsItsOwnEntry() {
        let bands = RewindTimeline.bands(
            frames: [frame(0, "xcode"), frame(150_000, nil, excluded: true)], span: span)

        let legend = RewindTimeline.legend(bands: bands, span: span)
        #expect(legend.count == 2)
        #expect(legend.last?.label == nil)
        #expect(legend.last?.ms ?? 0 > 0)
    }

    /// A rewind saved an hour ago has no place on a five-minute rail.
    @Test func marksOutsideTheSpanAreNotDrawn() {
        let inside = SavedRewind(
            id: 1, kind: .rewind, title: "in", createdAt: 0,
            startedAt: 0, endedAt: 150_000, directory: "saved/1")
        let outside = SavedRewind(
            id: 2, kind: .rewind, title: "out", createdAt: 0,
            startedAt: 0, endedAt: 9_000_000, directory: "saved/2")

        let marks = RewindTimeline.marks(saved: [inside, outside], span: span)
        #expect(marks.map(\.id) == [1])
        #expect(marks[0].at == 0.5)
    }

    /// The live end of the rail is named, not stamped: "now" stays true for
    /// the whole second it is on screen, where a clock reading does not.
    @Test func theLastTickSaysNow() {
        let ticks = RewindTimeline.ticks(span: span, count: 6)

        #expect(ticks.count == 6)
        #expect(ticks.last?.label == "now")
        #expect(ticks.first?.at == 0)
        #expect(ticks.last?.at == 1)
    }

    /// The rail covers the *configured* window even when the buffer has only
    /// been filling for a moment — its width is a promise about how far back
    /// you can go, not a report on how much has arrived.
    @Test func theSpanIsTheConfiguredWindowNotTheFramesExtent() {
        let settings = RewindSettings(recording: true, bufferMinutes: 5)
        let span = RewindTimeline.span(now: 1_000_000, settings: settings)

        #expect(span.lengthMs == 300_000)
        #expect(span.end == 1_000_000)
    }
}
