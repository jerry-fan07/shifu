import Foundation

/// The shape of one glow pulse (design.md §4.4): how long each phase of the
/// breath lasts, how the vignette is graded, and how big the line is.
///
/// These numbers live here rather than on `GlowOverlay` because two processes
/// have to agree on them. The daemon draws the real nudge; the app replays one
/// during first run (§7) so the user can see what they are agreeing to before
/// it ever fires unannounced. That demonstration's entire claim is "this is the
/// nudge" — a copy of the timings would keep that claim only until one side
/// was tuned.
///
/// Only the numbers are shared. The two renderers are deliberately separate:
/// `shifud` animates on Core Animation layers because its main thread is
/// blocked by the capture ladder exactly when a pulse fires, while the app's is
/// idle behind an onboarding window and can drive the same curve from SwiftUI.
public enum FocusNudge {
    /// The line the pulse carries. One string, not a rotation: a nudge that
    /// says something different every time is a thing you start reading.
    public static let message = "Believe in yourself"

    // Breathe in, hold at peak, breathe out — the hold is what makes the
    // velocity reversal read as a breath, not a corner.
    public static let breatheIn: TimeInterval = 1.6
    public static let hold: TimeInterval = 0.4
    public static let breatheOut: TimeInterval = 2.4
    /// The message's own fade. Shorter than the vignette's ramp on purpose, so
    /// the line lands while the glow is still rising.
    public static let messageFade: TimeInterval = 0.8

    /// The whole visible pulse, end to end.
    public static var pulse: TimeInterval { breatheIn + hold + breatheOut }

    /// The floor between two pulses while the user stays off-task. Policy
    /// rather than animation, but the first-run demonstration draws the pulse
    /// against it — "and then nothing for this long" is half of what makes the
    /// nudge tolerable, and it can only be shown to scale.
    public static let spacing: TimeInterval = 10

    // MARK: - Geometry

    /// The vignette's inner edge, 0…1 of the way from the centre to the
    /// corner: fully transparent out to here, so whatever the user is actually
    /// working on is never tinted.
    public static let clearStop = 0.15
    /// The amber's alpha where the vignette meets the corner.
    public static let edgeAlpha = 0.55

    /// The line's point size as a fraction of the display's width — ≈84 pt on
    /// a 14" MacBook Pro, so it scales with the screen instead of overflowing a
    /// small one or shrinking into a large one.
    public static let messageWidthFraction = 1.0 / 18.0
}
