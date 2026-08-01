import SwiftUI

// The marks that carry a number without spelling it out: status pips,
// series swatches, meters, the day's ribbon, the Timeline's stacked bars,
// and a theme's sparkline. Every one of them sits beside the figure it
// draws — none is ever the only place a value appears.

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
/// Says "what the morning was" — "how much at 10 AM" is `StackedBars`'
/// question, over on the Timeline.
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
///
/// Each label is centred on the instant it names. The obvious layout — an
/// `HStack` of labels with `Spacer`s between them — is wrong for any rail whose
/// ticks aren't a uniform division of it: a rail from 07:00 to 22:00 ticked
/// every two hours runs 07, 09 … 21, 22, and the closing hour is one hour past
/// its neighbour where every other gap is two. Spacing those nine by count puts
/// 21 seven eighths along when the hour itself falls fourteen fifteenths along,
/// an hour's drift off the band it names. An axis that disagrees with the
/// bands above it is worse than no axis, because it is the thing you check
/// them against.
///
/// The two end labels are the exception: they are held inside the rail so they
/// cannot hang off the page. That costs half a label — ten minutes on a
/// day-long rail — and only ever at the ends.
struct RibbonAxis: View {
    let ticks: [LedgerShapes.AxisTick]
    var leading: CGFloat = 0

    /// Measured rather than guessed: the clamp at either end is only honest
    /// if the width it clamps by is the width that draws.
    private static let label = ("00" as NSString)
        .size(withAttributes: [.font: Instrument.monoFont(10)])

    var body: some View {
        GeometryReader { proxy in
            ForEach(ticks) { tick in
                Text(tick.label)
                    .font(Instrument.mono(10))
                    .foregroundStyle(Instrument.ghost)
                    .position(
                        x: min(
                            max(proxy.size.width * tick.place, Self.label.width / 2),
                            proxy.size.width - Self.label.width / 2),
                        y: Self.label.height / 2)
            }
        }
        .frame(height: Self.label.height)
        .padding(.leading, leading)
        .padding(.top, 5)
    }
}

/// One column of the Timeline's chart: a slot of clock — an hour of the day,
/// a day of the week — with the tracked time inside it stacked by group.
/// Built by `LedgerShapes.bars`.
struct BarStack: Identifiable {
    struct Segment: Identifiable {
        let id: Int
        /// The group this band came from, spelled the way a `TimeSlice` is —
        /// so the legend under the chart can point at its own bands across
        /// every column. Private time carries the category it is.
        let name: String
        let ms: Int64
        /// `.series` or `.hidden` — a slot with nothing in it draws no column
        /// at all, so `.gap` never occurs here.
        let fill: RibbonSegment.Fill
        /// What the tooltip says: the group and how much of the slot it held.
        let caption: String
    }

    let id: Int
    /// The axis label under the column. Empty for hours that go unticked.
    let tick: String
    /// Baseline first; private time rides on top, hatched.
    let segments: [Segment]

    var totalMs: Int64 { segments.reduce(0) { $0 + $1.ms } }
}

/// The Timeline's chart: one column per slot of clock, stacked by group —
/// the "how much at 10 AM" the Breakdown's ribbon deliberately doesn't
/// answer. The scale is ruled: hairlines at round durations, each with its
/// figure in the gutter, so *every* column reads as an amount rather than
/// only against its tallest neighbour. Exact values still ride in a tooltip,
/// the legend under the chart, and the block list below.
struct StackedBars: View {
    let stacks: [BarStack]
    var height: CGFloat = 108
    /// A label pinned to the axis's trailing edge — the day chart's "24", the
    /// closing boundary a per-slot tick can't name. Nil leaves the axis to
    /// the slot ticks alone.
    var endTick: String?
    /// One group's `BarStack.Segment.name`, held at full strength while every
    /// other band recedes — how the legend answers "and where was *that* one".
    /// Nil draws every column at full strength, which is the resting state.
    var highlight: String?
    /// Called as the pointer enters or leaves one band, with that band's group
    /// name and whether it is now on it. The chart doesn't own `highlight`, so
    /// asking a band where its group went is the same question the legend asks
    /// — it just gets asked from the mark instead of from its name. Nil leaves
    /// the bands inert, which is what a chart with no legend beside it wants.
    var onHoverBand: ((String, Bool) -> Void)?

    /// Between slots — the columns themselves sit centred in what's left.
    private static let spacing: CGFloat = 4
    /// The widest a column may be drawn, however much room its slot has: past
    /// this a column reads as a region rather than a mark.
    private static let maxThickness: CGFloat = 34
    /// Ground that always stays between neighbouring columns, so a narrow
    /// window thins the bars instead of running them together.
    private static let minAir: CGFloat = 9
    /// The ground showing between stacked segments, so neighbouring groups
    /// separate without a stroke that isn't data.
    private static let gap: CGFloat = 2
    /// The gutter the grid's figures sit in, left of the plot.
    private static let axisWidth: CGFloat = 36
    private static let axisGap: CGFloat = 7
    /// At most this many grid marks — more and the band reads as ruled paper.
    private static let marks = 4
    /// The steps a grid mark may take, coarsest last. Round durations only:
    /// the point of the grid is that a column lands near a figure you can
    /// hold in your head.
    private static let steps: [Int64] = [
        60_000, 120_000, 300_000, 600_000, 900_000, 1_800_000,
        3_600_000, 7_200_000, 10_800_000, 21_600_000, 43_200_000
    ]

    private var peakMs: Int64 { stacks.map(\.totalMs).max() ?? 0 }

    /// The smallest step that rules the peak in `marks` lines or fewer.
    private var step: Int64 {
        // A slot is a day at most, which the last step rules four times over;
        // the fallback is only here to keep this total.
        Self.steps.first { peakMs <= $0 * Int64(Self.marks) } ?? 43_200_000
    }

    /// The top of the scale: a whole number of steps, so the highest mark is
    /// the top of the band rather than a line floating under the peak.
    private var ceilingMs: Int64 { (peakMs + step - 1) / step * step }

    private var levels: [Int64] {
        Array(stride(from: step, through: ceilingMs, by: Int(step)))
    }

    /// The band less the topmost mark's own hairline, so a column at the
    /// ceiling meets that line instead of running a pixel past it.
    private var plotHeight: CGFloat { max(1, height - 1) }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                ZStack(alignment: .bottomLeading) {
                    grid
                    columns(thickness: thickness(across: proxy.size.width))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
            .frame(height: height)
            Rule().padding(.leading, Self.axisWidth)
            ticks
        }
    }

    /// The scale, ruled across the plot and drawn behind the columns — a mark
    /// is a reference to read a column against, not something laid over it.
    private var grid: some View {
        ZStack(alignment: .bottomLeading) {
            ForEach(levels, id: \.self) { level in
                mark(level)
                    .offset(y: -plotHeight * CGFloat(Double(level) / Double(max(1, ceilingMs))))
            }
        }
    }

    /// One mark: its figure in the gutter, its hairline across the plot. The
    /// row is pinned to a 1pt frame so the line, not the label, is what sits
    /// at the level.
    private func mark(_ level: Int64) -> some View {
        HStack(spacing: Self.axisGap) {
            Text(Self.axisLabel(level))
                .font(Instrument.mono(9.5))
                .foregroundStyle(Instrument.ghost)
                .fixedSize()
                .frame(width: Self.axisWidth - Self.axisGap, alignment: .trailing)
            Rectangle().fill(Instrument.hairline).frame(height: 1)
        }
        .frame(height: 1)
    }

    private func columns(thickness: CGFloat) -> some View {
        HStack(alignment: .bottom, spacing: Self.spacing) {
            ForEach(stacks) { stack in
                segments(stack, thickness: thickness)
                    .frame(maxWidth: .infinity, alignment: .bottom)
            }
        }
        .padding(.leading, Self.axisWidth)
        // Short enough not to lag a pointer running down the legend, long
        // enough that the eye follows what receded rather than being handed a
        // different chart between two frames.
        .animation(.easeOut(duration: 0.12), value: highlight)
    }

    private var ticks: some View {
        ZStack(alignment: .trailing) {
            HStack(spacing: Self.spacing) {
                ForEach(stacks) { stack in
                    Text(stack.tick)
                        .font(Instrument.mono(10))
                        .foregroundStyle(Instrument.ghost)
                        .frame(maxWidth: .infinity)
                }
            }
            if let endTick {
                Text(endTick)
                    .font(Instrument.mono(10))
                    .foregroundStyle(Instrument.ghost)
            }
        }
        .padding(.leading, Self.axisWidth)
        .padding(.top, 5)
    }

    /// A column takes its slot less the air, up to the cap — the day's
    /// twenty-four columns thin down on a narrow window instead of touching,
    /// and the week's seven don't read as threads on a wide one.
    private func thickness(across width: CGFloat) -> CGFloat {
        let count = CGFloat(max(1, stacks.count))
        let slot = (width - Self.axisWidth - Self.spacing * (count - 1)) / count
        return max(3, min(Self.maxThickness, slot - Self.minAir))
    }

    /// The column itself. Segment heights share the column's scaled height
    /// after the gaps take theirs, so the cap sits at the slot's true total;
    /// the cap is rounded and the baseline square.
    private func segments(_ stack: BarStack, thickness: CGFloat) -> some View {
        let room = max(
            0,
            plotHeight * CGFloat(Double(stack.totalMs) / Double(max(1, ceilingMs)))
                - CGFloat(max(0, stack.segments.count - 1)) * Self.gap)
        return VStack(spacing: Self.gap) {
            ForEach(stack.segments.reversed()) { segment in
                fill(for: segment)
                    .frame(height: max(
                        1, room * CGFloat(Double(segment.ms) / Double(max(1, stack.totalMs)))))
                    // Half the ground on each side counts as the band, so a
                    // column reads as one continuous strip of bands to the
                    // pointer: crossing between two of them can't drop into a
                    // 2pt hole and un-dim the whole chart for a frame. It also
                    // gives the thinnest bands — which floor at 1pt — an area
                    // worth aiming at. The negative padding puts the layout
                    // back, so only the hit area grew.
                    .padding(.vertical, Self.gap / 2)
                    .contentShape(Rectangle())
                    .padding(.vertical, -Self.gap / 2)
                    .onHover { inside in onHoverBand?(segment.name, inside) }
                    .help(segment.caption)
            }
        }
        .frame(width: thickness)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4))
    }

    /// A mark's figure — the axis's register, tighter than the block list's:
    /// "45m", "2h", "1h30".
    private static func axisLabel(_ ms: Int64) -> String {
        let minutes = Int(ms / 60_000)
        guard minutes >= 60 else { return "\(minutes)m" }
        let rest = minutes % 60
        return rest == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h\(rest)"
    }

    /// A band the `highlight` passed over recedes to the flat tone of a
    /// recessed track — *one* tone for all of them, never each faded in
    /// proportion to its own colour.
    ///
    /// Fading by opacity is the obvious way and it is wrong here. This palette
    /// is three steps of a single accent, so it separates its series by
    /// lightness, and fading slides a band along that exact axis: at a fifth
    /// strength the strong step lands on #DDE2E8, four points off where the
    /// undimmed soft step sits (#C7D3E0). Hover the soft group and the chart
    /// dims into a field of near-identical pale blues with the answer
    /// somewhere inside it. Flattening every receded band to one tone lighter
    /// than any series in the ramp is what makes the lit one findable — and
    /// it holds in dark, where `well` inverts and the ramp does not.
    @ViewBuilder private func fill(for segment: BarStack.Segment) -> some View {
        let paint: RibbonSegment.Fill = highlight == nil || highlight == segment.name
            ? segment.fill
            : .series(Instrument.well)
        switch paint {
        case .series(let color): Rectangle().fill(color)
        case .gap: Color.clear
        case .hidden: Hatch()
        }
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
