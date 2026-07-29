import ShifuCore
import SwiftUI

/// Today laid out as stepping stones (design.md §7) — one stone per hour of the
/// waking day, sized by how much of that hour the ledger holds and colored by
/// whatever most of it was. Hours you didn't work are the gaps you step over.
/// Shifu stands on the last stone you laid.
///
/// It is the same numbers as the Time page's bars, told as a route instead of a
/// chart: the Today page's job is "how is the day going", not "measure it".
struct DayTrail: View {
    struct Stone: Identifiable {
        let hour: Int
        let ms: Int64
        let label: String
        let color: Color

        var id: Int { hour }
        /// Under a minute is rounding noise, not a stone.
        var isEmpty: Bool { ms < 60_000 }
        /// 0…1 against a full hour — how big the stone is drawn.
        var fill: Double { min(1, Double(ms) / 3_600_000) }
    }

    let stones: [Stone]

    private static let height: CGFloat = 96
    /// How far the route climbs left → right. Enough to read as a rise, little
    /// enough that stone size still reads as the quantity.
    private static let climb: CGFloat = 22
    private static let maxStoneWidth: CGFloat = 30

    var body: some View {
        GeometryReader { proxy in
            let slot = proxy.size.width / CGFloat(max(1, stones.count))
            ZStack(alignment: .topLeading) {
                ground(slot: slot, width: proxy.size.width)
                trailLine(slot: slot, width: proxy.size.width)
                ForEach(Array(stones.enumerated()), id: \.element.id) { index, stone in
                    stoneView(stone, at: index, slot: slot)
                }
                if let last = lastLaid {
                    SenseiFigure(size: 34, mood: .watching)
                        .offset(
                            x: centerX(last.index, slot: slot) - 17,
                            y: baseline(last.index) - stoneHeight(last.stone) - 33)
                }
            }
        }
        .frame(height: Self.height)
    }

    /// Index and stone of the most recent hour with work in it — the one he
    /// is standing on.
    private var lastLaid: (index: Int, stone: Stone)? {
        guard let index = stones.lastIndex(where: { !$0.isEmpty }) else { return nil }
        return (index: index, stone: stones[index])
    }

    // MARK: - Geometry

    private func centerX(_ index: Int, slot: CGFloat) -> CGFloat {
        slot * (CGFloat(index) + 0.5)
    }

    /// The route's ground line under stone `index`: a steady climb with a
    /// shallow wave on it, so it reads as terrain rather than a trend line.
    private func baseline(_ index: Int) -> CGFloat {
        let progress = CGFloat(index) / CGFloat(max(1, stones.count - 1))
        let wave = sin(Double(progress) * 5.4 + 0.6) * 3.5
        return Self.height - 26 - progress * Self.climb + wave
    }

    private func stoneHeight(_ stone: Stone) -> CGFloat {
        stone.isEmpty ? 5 : 7 + 13 * stone.fill
    }

    private func stoneWidth(_ stone: Stone, slot: CGFloat) -> CGFloat {
        let room = min(Self.maxStoneWidth, slot - 5)
        return stone.isEmpty ? 5 : room * (0.55 + 0.45 * stone.fill)
    }

    // MARK: - Parts

    /// The hillside the route is cut into. Without it the stones float; with
    /// it the empty hours read as ground you walked over rather than data that
    /// is missing.
    private func ground(slot: CGFloat, width: CGFloat) -> some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: Self.height))
            path.addLine(to: CGPoint(x: 0, y: baseline(0) + 2))
            for index in stones.indices {
                path.addLine(to: CGPoint(x: centerX(index, slot: slot), y: baseline(index) + 2))
            }
            path.addLine(to: CGPoint(x: width, y: baseline(stones.count - 1) + 2))
            path.addLine(to: CGPoint(x: width, y: Self.height))
            path.closeSubpath()
        }
        .fill(LinearGradient(
            colors: [Dojo.accent.opacity(0.13), Dojo.accent.opacity(0.01)],
            startPoint: .top, endPoint: .bottom))
        // The hillside runs off both edges of the card rather than stopping at
        // a hard vertical seam.
        .mask(LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.07),
                .init(color: .black, location: 0.93),
                .init(color: .clear, location: 1)
            ],
            startPoint: .leading, endPoint: .trailing))
    }

    /// The route itself: a dotted line through every stone, so the gaps still
    /// belong to the same walk.
    private func trailLine(slot: CGFloat, width: CGFloat) -> some View {
        Path { path in
            for index in stones.indices {
                let point = CGPoint(x: centerX(index, slot: slot), y: baseline(index) + 2)
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
        }
        .stroke(
            Dojo.accent.opacity(0.3),
            style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [1.5, 5]))
    }

    /// The stone itself rides the terrain; its hour label stays on one flat
    /// baseline at the foot of the view, so the ticks read as an axis.
    private func stoneView(_ stone: Stone, at index: Int, slot: CGFloat) -> some View {
        let height = stoneHeight(stone)
        return ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: height / 2, style: .continuous)
                .fill(stone.isEmpty
                    ? AnyShapeStyle(Dojo.accent.opacity(0.28)) : AnyShapeStyle(stone.color))
                .frame(width: stoneWidth(stone, slot: slot), height: height)
                .offset(y: baseline(index) - height)
            if stone.hour.isMultiple(of: 3) {
                Text(String(format: "%02d", stone.hour))
                    .font(Dojo.label(9, .medium))
                    .foregroundStyle(.tertiary)
                    .offset(y: Self.height - 14)
            }
        }
        .frame(width: slot, height: Self.height, alignment: .top)
        .offset(x: slot * CGFloat(index))
        .help(stone.isEmpty
            ? "\(TimeBreakdown.hourLabel(stone.hour)) — nothing tracked"
            : "\(TimeBreakdown.hourLabel(stone.hour)) — "
                + "\(TimeBreakdown.duration(stone.ms)) \(stone.label)")
    }
}

extension DayTrail {
    /// Stones for one day's activity blocks.
    ///
    /// The window runs from the earliest hour with work in it (or 08:00,
    /// whichever is earlier) to the current hour, so an early start widens the
    /// route instead of falling off its left edge, and a day that has barely
    /// begun still shows a road ahead.
    static func stones(
        from activities: [LedgerBuilder.LabeledActivity], now: Date = Date()
    ) -> [Stone] {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: now)
        var totals: [Int: [String: Int64]] = [:]
        for activity in activities {
            let start = Date(timeIntervalSince1970: Double(activity.startedAt) / 1_000)
            let end = Date(timeIntervalSince1970: Double(activity.endedAt) / 1_000)
            var cursor = max(start, dayStart)
            while cursor < end {
                let hour = calendar.component(.hour, from: cursor)
                let hourEnd = calendar.date(
                    bySettingHour: hour, minute: 59, second: 59, of: cursor)!
                    .addingTimeInterval(1)
                let slice = min(end, hourEnd).timeIntervalSince(cursor)
                totals[hour, default: [:]][activity.category, default: 0] += Int64(slice * 1_000)
                cursor = hourEnd
            }
        }

        let currentHour = calendar.component(.hour, from: now)
        let firstWorked = totals.filter { $0.value.values.reduce(0, +) >= 60_000 }.keys.min()
        let from = min(firstWorked ?? 8, 8)
        let to = max(currentHour, from + 5)
        let colors = TimePalette.colors(
            for: Array(Set(totals.values.flatMap(\.keys))), lens: .category)
        return (from...min(23, to)).map { hour in
            let byCategory = totals[hour] ?? [:]
            let top = byCategory.max { $0.value < $1.value }
            return Stone(
                hour: hour,
                ms: byCategory.values.reduce(0, +),
                label: top?.key ?? "",
                color: top.flatMap { colors[$0.key] } ?? TimePalette.otherColor)
        }
    }
}
