import CoreGraphics
import Foundation

/// The box the user dragged, in the one coordinate system the capture side
/// speaks (design.md §3.6).
///
/// **Display-relative points, top-left origin** — ScreenCaptureKit's
/// `sourceRect`, not AppKit's. The conversion out of AppKit's bottom-left,
/// main-screen-origin globals happens once, in `from(selection:on:displayID:)`,
/// because it is the one part of this feature that is silently wrong rather
/// than visibly broken when it is wrong: a flipped rect still captures
/// *something*, just not what was dragged.
///
/// Whole points. A drag has no meaningful sub-pixel precision, and integers
/// keep the request file the plain ASCII line `pause_until` taught every reader
/// in this codebase to expect.
public struct SnipRegion: Equatable, Sendable {
    /// Which screen it was dragged on (`CGDirectDisplayID`). Carried because a
    /// rect alone is ambiguous the moment a second monitor exists.
    public var displayID: UInt32
    /// Points in from the display's left edge.
    public var left: Int
    /// Points down from the display's top edge — *down*, which is the whole
    /// reason this type exists rather than a bare `CGRect`.
    public var top: Int
    public var width: Int
    public var height: Int

    public init(displayID: UInt32, left: Int, top: Int, width: Int, height: Int) {
        self.displayID = displayID
        self.left = left
        self.top = top
        self.width = width
        self.height = height
    }

    /// Anything smaller than this is a click that slipped, not a selection.
    public static let minimumSide = 8

    public var isUsable: Bool { width >= Self.minimumSide && height >= Self.minimumSide }

    public var rect: CGRect {
        CGRect(
            x: CGFloat(left), y: CGFloat(top),
            width: CGFloat(width), height: CGFloat(height))
    }

    /// AppKit globals → display-relative top-left points.
    ///
    /// `selection` and `screen` are both in AppKit's global space (y up, origin
    /// at the bottom-left of the *main* screen); the result is relative to
    /// `screen`'s own top-left with y down. Pure on purpose — this is unit-
    /// testable without a window server, and it is the piece worth testing.
    public static func from(
        selection: CGRect, on screen: CGRect, displayID: UInt32
    ) -> SnipRegion {
        let clamped = selection.intersection(screen)
        guard !clamped.isNull else {
            return SnipRegion(displayID: displayID, left: 0, top: 0, width: 0, height: 0)
        }
        return SnipRegion(
            displayID: displayID,
            left: Int((clamped.minX - screen.minX).rounded()),
            top: Int((screen.maxY - clamped.maxY).rounded()),
            width: Int(clamped.width.rounded()),
            height: Int(clamped.height.rounded()))
    }

    /// The tail of the request line. Five fields, space-separated, in the order
    /// they are read back.
    var encoded: String { "\(displayID) \(left) \(top) \(width) \(height)" }

    static func decode(_ fields: ArraySlice<Substring>) -> SnipRegion? {
        let numbers = fields.compactMap { Int($0) }
        guard numbers.count == 5, numbers.allSatisfy({ $0 >= 0 }),
              let displayID = UInt32(exactly: numbers[0])
        else { return nil }
        return SnipRegion(
            displayID: displayID, left: numbers[1], top: numbers[2],
            width: numbers[3], height: numbers[4])
    }
}

/// The app→daemon channel for the two things only the daemon can do
/// (design.md §3.6).
///
/// There is no IPC in Shifu, and Rewind does not get to invent one. The menu
/// bar can't take a screenshot — the daemon holds the Screen Recording grant,
/// the exclusion list, and the buffer — so "Save a rewind" and "Snip" are
/// control files, exactly like `pause_until` and `focus_mode`.
///
/// A request carries a **timestamp and is ignored once stale**. That is the
/// one thing this file has to get right that the other two don't: pause is a
/// state, so reading it late is harmless, while a request is an *event*, and a
/// request written while the daemon was down would otherwise fire the moment it
/// next starts — a screenshot of whatever is on screen hours later, which is
/// the single worst thing this feature could do.
public enum RewindRequest: String, Sendable, CaseIterable {
    /// Save the rolling buffer as a rewind.
    case rewind
    /// Take one frame now and file it with the current task.
    case snip

    /// How long a request stays live. Long enough to survive a daemon busy
    /// with an OCR pass, far short of "I walked away and came back".
    public static let staleAfter: TimeInterval = 10

    /// What a claimed request turns out to say: when it was asked for, and —
    /// for a snip the user dragged a box for — which box.
    ///
    /// One value rather than two returns because a request with a region and a
    /// request without one are the same event; the region is a refinement of it,
    /// and a caller that ignores `region` degrades to the whole screen, which is
    /// what a snip meant before this existed.
    public struct Claim: Equatable, Sendable {
        public var asked: Date
        public var region: SnipRegion?

        public init(asked: Date, region: SnipRegion? = nil) {
            self.asked = asked
            self.region = region
        }
    }

    var filename: String {
        switch self {
        case .rewind: return "rewind_request"
        case .snip: return "snip_request"
        }
    }

    public func file(in home: URL? = nil) -> URL {
        (home ?? ShifuPaths.home).appendingPathComponent(filename)
    }

    /// Asks for this to happen. Whole seconds, so the file stays the ASCII
    /// integer `pause_until` taught every reader in this codebase to expect —
    /// followed, when the user dragged a box, by that box on the same line.
    ///
    /// `region` is only meaningful for `.snip`; a rewind is the buffer, and the
    /// buffer is whole frames.
    public func ask(now: Date = Date(), home: URL? = nil, region: SnipRegion? = nil) throws {
        if home == nil { try ShifuPaths.ensureHomeExists() }
        var line = String(Int(now.timeIntervalSince1970))
        if self == .snip, let region, region.isUsable { line += " " + region.encoded }
        try line.write(to: file(in: home), atomically: true, encoding: .utf8)
    }

    /// Takes the request if there is a fresh one, and removes the file either
    /// way — a stale request is consumed rather than left to fire later.
    ///
    /// Returns what was asked for, or nil for no request at all. A *stale*
    /// request also returns nil, which is why the caller can't tell the two
    /// apart and doesn't need to: neither is something to act on.
    ///
    /// A line with no region is a whole-screen snip — the shape this file had
    /// before regions existed, and still the shape the player's "Keep this
    /// frame" writes. A line with a region that *doesn't parse* is refused
    /// outright rather than widened to the whole screen: the user drew a box
    /// around something, and capturing everything around it instead is the one
    /// failure mode this feature must not have.
    public func claim(now: Date = Date(), home: URL? = nil) -> Claim? {
        let url = file(in: home)
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        try? FileManager.default.removeItem(at: url)
        let fields = raw.split(whereSeparator: \.isWhitespace)
        guard let stamp = fields.first, let seconds = TimeInterval(stamp), seconds.isFinite
        else { return nil }
        var region: SnipRegion?
        if fields.count > 1 {
            guard let decoded = SnipRegion.decode(fields.dropFirst()), decoded.isUsable
            else { return nil }
            region = decoded
        }
        let asked = Date(timeIntervalSince1970: seconds)
        // Future-dated requests are as suspect as stale ones — a clock change
        // is not a licence to screenshot. `abs` covers both directions.
        guard abs(now.timeIntervalSince(asked)) <= Self.staleAfter else { return nil }
        return Claim(asked: asked, region: region)
    }

    /// Drops any pending request without acting on it. Called when capture goes
    /// down: a request written a moment before a pause must not survive it.
    public static func clearAll(home: URL? = nil) {
        for request in allCases {
            try? FileManager.default.removeItem(at: request.file(in: home))
        }
    }
}
