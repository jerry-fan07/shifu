import ShifuCore
import SwiftUI

// The rail under the player (design.md §3.6): four strips over one span, an
// axis under them, and a playhead across the lot. Every position on it comes
// from `RewindTimeline`, which is where the arithmetic is tested.

/// The scrubber. Click anywhere on it to move the playhead there.
struct RewindRail: View {
    let bands: [RewindTimeline.Band]
    let marks: [RewindTimeline.Mark]
    let taskBands: [RewindTimeline.Band]
    let ticks: [(at: Double, label: String)]
    /// What the band over the strips says this footage *is* — the running
    /// fidelity for the live buffer, the clip's own shape for a saved one.
    let fidelity: String
    /// Where the playhead sits, 0…1.
    let playhead: Double
    let onScrub: (Double) -> Void

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 5) {
                    markStrip(width: width)
                    fidelityStrip(width: width)
                    appStrip(width: width)
                    if !taskBands.isEmpty { taskStrip(width: width) }
                    axis(width: width)
                }
                playheadLine(width: width)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { onScrub(min(1, max(0, $0.location.x / max(1, width)))) })
        }
        .frame(height: taskBands.isEmpty ? 92 : 110)
    }

    // MARK: - Strips

    /// Where something was saved from. A tick and a square, in `beacon` — the
    /// one mark colour that is neither a series nor a count.
    private func markStrip(width: CGFloat) -> some View {
        ZStack(alignment: .bottomLeading) {
            Color.clear
            ForEach(marks) { mark in
                VStack(spacing: 1) {
                    Rectangle()
                        .fill(Instrument.beacon)
                        .frame(width: 5, height: 5)
                    Rectangle()
                        .fill(Instrument.beacon)
                        .frame(width: 1, height: 6)
                }
                .offset(x: width * mark.at - 2.5)
                .help(mark.title)
            }
        }
        .frame(height: 11)
    }

    /// What fidelity this footage is held at, and how much of the rail it
    /// actually covers.
    ///
    /// **One tier, filled from the right.** Shifu keeps every frame in the
    /// window at the same low resolution, so there is no hi/lo split to draw —
    /// what the band's *length* says instead is how much of the configured
    /// window has arrived. A buffer that has been filling for one minute of
    /// five is a fifth of a rail, which is the honest picture of how far back
    /// you can actually go right now.
    private func fidelityStrip(width: CGFloat) -> some View {
        ZStack(alignment: .trailing) {
            RoundedRectangle(cornerRadius: 4).fill(Instrument.well)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4).fill(Instrument.accent)
                // Truncates rather than `.fixedSize()`: a buffer that has
                // been filling for a minute of thirty is a sliver of a band,
                // and a label wider than its band would run across the rail.
                Text(fidelity)
                    .font(Instrument.mono(10))
                    .tracking(0.6)
                    .foregroundStyle(Instrument.solidInk)
                    .lineLimit(1)
                    .padding(.horizontal, 9)
            }
            .frame(width: bands.isEmpty ? 0 : width * filled)
            .clipped()
        }
        .frame(height: 30)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    /// Each band at its own `start` rather than packed in a row: while the
    /// buffer is still filling, the frames cover the tail of the span and the
    /// head of the rail has honestly nothing on it.
    private func appStrip(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(Instrument.well)
            ForEach(bands) { band in
                Group {
                    if band.excluded {
                        Hatch()
                    } else {
                        Rectangle().fill(Self.color(for: band.label))
                    }
                }
                .frame(width: max(0, width * band.width))
                .offset(x: width * band.start)
            }
        }
        .frame(height: 7)
        .clipShape(RoundedRectangle(cornerRadius: 1))
    }

    /// What the ledger says was going on. Empty until the analyzer has reached
    /// these minutes, which for the live end of the buffer it usually has not —
    /// so the strip disappears rather than drawing an hour-old task over a
    /// five-minute rail. Bands sit at their own `start`, like the app strip's.
    private func taskStrip(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Color.clear
            ForEach(taskBands) { band in
                HStack {
                    Text(band.label ?? "")
                        .font(Instrument.sans(10))
                        .foregroundStyle(Instrument.muted)
                        .lineLimit(1)
                        .padding(.leading, 5)
                    Spacer(minLength: 0)
                }
                .frame(width: max(0, width * band.width), alignment: .leading)
                .frame(height: 16)
                .background(Instrument.rowTint)
                .clipped()
                .offset(x: width * band.start)
            }
        }
        .frame(height: 16)
    }

    private func axis(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(Array(ticks.enumerated()), id: \.offset) { index, tick in
                Text(tick.label)
                    .font(Instrument.mono(10))
                    .foregroundStyle(Instrument.ghost)
                    .fixedSize()
                    // The ends anchor to their edges; everything between is
                    // centred on its tick. A centred first label hangs off the
                    // left of the rail.
                    .alignmentGuide(.leading) { dimension in
                        if index == 0 { return 0 }
                        if index == ticks.count - 1 { return dimension.width }
                        return dimension.width / 2
                    }
                    .offset(x: width * tick.at)
            }
        }
        .frame(height: 14)
    }

    /// The playhead, with the knob a scrubber has: the hairline alone reads as
    /// a chart's marker rather than as something you can take hold of, and this
    /// rail is the player's seek bar.
    private func playheadLine(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            Circle()
                .fill(Instrument.ink)
                .frame(width: 9, height: 9)
                .overlay { Circle().strokeBorder(Instrument.ground, lineWidth: 1.5) }
            Rectangle()
                .fill(Instrument.ink)
                .frame(width: 1)
        }
        .frame(height: taskBands.isEmpty ? 60 : 78)
        .offset(x: width * playhead - 4.5, y: 12)
    }

    // MARK: - Colours

    /// A band's hue, hashed from its bundle so one app keeps one colour across
    /// a scrub — the same trick and the same scale the Time page uses.
    static func color(for bundle: String?) -> Color {
        guard let bundle, !bundle.isEmpty else { return Instrument.other }
        let hash = bundle.unicodeScalars.reduce(UInt64(5_381)) { ($0 &* 33) &+ UInt64($1.value) }
        return Instrument.slots[Int(hash % UInt64(Instrument.slots.count))]
    }

    /// How much of the rail the footage covers, measured from its oldest
    /// frame to the live end.
    private var filled: Double {
        guard let first = bands.first else { return 0 }
        return min(1, max(0, 1 - first.start))
    }
}

/// What the rail's colours mean, and how long each thing held the screen.
struct RewindLegend: View {
    let entries: [(label: String?, ms: Int64)]
    let markCount: Int
    /// Bundle → the name a person would use for it, when the ledger knows one.
    let names: [String: String]

    var body: some View {
        FlowRow(spacing: 18, lineSpacing: 7) {
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                HStack(spacing: 7) {
                    SeriesSwatch(
                        color: RewindRail.color(for: entry.label),
                        hatched: entry.label == nil)
                    Text(entry.label.map { names[$0] ?? $0 } ?? "Excluded — never captured")
                        .font(Instrument.sans(11.5))
                        .foregroundStyle(Instrument.secondary)
                    Figure(TimeBreakdown.duration(entry.ms), size: 11, color: Instrument.faint)
                }
            }
            if markCount > 0 {
                HStack(spacing: 7) {
                    Rectangle().fill(Instrument.beacon).frame(width: 5, height: 5)
                    Text("Saved from here")
                        .font(Instrument.sans(11.5))
                        .foregroundStyle(Instrument.secondary)
                    Figure("\(markCount)", size: 11, color: Instrument.faint)
                }
            }
        }
    }
}
