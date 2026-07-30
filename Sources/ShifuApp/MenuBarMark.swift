import AppKit
import SwiftUI

/// Shifu's mark in the menu bar: three rails of a ribbon, rising. Flat and
/// even when capture is paused, so the state is legible at 18 points without
/// a badge.
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

/// The mark itself, also usable on screen: three rails, rising while watching
/// and level while resting.
struct InstrumentMark: View {
    var paused = false
    var color: Color = .primary

    private static let watching: [CGFloat] = [0.42, 0.68, 1.0]
    private static let resting: [CGFloat] = [0.42, 0.42, 0.42]

    var body: some View {
        GeometryReader { proxy in
            let bars = paused ? Self.resting : Self.watching
            let width = proxy.size.width / CGFloat(bars.count * 2 - 1)
            HStack(alignment: .bottom, spacing: width) {
                ForEach(Array(bars.enumerated()), id: \.offset) { _, fraction in
                    RoundedRectangle(cornerRadius: width / 2.5)
                        .fill(color)
                        .frame(width: width, height: proxy.size.height * fraction)
                }
            }
            .frame(
                width: proxy.size.width, height: proxy.size.height,
                alignment: .bottomLeading)
        }
    }
}
