import AppKit
import Foundation
import ShifuCore
import SwiftUI
import Testing
@testable import ShifuApp

/// A camera pointed at one thing: the Timeline chart with a legend row under
/// the pointer, so the recede is judged against a real week rather than
/// reasoned about.
///
/// `WindowShots` can't answer this. `onHover` fires from wherever the real
/// mouse happens to be, which offscreen means nowhere — so the hover state is
/// unreachable through the window, and the only honest way to see the lit
/// chart is to hand `StackedBars` the `highlight` its legend would have set.
/// That leaves the five lines of `.onHover` wiring unphotographed; they are
/// `BreakdownTable`'s, verbatim.
///
///     SHIFU_SHOTS=/tmp/shifu-shots SHIFU_HOME=/tmp/shifu-verify \
///         swift test --filter BarHighlightShots
@Suite struct BarHighlightShots {
    @MainActor @Test func aLegendRowLitOverARealWeek() throws {
        guard let raw = ProcessInfo.processInfo.environment["SHIFU_SHOTS"] else { return }
        let directory = URL(fileURLWithPath: raw, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)

        let store = LedgerStore()
        store.refresh()
        let blocks = store.activities(sinceWeeksAgo: 1)
        let now = Date()
        let window = (from: Calendar.current.startOfWeek(for: now), to: now)

        // Both scales, because they are different palettes and only one of
        // them is a ramp. Theme hues come from a hash over `Instrument.slots`;
        // Category hues are a fixed eight-name table that reaches for the
        // greys the recede also lives among — so it is the Category lens, in
        // dark, that says whether the recede clears every series or only the
        // colourful ones.
        for lens in [TimeLens.theme, .category] {
            let slices = TimeBreakdown.slices(
                blocks, lens: lens, from: window.from, to: window.to,
                limit: lens == .category ? nil : 6)
            let colors = Dictionary(uniqueKeysWithValues: slices.map { ($0.name, $0.color) })
            let stacks = LedgerShapes.bars(
                blocks, lens: lens, colors: colors, order: slices.map(\.name),
                slots: daySlots(from: window.from))

            // Nothing lit, then every series in turn — one shot each, because
            // the question is whether a lit band is findable at a glance, and
            // charts stacked in one PNG is not how anybody looks at one. Every
            // series matters here, not a representative one: what the recede
            // has to clear is whichever hue the group happens to hold, and the
            // palest of them have the least room to clear it by.
            let lit: [String?] = [nil] + slices.map { $0.name }
            for dark in [false, true] {
                for (index, name) in lit.enumerated() {
                    shoot(
                        VStack(alignment: .leading, spacing: 6) {
                            Text(name ?? "— resting —")
                                .font(Instrument.mono(10))
                                .foregroundStyle(Instrument.ghost)
                            StackedBars(stacks: stacks, highlight: name)
                        }
                        .padding(22)
                        .background(Instrument.ground),
                        to: directory.appendingPathComponent(
                            "bars-\(lens.rawValue.lowercased())-\(index)"
                                + "\(dark ? "-dark" : "").png"),
                        dark: dark)
                }
            }
        }
    }

    /// The week's seven slots, as `TimelineChart` cuts them.
    private func daySlots(from start: Date) -> [LedgerShapes.Slot] {
        let calendar = Calendar.current
        return (0..<7).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: start),
                  let next = calendar.date(byAdding: .day, value: 1, to: day)
            else { return nil }
            return LedgerShapes.Slot(
                tick: day.formatted(.dateTime.weekday(.abbreviated)), from: day, to: next)
        }
    }

    @MainActor private func shoot(_ view: some View, to url: URL, dark: Bool) {
        let size = CGSize(width: 900, height: 200)
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: size)
        window.contentView = host
        window.orderBack(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        host.layoutSubtreeIfNeeded()

        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
        window.orderOut(nil)
    }
}
