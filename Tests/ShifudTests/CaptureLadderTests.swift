import ApplicationServices
import Foundation
import ShifuCore
import Testing
@testable import shifud

// MARK: - Shared harness

/// Records what the ladder asked the outside world for, in order.
private final class Spy {
    var calls: [String] = []
    /// A window handle the fake can hand back. AX elements are CF types
    /// with no public initializer, but one for our own process is free and
    /// the fake never dereferences it.
    var window: AXUIElement? = AXUIElementCreateApplication(getpid())
    var title: String?
    var url: String?
    var axText = ""
    var ocrResult: OCRCapture.Result? = OCRCapture.Result(text: "", dhash: 0)
    var ocrError: Error?
    var ocrCallCount = 0

    var didReadContent: Bool { calls.contains { $0 == "extractText" || $0 == "ocr" } }

    func probe() -> CaptureEngine.Probe {
        CaptureEngine.Probe(
            focusedWindow: { _ in self.calls.append("focusedWindow"); return self.window },
            title: { _ in self.calls.append("title"); return self.title },
            webAreaURL: { _ in self.calls.append("webAreaURL"); return self.url },
            extractText: { _, _ in self.calls.append("extractText"); return self.axText },
            enableWebAccessibility: { _ in self.calls.append("enableWebAX") },
            ocrText: { _ in
                self.calls.append("ocr")
                self.ocrCallCount += 1
                if let error = self.ocrError { throw error }
                return self.ocrResult
            })
    }
}

/// Wall time the test moves by hand. The ladder's two dedupe states expire on
/// different schedules, so "how long was the user away" is an input to the
/// ladder as much as the screen contents are.
private final class FakeClock {
    var now = Date(timeIntervalSince1970: 1_700_000_000)
    func advance(_ seconds: TimeInterval) { now.addTimeInterval(seconds) }
}

private struct Harness {
    let database: ShifuDatabase
    let engine: CaptureEngine
    let spy: Spy
    let clock: FakeClock

    func observations() throws -> [Observation] {
        try database.queue.read { try Observation.order(sql: "id").fetchAll($0) }
    }
}

@MainActor
private func makeHarness(excluding domains: [String] = [],
                         bundles: [String] = []) throws -> Harness {
    let database = try ShifuDatabase.inMemory()
    try database.queue.write { db in
        for domain in domains {
            try db.execute(sql: "INSERT INTO exclusions (kind, value) VALUES ('domain', ?)",
                           arguments: [domain])
        }
        for bundle in bundles {
            try db.execute(sql: "INSERT INTO exclusions (kind, value) VALUES ('bundle', ?)",
                           arguments: [bundle])
        }
    }
    let spy = Spy()
    let clock = FakeClock()
    let engine = CaptureEngine(
        recorder: ObservationRecorder(database: database),
        exclusions: try Exclusions(database: database),
        probe: spy.probe(),
        now: { clock.now })
    return Harness(database: database, engine: engine, spy: spy, clock: clock)
}

@MainActor
private func capture(_ harness: Harness, bundle: String, pid: pid_t = 4_242,
                     launchDate: Date? = nil) async {
    harness.engine.capture(bundle: bundle, pid: pid, launchDate: launchDate,
                           trigger: "test")
    await harness.engine.ocrTask?.value
}

/// Two rung-3 triggers inside one OCR pass — the collision `ocrInFlight`
/// guards. The flag is set synchronously before the pass is spawned, so two
/// captures in one turn reach it the same way two run-loop turns do in
/// production.
@MainActor
private func collidingCaptures(_ harness: Harness, bundle: String) async {
    harness.engine.capture(bundle: bundle, pid: 1, launchDate: nil, trigger: "window")
    harness.clock.advance(0.3)   // inside one OCR pass (~300 ms measured)
    harness.engine.capture(bundle: bundle, pid: 1, launchDate: nil, trigger: "window")
    await harness.engine.ocrTask?.value
}

/// The capture ladder (design.md §3.2) and the two privacy invariants that
/// live in it: exclusions are enforced *before* capture (CLAUDE.md 3), and the
/// cheap rungs are tried before the expensive ones so a screenshot is only ever
/// taken when AX came up short.
///
/// ARCHITECTURE.md §5 listed invariant 3's ordering as "structural — no test".
/// It is testable once the ladder's outside world is a seam: the fake above
/// records every read it is asked for, so "an excluded window reaches no
/// reader" is an assertion about `probe.calls` rather than a code review.
@MainActor
@Suite struct CaptureLadderTests {
    // MARK: - Invariant 3: exclusion before any content read

    @Test func excludedBundleReachesNoReaderAtAll() async throws {
        let harness = try makeHarness(bundles: ["com.agilebits.onepassword7"])
        harness.spy.axText = String(repeating: "secret ", count: 100)
        await capture(harness, bundle: "com.agilebits.onepassword7")

        // Not merely "no text on disk" — the ladder never even looked.
        #expect(harness.spy.calls.isEmpty)
        let rows = try harness.observations()
        #expect(rows.count == 1)
        #expect(rows[0].captureKind == .excluded)
        #expect(rows[0].text == nil)
        #expect(rows[0].windowTitle == nil)
    }

    @Test func privateBrowserWindowIsExcludedBeforeURLOrTextIsRead() async throws {
        let harness = try makeHarness()
        harness.spy.title = "Shopping — Private Browsing"
        harness.spy.url = "https://bank.test/accounts"
        harness.spy.axText = String(repeating: "balance ", count: 100)
        await capture(harness, bundle: "com.apple.Safari")

        #expect(!harness.spy.calls.contains("webAreaURL"))
        #expect(!harness.spy.didReadContent)
        let rows = try harness.observations()
        #expect(rows[0].captureKind == .excluded)
        #expect(rows[0].text == nil)
        #expect(rows[0].url == nil)
    }

    @Test func excludedDomainIsExcludedBeforeTextIsRead() async throws {
        let harness = try makeHarness(excluding: ["chase.com"])
        harness.spy.title = "Chase — Accounts"
        harness.spy.url = "https://secure.chase.com/accounts"
        harness.spy.axText = String(repeating: "balance ", count: 100)
        await capture(harness, bundle: "com.apple.Safari")

        #expect(!harness.spy.didReadContent)
        let rows = try harness.observations()
        #expect(rows[0].captureKind == .excluded)
        #expect(rows[0].text == nil)
        #expect(rows[0].url == nil)
    }

    // MARK: - Rung order: cheapest first, OCR only as a last resort

    @Test func noAccessibilityDegradesToMetadataOnly() async throws {
        let harness = try makeHarness()
        harness.spy.window = nil
        await capture(harness, bundle: "com.apple.Safari")

        #expect(!harness.spy.didReadContent)
        let rows = try harness.observations()
        #expect(rows[0].captureKind == .meta)
        #expect(rows[0].text == nil)
    }

    @Test func sufficientAXTextStopsTheLadderBeforeOCR() async throws {
        let harness = try makeHarness()
        harness.spy.title = "docs"
        harness.spy.axText = String(repeating: "a", count: CaptureEngine.axTextFloor)
        await capture(harness, bundle: "com.apple.Safari")

        #expect(harness.spy.ocrCallCount == 0)
        let rows = try harness.observations()
        #expect(rows[0].captureKind == .ax)
        #expect(rows[0].text?.count == CaptureEngine.axTextFloor)
    }

    @Test func textOneCharBelowTheFloorFallsThroughToOCR() async throws {
        let harness = try makeHarness()
        harness.spy.axText = String(repeating: "a", count: CaptureEngine.axTextFloor - 1)
        harness.spy.ocrResult = OCRCapture.Result(text: "screen text from OCR", dhash: 7)
        await capture(harness, bundle: "com.apple.Safari")

        #expect(harness.spy.ocrCallCount == 1)
        let rows = try harness.observations()
        #expect(rows[0].captureKind == .ocr)
        #expect(rows[0].text == "screen text from OCR")
    }

    // MARK: - Degradation (design.md §10): never drop a trigger

    @Test func ocrFailureFallsBackToTheAXTextItAlreadyHad() async throws {
        let harness = try makeHarness()
        harness.spy.axText = "short but real"
        harness.spy.ocrError = LLMError.unavailable("no screen recording permission")
        await capture(harness, bundle: "com.example.editor")

        let rows = try harness.observations()
        #expect(rows.count == 1)
        #expect(rows[0].captureKind == .ax)
        #expect(rows[0].text == "short but real")
    }

    @Test func ocrFailureWithNoAXTextStillRecordsDuration() async throws {
        let harness = try makeHarness()
        harness.spy.axText = ""
        harness.spy.ocrError = LLMError.unavailable("denied")
        await capture(harness, bundle: "com.example.editor")

        let rows = try harness.observations()
        #expect(rows.count == 1)
        #expect(rows[0].captureKind == .meta)
    }

    @Test func noCapturableWindowDegradesRatherThanDroppingTheTrigger() async throws {
        let harness = try makeHarness()
        harness.spy.axText = "a little text"
        harness.spy.ocrResult = nil
        await capture(harness, bundle: "com.example.editor")

        let rows = try harness.observations()
        #expect(rows.count == 1)
        #expect(rows[0].captureKind == .ax)
    }

    /// A second rung-3 trigger arriving while the first still holds the OCR
    /// rung. The rung is serialized to stay inside the CPU budget (§3.4), which
    /// is a reason to skip the *screenshot*, never a reason to skip the *row* —
    /// §10 spells this case out as "intermediate switches recorded as metadata
    /// only".
    @Test func aTriggerLandingMidOCRDegradesRatherThanDropping() async throws {
        let harness = try makeHarness()
        harness.spy.title = "Editor"
        harness.spy.axText = "short but real"
        harness.spy.ocrResult = OCRCapture.Result(text: "screen text from OCR", dhash: 0x1234)
        await collidingCaptures(harness, bundle: "com.example.editor")

        // Still exactly one screenshot: the fix must not relax the rung's
        // serialization, only stop it swallowing the trigger.
        #expect(harness.spy.ocrCallCount == 1)

        let rows = try harness.observations()
        #expect(rows.count == 2)
        #expect(rows.contains { $0.captureKind == .ax && $0.text == "short but real" })
        #expect(rows.contains { $0.captureKind == .ocr && $0.text == "screen text from OCR" })
    }

    /// The same collision from Focus Mode's side: a trigger that records
    /// nothing also reports nothing, and these collisions cluster where triggers
    /// come fastest — title churn at the 500 ms debounce — which is exactly when
    /// the glow has something to judge.
    @Test func aTriggerLandingMidOCRStillReportsToFocusMode() async throws {
        let harness = try makeHarness()
        harness.spy.title = "Editor"
        harness.spy.axText = "short but real"
        harness.spy.ocrResult = OCRCapture.Result(text: "screen text from OCR", dhash: 0x1234)
        var seen: [String] = []
        harness.engine.onCapture = { bundle, _, _ in seen.append(bundle) }

        await collidingCaptures(harness, bundle: "com.example.editor")

        #expect(seen == ["com.example.editor", "com.example.editor"])
    }

    @Test func emptyOCRTextDegradesToMetadata() async throws {
        let harness = try makeHarness()
        harness.spy.axText = ""
        harness.spy.ocrResult = OCRCapture.Result(text: "", dhash: 99)
        await capture(harness, bundle: "com.example.editor")

        #expect(try harness.observations()[0].captureKind == .meta)
    }

    // MARK: - Chromium web-AX poke (§3.4: one round-trip, not one per capture)

    @Test func chromiumIsPokedOncePerProcessLifetime() async throws {
        let harness = try makeHarness()
        let launched = Date(timeIntervalSince1970: 1_700_000_000)
        harness.spy.axText = String(repeating: "a", count: 100)

        await capture(harness, bundle: "com.google.Chrome", pid: 500, launchDate: launched)
        await capture(harness, bundle: "com.google.Chrome", pid: 500, launchDate: launched)
        #expect(harness.spy.calls.filter { $0 == "enableWebAX" }.count == 1)

        // macOS recycles pids: the same number with a different launch date is
        // a genuinely new process and must be poked again.
        await capture(harness, bundle: "com.google.Chrome", pid: 500,
                      launchDate: launched.addingTimeInterval(3_600))
        #expect(harness.spy.calls.filter { $0 == "enableWebAX" }.count == 2)
    }

    @Test func nonChromiumBrowsersAreNeverPoked() async throws {
        let harness = try makeHarness()
        harness.spy.axText = String(repeating: "a", count: 100)
        await capture(harness, bundle: "com.apple.Safari")
        #expect(!harness.spy.calls.contains("enableWebAX"))
    }

    @Test func nonBrowsersNeverHaveTheirURLRead() async throws {
        let harness = try makeHarness()
        harness.spy.axText = String(repeating: "a", count: 100)
        await capture(harness, bundle: "com.apple.dt.Xcode")

        #expect(!harness.spy.calls.contains("webAreaURL"))
        #expect(try harness.observations()[0].url == nil)
    }

    // MARK: - Focus Mode's hook

    @Test func onCaptureReportsBundleURLAndExclusion() async throws {
        let harness = try makeHarness(bundles: ["com.private.app"])
        struct Reported: Equatable {
            let bundle: String
            let url: String?
            let excluded: Bool
        }
        var seen: [Reported] = []
        harness.engine.onCapture = { seen.append(Reported(bundle: $0, url: $1, excluded: $2)) }

        harness.spy.url = "https://example.test/page"
        harness.spy.axText = String(repeating: "a", count: 100)
        await capture(harness, bundle: "com.apple.Safari")
        await capture(harness, bundle: "com.private.app")

        #expect(seen.count == 2)
        #expect(seen[0] == Reported(bundle: "com.apple.Safari",
                                    url: "https://example.test/page", excluded: false))
        #expect(seen[1].bundle == "com.private.app")
        #expect(seen[1].excluded)
    }
}

/// The dHash gate on rung 3, and the two dedupe states it sits between: the
/// engine's `lastDHashByKey` (LRU, no TTL) and the recorder's per-window state
/// (expires after `dedupeTTLMs`). "Unchanged screen" is a claim about pixels
/// alone, so every test here is ultimately about what the gate is *not*
/// entitled to conclude from it.
@MainActor
@Suite struct CaptureGateTests {
    // MARK: - The dHash gate (§3.2)

    @Test func unchangedScreenBumpsLastSeenInsteadOfInsertingARow() async throws {
        let harness = try makeHarness()
        harness.spy.title = "Movie"
        harness.spy.ocrResult = OCRCapture.Result(text: "subtitles", dhash: 0xdead_beef)
        await capture(harness, bundle: "com.apple.TV")
        let first = try harness.observations()
        #expect(first.count == 1)

        // Same screen, one heartbeat later: one row, later last_seen.
        harness.spy.ocrResult = OCRCapture.Result(text: "subtitles", dhash: 0xdead_beef)
        await capture(harness, bundle: "com.apple.TV")
        let second = try harness.observations()
        #expect(second.count == 1)
        #expect(second[0].lastSeen >= first[0].lastSeen)
    }

    @Test func changedScreenPassesTheGate() async throws {
        let harness = try makeHarness()
        harness.spy.title = "Editor"
        harness.spy.ocrResult = OCRCapture.Result(text: "first page", dhash: 0x0f0f_0f0f)
        await capture(harness, bundle: "com.example.editor")

        harness.spy.ocrResult = OCRCapture.Result(text: "a wholly different page", dhash: 0xf0f0_f0f0)
        await capture(harness, bundle: "com.example.editor")

        #expect(try harness.observations().count == 2)
    }

    @Test func theGateIsPerWindowNotGlobal() async throws {
        let harness = try makeHarness()
        harness.spy.title = "Left"
        harness.spy.ocrResult = OCRCapture.Result(text: "left pane", dhash: 0x1111)
        await capture(harness, bundle: "com.example.editor")

        // A different window with the same screen hash is still new content.
        harness.spy.title = "Right"
        harness.spy.ocrResult = OCRCapture.Result(text: "right pane", dhash: 0x1111)
        await capture(harness, bundle: "com.example.editor")

        #expect(try harness.observations().count == 2)
    }

    // MARK: - The gate vs. the dedupe TTL: coming back to an unchanged screen

    /// Sit on a static screen, switch away for longer than
    /// `ObservationRecorder.dedupeTTLMs`, switch back to the same screen.
    ///
    /// The two dedupe states in the ladder expire on different schedules —
    /// `lastDHashByKey` never does, the recorder's `lastByWindow` does after
    /// the TTL — so on return the gate says "unchanged" while the row it wants
    /// to bump is already gone. Bumping nothing and returning would drop the
    /// window out of the ledger *permanently*: the cached dHash still matches
    /// on every later heartbeat, so only a content change or a daemon restart
    /// could ever get it logged again.
    @Test func unchangedScreenPastTheDedupeTTLIsLoggedAgain() async throws {
        let harness = try makeHarness()
        harness.spy.title = "Reader"
        harness.spy.ocrResult = OCRCapture.Result(text: "page 12", dhash: 0xabcd_0000)
        await capture(harness, bundle: "com.example.reader")
        #expect(try harness.observations().count == 1)

        // Away in another app for longer than the recorder keeps this window's
        // dedupe state. Nothing about the screen itself changed.
        harness.clock.advance(TimeInterval(Sessionizer.gapThresholdMs) / 1_000 + 60)
        await capture(harness, bundle: "com.example.reader")

        let rows = try harness.observations()
        #expect(rows.count == 2)
        #expect(rows[1].captureKind == .ocr)
        #expect(rows[1].text == "page 12")

        // …and the window is not stuck the *other* way either: still inside the
        // TTL now, so the next heartbeat dedupes onto the fresh row as usual.
        harness.clock.advance(30)
        await capture(harness, bundle: "com.example.reader")
        let after = try harness.observations()
        #expect(after.count == 2)
        #expect(after[1].lastSeen > rows[1].lastSeen)
    }

    /// The same stuck state seen from Focus Mode's side: a capture that records
    /// nothing also reports nothing, so the glow stops evaluating the window
    /// even though the user is sitting on it.
    @Test func unchangedScreenPastTheDedupeTTLStillReportsToFocusMode() async throws {
        let harness = try makeHarness()
        harness.spy.title = "Reader"
        harness.spy.ocrResult = OCRCapture.Result(text: "page 12", dhash: 0xabcd_0000)
        var seen: [String] = []
        harness.engine.onCapture = { bundle, _, _ in seen.append(bundle) }

        await capture(harness, bundle: "com.example.reader")
        harness.clock.advance(TimeInterval(Sessionizer.gapThresholdMs) / 1_000 + 60)
        await capture(harness, bundle: "com.example.reader")

        #expect(seen == ["com.example.reader", "com.example.reader"])
    }

    /// Two tabs of the same site, one title between them: the gate must judge a
    /// window against **its own** last screen, never against the other tab's.
    ///
    /// Keyed on `bundle|title` alone the two tabs share a cache slot, so the
    /// hash the gate compares against belongs to whichever tab wrote last. Same
    /// site means same layout, and an 8×8 dHash is coarse enough that two pages
    /// of one site sit well within `unchangedThreshold` of each other while
    /// their text has nothing in common — so the gate calls tab A "unchanged"
    /// on the strength of tab B's pixels and drops A's new content. Qualifying
    /// the key by URL, exactly as the recorder does, makes every comparison
    /// apples-to-apples.
    @Test func theGateComparesAWindowAgainstItsOwnLastScreen() async throws {
        let harness = try makeHarness()
        harness.spy.title = "Instagram - Google Chrome"

        harness.spy.url = "https://www.instagram.com/"
        harness.spy.ocrResult = OCRCapture.Result(
            text: "home feed posts from people you follow", dhash: 0x0000_0000)
        await capture(harness, bundle: "com.google.Chrome")

        harness.spy.url = "https://www.instagram.com/explore/"
        harness.spy.ocrResult = OCRCapture.Result(
            text: "explore grid suggested reels and topics", dhash: 0xffff_ffff)
        await capture(harness, bundle: "com.google.Chrome")

        // Back to the first tab, scrolled on to wholly new content. Its screen
        // now resembles the *other* tab's — same site, same chrome — but not
        // its own earlier one.
        harness.clock.advance(10)
        harness.spy.url = "https://www.instagram.com/"
        harness.spy.ocrResult = OCRCapture.Result(
            text: "direct messages inbox unread threads", dhash: 0xffff_fffe)
        await capture(harness, bundle: "com.google.Chrome")

        let rows = try harness.observations()
        #expect(rows.count == 3)
        #expect(rows[2].url == "https://www.instagram.com/")
        #expect(rows[2].text == "direct messages inbox unread threads")
    }

    /// Two URLs behind one window title — Instagram Stories, or a pair of
    /// "New Tab" pages — captured back to back on a visually similar screen.
    ///
    /// Historically a second, independent way into the stuck state: the gate
    /// keyed on `bundle|title` while the recorder qualified by URL too, so the
    /// two shared a cached hash while owning separate rows, and the second URL
    /// was reported unchanged on the strength of the first one's hash — then
    /// dropped for good, since that hash goes on matching. Two guards now stand
    /// between: the gate key names the URL as well, and a failed `touch` is
    /// honoured rather than swallowed. Real shapes in the dogfood ledger, where
    /// one "New Tab" title covers 157 OCR rows across 2 URLs.
    @Test func twoURLsSharingATitleAreLoggedSeparately() async throws {
        let harness = try makeHarness()
        harness.spy.title = "New Tab - Google Chrome"

        harness.spy.url = "https://a.test/one"
        harness.spy.ocrResult = OCRCapture.Result(text: "page A", dhash: 0x1111)
        await capture(harness, bundle: "com.google.Chrome")

        // Same title, different URL, identical screen hash.
        harness.spy.url = "https://b.test/two"
        harness.spy.ocrResult = OCRCapture.Result(text: "page B", dhash: 0x1111)
        await capture(harness, bundle: "com.google.Chrome")

        let rows = try harness.observations()
        #expect(rows.count == 2)
        #expect(rows.map(\.url) == ["https://a.test/one", "https://b.test/two"])
        #expect(rows.map(\.text) == ["page A", "page B"])
    }
}
