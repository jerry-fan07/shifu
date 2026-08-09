import Foundation
import ShifuCore
import Testing

/// The app→daemon request files (design.md §3.6).
///
/// A request is an *event*, unlike `pause_until` and `focus_mode`, which are
/// states. That difference is the whole suite: reading a state late is
/// harmless, while acting on a request late means screenshotting whatever
/// happens to be on screen when the daemon next starts.
@Suite struct RewindRequestTests {
    private func scratchHome() -> URL {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rewind-request-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    @Test func afreshRequestIsClaimedOnce() throws {
        let home = scratchHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let now = Date()

        try RewindRequest.rewind.ask(now: now, home: home)

        #expect(RewindRequest.rewind.claim(now: now, home: home) != nil)
        // Claiming consumes it: a second daemon tick must not fire it again.
        #expect(RewindRequest.rewind.claim(now: now, home: home) == nil)
    }

    /// The one that matters. A request written while the daemon was down would
    /// otherwise fire the moment it next starts — hours later, against whatever
    /// is on screen then.
    @Test func aStaleRequestIsConsumedWithoutFiring() throws {
        let home = scratchHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let asked = Date()

        try RewindRequest.rewind.ask(now: asked, home: home)
        let later = asked.addingTimeInterval(RewindRequest.staleAfter + 60)

        #expect(RewindRequest.rewind.claim(now: later, home: home) == nil)
        // Consumed, not left behind to fire on some later tick.
        #expect(!FileManager.default.fileExists(
            atPath: RewindRequest.rewind.file(in: home).path))
    }

    /// A clock that jumped backwards is not a licence to screenshot either.
    @Test func aFutureDatedRequestIsRefusedTheSameWay() throws {
        let home = scratchHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let now = Date()

        try RewindRequest.snip.ask(
            now: now.addingTimeInterval(RewindRequest.staleAfter + 60), home: home)

        #expect(RewindRequest.snip.claim(now: now, home: home) == nil)
    }

    @Test func theTwoRequestsAreIndependentFiles() throws {
        let home = scratchHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let now = Date()

        try RewindRequest.snip.ask(now: now, home: home)

        #expect(RewindRequest.rewind.claim(now: now, home: home) == nil)
        #expect(RewindRequest.snip.claim(now: now, home: home) != nil)
    }

    /// Capture going down clears the queue: a request written a moment before a
    /// pause must not survive it.
    @Test func clearingDropsEveryPendingRequest() throws {
        let home = scratchHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let now = Date()
        try RewindRequest.rewind.ask(now: now, home: home)
        try RewindRequest.snip.ask(now: now, home: home)

        RewindRequest.clearAll(home: home)

        #expect(RewindRequest.rewind.claim(now: now, home: home) == nil)
        #expect(RewindRequest.snip.claim(now: now, home: home) == nil)
    }

    @Test func garbageInTheFileIsNotARequest() throws {
        let home = scratchHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try "inf".write(
            to: RewindRequest.rewind.file(in: home), atomically: true, encoding: .utf8)

        #expect(RewindRequest.rewind.claim(home: home) == nil)
    }

    // MARK: - The dragged box

    @Test func aRegionSurvivesTheRoundTrip() throws {
        let home = scratchHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let now = Date()
        let region = SnipRegion(displayID: 2, left: 120, top: 64, width: 400, height: 300)

        try RewindRequest.snip.ask(now: now, home: home, region: region)

        #expect(RewindRequest.snip.claim(now: now, home: home)?.region == region)
    }

    /// The old shape of this file, and still what the player's "Keep this
    /// frame" writes: a bare timestamp is a whole-screen snip, not a broken one.
    @Test func aBareTimestampIsAWholeScreenSnip() throws {
        let home = scratchHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let now = Date()

        try RewindRequest.snip.ask(now: now, home: home)
        let claim = RewindRequest.snip.claim(now: now, home: home)

        #expect(claim != nil)
        #expect(claim?.region == nil)
    }

    /// **The one that matters here.** A region that doesn't parse must not
    /// widen to the whole screen: the user drew a box around one thing, and
    /// capturing everything around it instead is the failure this can't have.
    @Test func aMalformedRegionIsRefusedRatherThanWidened() throws {
        let home = scratchHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let now = Date()
        try "\(Int(now.timeIntervalSince1970)) 2 120 64 wide"
            .write(to: RewindRequest.snip.file(in: home), atomically: true, encoding: .utf8)

        #expect(RewindRequest.snip.claim(now: now, home: home) == nil)
    }

    /// A box a few pixels across is a click that slipped. Refused on the way
    /// out, so the file never carries one, and on the way in, so a hand-written
    /// one can't either.
    @Test func aBoxTooSmallToHaveBeenMeantIsNotARegion() throws {
        let home = scratchHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let now = Date()
        let sliver = SnipRegion(displayID: 1, left: 10, top: 10, width: 3, height: 2)

        try RewindRequest.snip.ask(now: now, home: home, region: sliver)
        // Written as a plain whole-screen snip…
        #expect(RewindRequest.snip.claim(now: now, home: home)?.region == nil)

        // …and refused outright when someone writes one by hand.
        try "\(Int(now.timeIntervalSince1970)) 1 10 10 3 2"
            .write(to: RewindRequest.snip.file(in: home), atomically: true, encoding: .utf8)
        #expect(RewindRequest.snip.claim(now: now, home: home) == nil)
    }

    /// Staleness still decides first: a region doesn't make an old request live.
    @Test func aStaleRegionRequestIsRefusedLikeAnyOther() throws {
        let home = scratchHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let asked = Date()
        let region = SnipRegion(displayID: 1, left: 0, top: 0, width: 400, height: 300)

        try RewindRequest.snip.ask(now: asked, home: home, region: region)
        let later = asked.addingTimeInterval(RewindRequest.staleAfter + 60)

        #expect(RewindRequest.snip.claim(now: later, home: home) == nil)
    }

    /// A rewind is the buffer, and the buffer is whole frames — a region on one
    /// is meaningless, so it never reaches the file.
    @Test func aRewindRequestNeverCarriesARegion() throws {
        let home = scratchHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let now = Date()
        let region = SnipRegion(displayID: 1, left: 0, top: 0, width: 400, height: 300)

        try RewindRequest.rewind.ask(now: now, home: home, region: region)

        #expect(RewindRequest.rewind.claim(now: now, home: home)?.region == nil)
    }
}

/// AppKit globals → ScreenCaptureKit's `sourceRect`.
///
/// The one part of the drag that is *silently* wrong when it is wrong: a
/// flipped or unshifted rect still captures something, just not what the user
/// drew a box around. Pure maths, so it is checkable without a window server —
/// which is the whole reason it lives in `ShifuCore` rather than in the view.
@Suite struct SnipRegionTests {
    /// The main screen: AppKit's origin, so only the y-flip has to happen.
    @Test func aBoxOnTheMainScreenIsFlippedButNotShifted() {
        let screen = CGRect(x: 0, y: 0, width: 1_512, height: 982)
        // 200 pts up from the bottom, 100 tall → 682 down from the top.
        let selection = CGRect(x: 40, y: 200, width: 400, height: 100)

        let region = SnipRegion.from(selection: selection, on: screen, displayID: 1)

        #expect(region == SnipRegion(
            displayID: 1, left: 40, top: 682, width: 400, height: 100))
    }

    /// A second monitor sitting to the right and higher: the box has to lose
    /// the screen's own origin as well as flip.
    @Test func aBoxOnASecondScreenIsRelativeToThatScreen() {
        let screen = CGRect(x: 1_512, y: 120, width: 1_920, height: 1_080)
        let selection = CGRect(x: 1_612, y: 900, width: 300, height: 200)

        let region = SnipRegion.from(selection: selection, on: screen, displayID: 9)

        // x: 1612 − 1512 = 100. y: (120 + 1080) − (900 + 200) = 100.
        #expect(region == SnipRegion(
            displayID: 9, left: 100, top: 100, width: 300, height: 200))
    }

    /// A drag that runs off the edge is clipped to the screen, not sent as a
    /// rect the display doesn't have.
    @Test func aDragOffTheEdgeIsClippedToTheScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        let selection = CGRect(x: -200, y: -100, width: 500, height: 400)

        let region = SnipRegion.from(selection: selection, on: screen, displayID: 1)

        // Kept part is x 0…300, y 0…300 in AppKit terms → 500 down from the top.
        #expect(region == SnipRegion(
            displayID: 1, left: 0, top: 500, width: 300, height: 300))
    }

    @Test func aSelectionEntirelyOffTheScreenIsNotUsable() {
        let screen = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        let selection = CGRect(x: 4_000, y: 4_000, width: 100, height: 100)

        #expect(!SnipRegion.from(selection: selection, on: screen, displayID: 1).isUsable)
    }

    /// A whole screen is a legal region — what ⏎ in the overlay sends, and the
    /// reason a second monitor snips the monitor you are looking at.
    @Test func awholeScreenRoundTripsToItsOwnOrigin() {
        let screen = CGRect(x: 1_512, y: 0, width: 1_920, height: 1_080)

        let region = SnipRegion.from(selection: screen, on: screen, displayID: 3)

        #expect(region == SnipRegion(
            displayID: 3, left: 0, top: 0, width: 1_920, height: 1_080))
    }
}
