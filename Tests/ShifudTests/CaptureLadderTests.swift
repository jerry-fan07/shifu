import ApplicationServices
import Foundation
import ShifuCore
import Testing
@testable import shifud

/// The capture ladder (design.md §3.2) and the two privacy invariants that
/// live in it: exclusions are enforced *before* capture (CLAUDE.md 3), and the
/// cheap rungs are tried before the expensive ones so a screenshot is only ever
/// taken when AX came up short.
///
/// ARCHITECTURE.md §5 listed invariant 3's ordering as "structural — no test".
/// It is testable once the ladder's outside world is a seam: the fake below
/// records every read it is asked for, so "an excluded window reaches no
/// reader" is an assertion about `probe.calls` rather than a code review.
@MainActor
@Suite struct CaptureLadderTests {
    /// Records what the ladder asked the outside world for, in order.
    final class Spy {
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

    struct Harness {
        let database: ShifuDatabase
        let engine: CaptureEngine
        let spy: Spy

        func observations() throws -> [Observation] {
            try database.queue.read { try Observation.order(sql: "id").fetchAll($0) }
        }
    }

    private func harness(excluding domains: [String] = [],
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
        let engine = CaptureEngine(
            recorder: ObservationRecorder(database: database),
            exclusions: try Exclusions(database: database),
            probe: spy.probe())
        return Harness(database: database, engine: engine, spy: spy)
    }

    private func capture(_ harness: Harness, bundle: String, pid: pid_t = 4_242,
                         launchDate: Date? = nil) async {
        harness.engine.capture(bundle: bundle, pid: pid, launchDate: launchDate,
                               trigger: "test")
        await harness.engine.ocrTask?.value
    }

    // MARK: - Invariant 3: exclusion before any content read

    @Test func excludedBundleReachesNoReaderAtAll() async throws {
        let harness = try harness(bundles: ["com.agilebits.onepassword7"])
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
        let harness = try harness()
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
        let harness = try harness(excluding: ["chase.com"])
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
        let harness = try harness()
        harness.spy.window = nil
        await capture(harness, bundle: "com.apple.Safari")

        #expect(!harness.spy.didReadContent)
        let rows = try harness.observations()
        #expect(rows[0].captureKind == .meta)
        #expect(rows[0].text == nil)
    }

    @Test func sufficientAXTextStopsTheLadderBeforeOCR() async throws {
        let harness = try harness()
        harness.spy.title = "docs"
        harness.spy.axText = String(repeating: "a", count: CaptureEngine.axTextFloor)
        await capture(harness, bundle: "com.apple.Safari")

        #expect(harness.spy.ocrCallCount == 0)
        let rows = try harness.observations()
        #expect(rows[0].captureKind == .ax)
        #expect(rows[0].text?.count == CaptureEngine.axTextFloor)
    }

    @Test func textOneCharBelowTheFloorFallsThroughToOCR() async throws {
        let harness = try harness()
        harness.spy.axText = String(repeating: "a", count: CaptureEngine.axTextFloor - 1)
        harness.spy.ocrResult = OCRCapture.Result(text: "screen text from OCR", dhash: 7)
        await capture(harness, bundle: "com.apple.Safari")

        #expect(harness.spy.ocrCallCount == 1)
        let rows = try harness.observations()
        #expect(rows[0].captureKind == .ocr)
        #expect(rows[0].text == "screen text from OCR")
    }

    // MARK: - The dHash gate (§3.2)

    @Test func unchangedScreenBumpsLastSeenInsteadOfInsertingARow() async throws {
        let harness = try harness()
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
        let harness = try harness()
        harness.spy.title = "Editor"
        harness.spy.ocrResult = OCRCapture.Result(text: "first page", dhash: 0x0f0f_0f0f)
        await capture(harness, bundle: "com.example.editor")

        harness.spy.ocrResult = OCRCapture.Result(text: "a wholly different page", dhash: 0xf0f0_f0f0)
        await capture(harness, bundle: "com.example.editor")

        #expect(try harness.observations().count == 2)
    }

    @Test func theGateIsPerWindowNotGlobal() async throws {
        let harness = try harness()
        harness.spy.title = "Left"
        harness.spy.ocrResult = OCRCapture.Result(text: "left pane", dhash: 0x1111)
        await capture(harness, bundle: "com.example.editor")

        // A different window with the same screen hash is still new content.
        harness.spy.title = "Right"
        harness.spy.ocrResult = OCRCapture.Result(text: "right pane", dhash: 0x1111)
        await capture(harness, bundle: "com.example.editor")

        #expect(try harness.observations().count == 2)
    }

    // MARK: - Degradation (design.md §10): never drop a trigger

    @Test func ocrFailureFallsBackToTheAXTextItAlreadyHad() async throws {
        let harness = try harness()
        harness.spy.axText = "short but real"
        harness.spy.ocrError = LLMError.unavailable("no screen recording permission")
        await capture(harness, bundle: "com.example.editor")

        let rows = try harness.observations()
        #expect(rows.count == 1)
        #expect(rows[0].captureKind == .ax)
        #expect(rows[0].text == "short but real")
    }

    @Test func ocrFailureWithNoAXTextStillRecordsDuration() async throws {
        let harness = try harness()
        harness.spy.axText = ""
        harness.spy.ocrError = LLMError.unavailable("denied")
        await capture(harness, bundle: "com.example.editor")

        let rows = try harness.observations()
        #expect(rows.count == 1)
        #expect(rows[0].captureKind == .meta)
    }

    @Test func noCapturableWindowDegradesRatherThanDroppingTheTrigger() async throws {
        let harness = try harness()
        harness.spy.axText = "a little text"
        harness.spy.ocrResult = nil
        await capture(harness, bundle: "com.example.editor")

        let rows = try harness.observations()
        #expect(rows.count == 1)
        #expect(rows[0].captureKind == .ax)
    }

    @Test func emptyOCRTextDegradesToMetadata() async throws {
        let harness = try harness()
        harness.spy.axText = ""
        harness.spy.ocrResult = OCRCapture.Result(text: "", dhash: 99)
        await capture(harness, bundle: "com.example.editor")

        #expect(try harness.observations()[0].captureKind == .meta)
    }

    // MARK: - Chromium web-AX poke (§3.4: one round-trip, not one per capture)

    @Test func chromiumIsPokedOncePerProcessLifetime() async throws {
        let harness = try harness()
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
        let harness = try harness()
        harness.spy.axText = String(repeating: "a", count: 100)
        await capture(harness, bundle: "com.apple.Safari")
        #expect(!harness.spy.calls.contains("enableWebAX"))
    }

    @Test func nonBrowsersNeverHaveTheirURLRead() async throws {
        let harness = try harness()
        harness.spy.axText = String(repeating: "a", count: 100)
        await capture(harness, bundle: "com.apple.dt.Xcode")

        #expect(!harness.spy.calls.contains("webAreaURL"))
        #expect(try harness.observations()[0].url == nil)
    }

    // MARK: - Work Mode's hook

    @Test func onCaptureReportsBundleURLAndExclusion() async throws {
        let harness = try harness(bundles: ["com.private.app"])
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
