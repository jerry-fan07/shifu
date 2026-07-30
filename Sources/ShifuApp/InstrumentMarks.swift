import SwiftUI

// The marks that carry a number without spelling it out: status pips,
// series swatches, meters, the day's ribbon, and a theme's sparkline.
// Every one of them sits beside the figure it draws — none is ever the
// only place a value appears.

/// The state pip — watching, resting, granted.
struct StatusDot: View {
    var color: Color = Instrument.live
    var size: CGFloat = 7

    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
    }
}

/// The square that ties a table row to its series.
struct SeriesSwatch: View {
    let color: Color
    var hatched = false

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(hatched ? AnyShapeStyle(Instrument.quiet) : AnyShapeStyle(color))
            .frame(width: 9, height: 9)
            .overlay { if hatched { Hatch().clipShape(RoundedRectangle(cornerRadius: 2)) } }
    }
}

/// A share of the whole, drawn as a rail. The track always shows, so a 0.4%
/// group still reads as a group rather than an empty row.
struct Meter: View {
    let share: Double
    var color: Color = Instrument.accent

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Instrument.well)
                Capsule()
                    .fill(color)
                    .frame(width: max(3, proxy.size.width * min(1, max(0, share))))
            }
        }
        .frame(height: 6)
    }
}

/// Diagonal ticks: time that was measured but never read (private, excluded).
struct Hatch: View {
    var body: some View {
        Canvas { context, size in
            let step: CGFloat = 6
            var offset = -size.height
            while offset < size.width {
                var path = Path()
                path.move(to: CGPoint(x: offset, y: size.height))
                path.addLine(to: CGPoint(x: offset + size.height, y: 0))
                context.stroke(path, with: .color(Instrument.ghost.opacity(0.55)), lineWidth: 2)
                offset += step
            }
        }
        .background(Instrument.quiet)
    }
}

/// One stretch of the day. `weight` is its duration; the style says whether it
/// was work, a gap, or time deliberately not read.
struct RibbonSegment: Identifiable {
    enum Fill { case series(Color), gap, hidden }

    let id: Int
    let weight: Double
    let fill: Fill
    /// What the tooltip says. Empty for gaps.
    var caption: String = ""
}

/// The day as it actually happened: a single rail, cut where the work changed.
/// Replaces a bar chart because a bar chart says "how much at 10 AM" and this
/// says "what the morning was".
struct Ribbon: View {
    let segments: [RibbonSegment]
    var height: CGFloat = 30
    var corner: CGFloat = 4

    private var total: Double { max(0.0001, segments.reduce(0) { $0 + $1.weight }) }

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                ForEach(segments) { segment in
                    fill(for: segment)
                        .frame(width: proxy.size.width * segment.weight / total)
                        .help(segment.caption)
                }
            }
        }
        .frame(height: height)
        .background(Instrument.well)
        .clipShape(RoundedRectangle(cornerRadius: corner))
    }

    @ViewBuilder private func fill(for segment: RibbonSegment) -> some View {
        switch segment.fill {
        case .series(let color): Rectangle().fill(color)
        case .gap: Color.clear
        case .hidden: Hatch()
        }
    }
}

/// The hours the ribbon spans, ticked under it.
struct RibbonAxis: View {
    let hours: [Int]
    var leading: CGFloat = 0

    var body: some View {
        HStack {
            ForEach(hours, id: \.self) { hour in
                Text(String(format: "%02d", hour))
                    .font(Instrument.mono(10))
                    .foregroundStyle(Instrument.ghost)
                if hour != hours.last { Spacer(minLength: 0) }
            }
        }
        .padding(.leading, leading)
        .padding(.top, 5)
    }
}

/// Eight weeks of a theme, drawn small enough to sit in a table cell. Recent
/// weeks take the strong step of the accent, older ones fade back — so a
/// sparkline says "rising" without an axis.
struct Sparkline: View {
    /// Oldest first, any scale — normalised here.
    let values: [Double]
    /// A theme nobody has touched draws in the quiet grey instead.
    var dormant = false
    var height: CGFloat = 22

    private static let ramp = [Instrument.soft, Instrument.mid, Instrument.strong]

    var body: some View {
        let peak = max(0.0001, values.max() ?? 0)
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                Rectangle()
                    .fill(dormant ? Instrument.quiet : Self.step(index, of: values.count))
                    // A dead week still shows a tick, so the eye can count the
                    // bars and know how far back the row reaches.
                    .frame(height: max(1, height * value / peak))
            }
        }
        .frame(height: height, alignment: .bottom)
    }

    /// Which step of the accent this bar takes: the run is split in thirds,
    /// oldest third softest.
    private static func step(_ index: Int, of count: Int) -> Color {
        guard count > 1 else { return ramp[2] }
        let third = Double(index) / Double(count - 1)
        return ramp[min(2, Int(third * 3))]
    }
}
