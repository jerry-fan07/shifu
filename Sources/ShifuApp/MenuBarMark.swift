import AppKit
import SwiftUI

/// Shifu's face in the menu bar. `MenuBarExtra(systemImage:)` can only take an
/// SF Symbol, and none of them is him — so the vector figure is rendered once
/// per state into an `NSImage` at menu-bar height and cached.
///
/// Deliberately *not* a template image: the headband is the mark, and a
/// template would flatten it to a monochrome blob indistinguishable from every
/// other menu bar item.
enum MenuBarMark {
    /// Menu bar items get 22 pt of height; 18 leaves the usual optical margin.
    private static let side: CGFloat = 18

    @MainActor private static var cache: [SenseiFigure.Mood: NSImage] = [:]

    /// Nil if `ImageRenderer` can't produce a bitmap — the caller falls back to
    /// an SF Symbol rather than leaving a blank gap in the menu bar, which is
    /// what an empty `NSImage` would look like.
    @MainActor static func image(paused: Bool) -> NSImage? {
        let mood: SenseiFigure.Mood = paused ? .resting : .watching
        if let cached = cache[mood] { return cached }
        let renderer = ImageRenderer(
            content: SenseiFigure(size: side, mood: mood)
                .frame(width: side, height: side))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let image = renderer.nsImage else { return nil }
        image.isTemplate = false
        cache[mood] = image
        return image
    }
}
