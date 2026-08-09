import AppKit

/// Bundle identifier → the name a person would use for it.
///
/// Its own file because two places need the same answer and they must not
/// disagree: the Privacy page lists what you have excluded, and the Rewind
/// legend names what held the screen. An app called `com.apple.dt.Xcode` in one
/// list and `Xcode` in the other reads as two different apps.
///
/// Cached for the launch, because the lookup walks the Launch Services database
/// and the legend asks for every band on every body pass.
@MainActor
enum AppNames {
    private static var cache: [String: String] = [:]

    /// The app's own name when macOS can still find it, falling back to the
    /// identifier — which is also what an app that has since been deleted
    /// shows, so a stale row is visibly stale rather than silently wrong.
    static func display(_ bundleID: String) -> String {
        if let cached = cache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else {
            cache[bundleID] = bundleID
            return bundleID
        }
        let name = FileManager.default.displayName(atPath: url.path)
        cache[bundleID] = name
        return name
    }
}
