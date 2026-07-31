import AppKit
import SwiftUI

/// Shifu's mark in the menu bar: one mountain ridge, drawn in a single stroke.
/// Worn down to foothills when capture is paused, so the state is legible at
/// 18 points without a badge.
///
/// `MenuBarExtra(systemImage:)` can only take an SF Symbol and none of them is
/// this, so the figure is rendered once per state into an `NSImage` at menu
/// bar height and cached. Rendered as a *template*: this mark is monochrome by
/// design, and letting AppKit tint it is what keeps it right on a dark menu
/// bar, under a wallpaper, and while the item is pressed.
enum MenuBarMark {
    /// Menu bar items get 22 pt of height; 18 leaves the usual optical margin.
    private static let side: CGFloat = 18

    @MainActor private static var cache: [Bool: NSImage] = [:]

    /// Nil if `ImageRenderer` can't produce a bitmap — the caller falls back to
    /// an SF Symbol rather than leaving a blank gap in the menu bar, which is
    /// what an empty `NSImage` would look like.
    @MainActor static func image(paused: Bool) -> NSImage? {
        if let cached = cache[paused] { return cached }
        let renderer = ImageRenderer(
            content: InstrumentMark(paused: paused)
                .frame(width: side, height: side))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let image = renderer.nsImage else { return nil }
        image.isTemplate = true
        cache[paused] = image
        return image
    }
}

/// The mark itself, also usable on screen: one ridge, high while watching and
/// worn down to two low hills while resting.
struct InstrumentMark: View {
    var paused = false

    /// The ridge as a polyline in unit space, y measured from the top. Both
    /// states start and end on the same base line at the same x, so the mark
    /// keeps its footing in the bar and only the country between changes.
    private static let watching: [CGPoint] = [
        .init(x: 0.08, y: 0.76), .init(x: 0.36, y: 0.24), .init(x: 0.56, y: 0.52),
        .init(x: 0.70, y: 0.36), .init(x: 0.92, y: 0.76)
    ]
    /// Two tiny peaks whose valley drops all the way back to the base line —
    /// at 18 points that reads as "smaller and calmer", where a flat line read
    /// as "broken".
    private static let resting: [CGPoint] = [
        .init(x: 0.08, y: 0.76), .init(x: 0.30, y: 0.52), .init(x: 0.50, y: 0.76),
        .init(x: 0.70, y: 0.52), .init(x: 0.92, y: 0.76)
    ]

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let points = paused ? Self.resting : Self.watching
            Path { path in
                for (index, point) in points.enumerated() {
                    let place = CGPoint(x: point.x * size.width, y: point.y * size.height)
                    if index == 0 { path.move(to: place) } else { path.addLine(to: place) }
                }
            }
            // Round joins keep the peaks from splintering once the stroke is
            // only ~2 pt wide; anything thinner disappears under a wallpaper.
            .stroke(
                Color.primary,
                style: StrokeStyle(
                    lineWidth: min(size.width, size.height) * 0.11,
                    lineCap: .round, lineJoin: .round))
        }
    }
}
