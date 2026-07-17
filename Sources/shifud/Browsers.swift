import Foundation

/// Browser awareness: which apps have URLs worth reading, and private-window
/// detection (always excluded, not configurable — design.md §8).
enum Browsers {
    static let bundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "org.mozilla.firefox",
        "com.brave.Browser",
        "company.thebrowser.Browser",   // Arc
        "com.microsoft.edgemac",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
        "org.chromium.Chromium",
    ]

    static func isBrowser(_ bundleID: String) -> Bool {
        bundleIDs.contains(bundleID)
    }

    /// Title-based heuristic; browsers put a marker in private-window titles.
    private static let privateMarkers = [
        "Private Browsing", "(Incognito)", "(Private)", "InPrivate",
    ]

    static func isPrivateWindow(title: String?) -> Bool {
        guard let title else { return false }
        return privateMarkers.contains { title.contains($0) }
    }
}
