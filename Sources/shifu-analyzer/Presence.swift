import CoreGraphics
import Foundation

/// Is anyone at the machine right now? Feeds `LLMPacer`'s active-vs-away duty
/// choice — polled per LLM call, so the pacer eases off within one call of
/// the user sitting back down.
///
/// These are the same two reads the daemon makes (`Daemon.SessionProbe`,
/// `Daemon.secondsSinceLastInput`), duplicated rather than shared: shifud's
/// versions are entangled with capture teardown and injection seams the
/// analyzer has no use for, and ten lines of public-API reads are cheaper
/// than a third home both binaries must agree on.
enum Presence {
    /// Five minutes without input reads as away — the daemon's own idle
    /// suspension threshold, reused so "Shifu thinks you left" means one
    /// thing across both binaries.
    static let idleThresholdSeconds: TimeInterval = 300

    static func userIsAway() -> Bool {
        screenIsLocked() || secondsSinceLastInput() > idleThresholdSeconds
    }

    /// `CGSSessionScreenIsLocked` is absent whenever the screen is unlocked,
    /// so a missing key is the documented encoding of "unlocked", not an
    /// error. The lock check must come first: at the lock screen the user
    /// session stops receiving HID events, so the idle counter alone can
    /// read a locked machine as active.
    private static func screenIsLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as NSDictionary? else { return false }
        return (session["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false
    }

    /// Min over the common HID event kinds — the same walk as
    /// `Daemon.secondsSinceLastInput`.
    private static func secondsSinceLastInput() -> TimeInterval {
        let kinds: [CGEventType] = [.keyDown, .mouseMoved, .leftMouseDown, .scrollWheel]
        return kinds.map {
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0)
        }.min() ?? 0
    }
}
