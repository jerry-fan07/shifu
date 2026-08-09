import CoreGraphics
import ImageIO
import ScreenCaptureKit
import ShifuCore
import UniformTypeIdentifiers

/// The screenshot half of Rewind (design.md §3.6): one low-resolution JPEG of
/// the whole display.
///
/// Deliberately the *display*, not the frontmost window the OCR rung takes: a
/// rewind is meant to answer "what was on my screen", and a window crop of an
/// app you were dragging something out of answers a different question. The
/// cost of that choice is that a display grab can see windows belonging to
/// excluded apps sitting behind the frontmost one — so it doesn't: excluded
/// applications are filtered out of the capture at the `SCContentFilter`, which
/// is enforcement before capture, not redaction after it (invariant 3).
///
/// Unlike `OCRCapture`, this one's bitmap **is** meant to be written. That is
/// the exception invariant 4 now names, and it lives in exactly this file and
/// `RewindStore`.
@MainActor
final class RewindShot {
    struct Result {
        let data: Data
        let width: Int
        let height: Int
    }

    /// JPEG quality. 0.5 on a 960-wide frame reads a window title and a code
    /// line fine and costs ~40 KB; the buffer is 60-odd of these, so the
    /// difference between this and 0.9 is the difference between a 3 MB and a
    /// 12 MB buffer for detail nobody scrubs for.
    static let quality: CGFloat = 0.5

    /// How far past 1:1 a region grab is allowed to go. A snipped box is meant
    /// to be *read* — a paragraph, an error, a chart label — so it gets the
    /// Retina density `OCRCapture` takes for the same reason, where a rolling
    /// buffer frame does not.
    static let maxRegionScale: CGFloat = 2

    /// Grabs the main display at `width` pixels across, skipping every window
    /// owned by an excluded application.
    ///
    /// With a `region`, grabs only that box, on the screen it was dragged on,
    /// through ScreenCaptureKit's own `sourceRect` — so the pixels outside it
    /// are never composited, let alone held. Cropping afterwards would have
    /// worked too, but this way "only what the user selected" is enforced by
    /// the capture rather than by a later step that could be skipped.
    ///
    /// Nil when there is no display to capture or the encode fails — the caller
    /// treats that as "no frame this tick", never as an error worth stopping
    /// for (design.md §10).
    func capture(
        width: Int, excludedBundles: Set<String>, region: SnipRegion? = nil
    ) async throws -> Result? {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        // The region names its own screen: a box dragged on a second monitor
        // resolved against `displays.first` would crop the wrong desktop.
        // Falling back is right — an unplugged monitor should still snip.
        guard let display = region.flatMap({ wanted in
            content.displays.first { $0.displayID == wanted.displayID }
        }) ?? content.displays.first else { return nil }

        // Filtered at the source: an excluded app's window is never in the
        // bitmap, so there is nothing to redact out of it afterwards.
        let excludedApps = content.applications.filter {
            excludedBundles.contains($0.bundleIdentifier)
        }
        let filter = SCContentFilter(
            display: display, excludingApplications: excludedApps, exceptingWindows: [])

        let bounds = CGRect(x: 0, y: 0, width: display.width, height: display.height)
        let source = region.map { $0.rect.intersection(bounds) } ?? bounds
        guard !source.isNull, source.width >= 1, source.height >= 1 else { return nil }

        let config = SCStreamConfiguration()
        let ceiling = min(CGFloat(width) / source.width, region == nil ? 1 : Self.maxRegionScale)
        let scale = max(ceiling, 0.01)
        if region != nil { config.sourceRect = source }
        config.width = max(2, Int((source.width * scale).rounded()))
        config.height = max(2, Int((source.height * scale).rounded()))
        config.showsCursor = false
        config.captureResolution = .nominal

        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: config)
        guard let data = Self.jpeg(from: image) else { return nil }
        return Result(data: data, width: image.width, height: image.height)
    }

    /// CGImage → JPEG bytes, through ImageIO rather than AppKit: this runs on
    /// the daemon's main actor every few seconds, and `NSBitmapImageRep` copies
    /// the whole surface once more than it needs to.
    static func jpeg(from image: CGImage, quality: CGFloat = RewindShot.quality) -> Data? {
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            buffer, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(
            destination, image,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return buffer as Data
    }
}
