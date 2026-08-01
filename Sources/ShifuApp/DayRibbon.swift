import ShifuCore
import SwiftUI

/// The day's declared stretches on a 24-hour rail, with the hours ticked under
/// it (Ledger's `Ribbon`, on a clock instead of a window).
///
/// This is the one drawing on a note page that isn't words, and it earns its
/// place by answering the question the prose can't: *was this a morning, or was
/// it all night?* Both readings come free — the front matter already says when
/// every stretch ran, and the rail is just that list, to scale.
///
/// `highlight` dims everything outside one prose block's span, so hovering a
/// paragraph shows which parts of the day it is talking about.
struct DayRibbon: View {
    let spans: [NoteProse.Span]
    var highlight: Range<Int>?
    var height: CGFloat = 7

    /// A stretch under this many minutes still has to be visible — a 3-minute
    /// check-in is a quarter of a pixel on a day-wide rail otherwise.
    private static let floor = 6
    private static let day = 24 * 60

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Ribbon(segments: Self.segments(spans, highlight: highlight),
                   height: height, corner: 1)
            RibbonAxis(ticks: Self.ticks)
        }
    }

    static let ticks: [LedgerShapes.AxisTick] = [0, 6, 12, 18, 24].map {
        LedgerShapes.AxisTick(hour: $0, place: Double($0) / 24)
    }

    /// The rail as weights: a gap, a stretch, a gap, a stretch. Overlapping or
    /// out-of-order spans are folded in the order they were written, which is
    /// the order the note declares them.
    static func segments(
        _ spans: [NoteProse.Span], highlight: Range<Int>?
    ) -> [RibbonSegment] {
        var segments: [RibbonSegment] = []
        var cursor = 0
        for span in spans {
            guard let minutes = span.minutes else { continue }
            let start = max(cursor, minutes.lowerBound)
            let end = max(start + Self.floor, minutes.upperBound)
            if start > cursor {
                segments.append(RibbonSegment(
                    id: segments.count, weight: Double(start - cursor), fill: .gap))
            }
            let lit = highlight.map { $0.contains(minutes.lowerBound) } ?? true
            segments.append(RibbonSegment(
                id: segments.count, weight: Double(end - start),
                fill: .series(lit ? Instrument.accent : Instrument.quiet),
                caption: span.label))
            cursor = end
        }
        if cursor < Self.day {
            segments.append(RibbonSegment(
                id: segments.count, weight: Double(Self.day - cursor), fill: .gap))
        }
        return segments
    }
}

/// `DayRibbon` over a span of days instead of a clock: an overview's dated
/// stretches on one rail, to scale between the first day named and the last.
/// Same marks, same dimming — `highlight` is the hovered row's index, and
/// every other mark recedes while it is set.
///
/// Unlike the day's rail, the domain is the note's own: it starts at the
/// first date the timeline names rather than at a fixed clock edge, because
/// "how far into July" is not a question an overview answers.
struct DateRibbon: View {
    /// One row's place on the rail. `dates` is nil when the row's lead didn't
    /// parse — the row still reads below, it just leaves no mark.
    struct Mark {
        var dates: ClosedRange<Date>?
        var caption: String = ""
    }

    let marks: [Mark]
    var highlight: Int?
    var height: CGFloat = 7

    private static let calendar = Calendar(identifier: .gregorian)

    var body: some View {
        if let domain {
            VStack(alignment: .leading, spacing: 0) {
                Ribbon(segments: segments(domain), height: height, corner: 1)
                RibbonDateAxis(ticks: ticks(domain))
            }
        }
    }

    private var domain: ClosedRange<Date>? {
        let known = marks.compactMap(\.dates)
        guard let first = known.map(\.lowerBound).min(),
              let last = known.map(\.upperBound).max()
        else { return nil }
        return first...last
    }

    private func days(from start: Date, to end: Date) -> Int {
        Self.calendar.dateComponents([.day], from: start, to: end).day ?? 0
    }

    /// The rail as weights, one day per unit: a gap, a stretch, a gap.
    /// Overlapping or out-of-order rows are folded in the order they were
    /// written, which is the order the note declares them.
    private func segments(_ domain: ClosedRange<Date>) -> [RibbonSegment] {
        let total = days(from: domain.lowerBound, to: domain.upperBound) + 1
        var segments: [RibbonSegment] = []
        var cursor = 0
        for (row, mark) in marks.enumerated() {
            guard let dates = mark.dates else { continue }
            let start = max(cursor, days(from: domain.lowerBound, to: dates.lowerBound))
            let end = max(start + 1, days(from: domain.lowerBound, to: dates.upperBound) + 1)
            if start > cursor {
                segments.append(RibbonSegment(
                    id: segments.count, weight: Double(start - cursor), fill: .gap))
            }
            let lit = highlight.map { $0 == row } ?? true
            segments.append(RibbonSegment(
                id: segments.count, weight: Double(end - start),
                fill: .series(lit ? Instrument.accent : Instrument.quiet),
                caption: mark.caption))
            cursor = end
        }
        if cursor < total {
            segments.append(RibbonSegment(
                id: segments.count, weight: Double(total - cursor), fill: .gap))
        }
        return segments
    }

    /// First day, last day, and — once the rail is wide enough to hold it —
    /// the midpoint, each centred on the middle of the day it names.
    private func ticks(_ domain: ClosedRange<Date>) -> [RibbonDateAxis.Tick] {
        let total = days(from: domain.lowerBound, to: domain.upperBound) + 1
        func label(_ date: Date) -> String {
            date.formatted(.dateTime.month(.abbreviated).day())
        }
        var ticks = [RibbonDateAxis.Tick(label: label(domain.lowerBound), place: 0)]
        if total >= 8, let middle = Self.calendar.date(
            byAdding: .day, value: total / 2, to: domain.lowerBound) {
            ticks.append(RibbonDateAxis.Tick(
                label: label(middle), place: (Double(total / 2) + 0.5) / Double(total)))
        }
        if total > 1 {
            ticks.append(RibbonDateAxis.Tick(
                label: label(domain.upperBound),
                place: (Double(total) - 0.5) / Double(total)))
        }
        return ticks
    }
}

/// `RibbonAxis` with words for hours: date labels under a `DateRibbon`,
/// centred on the instants they name and clamped inside the rail at the ends
/// (the same reasoning as the hour axis — an axis that disagrees with the
/// band above it is worse than no axis).
struct RibbonDateAxis: View {
    struct Tick: Identifiable {
        var label: String
        var place: Double

        var id: Double { place }
    }

    let ticks: [Tick]

    private static let font = Instrument.monoFont(10)

    var body: some View {
        GeometryReader { proxy in
            ForEach(ticks) { tick in
                let size = (tick.label as NSString)
                    .size(withAttributes: [.font: Self.font])
                Text(tick.label)
                    .font(Instrument.mono(10))
                    .foregroundStyle(Instrument.ghost)
                    .position(
                        x: min(
                            max(proxy.size.width * tick.place, size.width / 2),
                            proxy.size.width - size.width / 2),
                        y: size.height / 2)
            }
        }
        .frame(height: ("0" as NSString).size(withAttributes: [.font: Self.font]).height)
        .padding(.top, 5)
    }
}
