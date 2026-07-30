import Foundation
import ShifuCore
import Testing
@testable import shifud

/// Invariant 5 (CLAUDE.md, design.md §8): **pause tears down observers, it
/// doesn't just gate writes.** ARCHITECTURE.md §5 listed this as "structural
/// only — no automated guard"; `Daemon.observerState` is what turns it into an
/// assertion.
///
/// The distinction matters because a gate is invisible in the wrong direction:
/// a daemon that keeps its AX observer attached while "paused" is still asking
/// the frontmost app for its window title on every focus change, which is
/// exactly the reading the user paused to stop.
@MainActor
@Suite(.serialized) struct DaemonTeardownTests {
    private func daemon() throws -> Daemon {
        let database = try ShifuDatabase.inMemory()
        let engine = CaptureEngine(
            recorder: ObservationRecorder(database: database),
            exclusions: try Exclusions(database: database),
            probe: CaptureEngine.Probe(
                focusedWindow: { _ in nil }, title: { _ in nil }, webAreaURL: { _ in nil },
                extractText: { _, _ in "" }, enableWebAccessibility: { _ in },
                ocrText: { _ in nil }))
        return Daemon(engine: engine, database: database)
    }

    @Test func stopCaptureRemovesEveryCaptureSideObserver() throws {
        let daemon = try daemon()
        daemon.startCapture()
        let running = daemon.observerState
        #expect(running.capturing)
        #expect(running.workspaceObserver)
        #expect(running.heartbeat)

        daemon.stopCapture()
        let paused = daemon.observerState
        #expect(!paused.capturing)
        #expect(!paused.workspaceObserver)
        #expect(!paused.heartbeat)
        #expect(!paused.axObserver)
        #expect(!paused.debounce)
    }

    @Test func pauseLeavesTheAnalyzerTimerAlone() throws {
        let daemon = try daemon()
        daemon.startCapture()
        #expect(daemon.observerState.analyzerTimer)

        // The analyzer only touches already-captured data, so it keeps its
        // schedule while capture is off (ARCHITECTURE.md §6).
        daemon.stopCapture()
        #expect(daemon.observerState.analyzerTimer)
    }

    @Test func resumingReattachesWhatPauseToreDown() throws {
        let daemon = try daemon()
        daemon.startCapture()
        daemon.stopCapture()
        daemon.startCapture()

        let state = daemon.observerState
        #expect(state.capturing)
        #expect(state.workspaceObserver)
        #expect(state.heartbeat)
        daemon.stopCapture()
    }

    @Test func repeatedStartsAndStopsAreIdempotent() throws {
        let daemon = try daemon()
        daemon.startCapture()
        let afterOne = daemon.observerState
        daemon.startCapture()
        #expect(daemon.observerState == afterOne)

        daemon.stopCapture()
        let stopped = daemon.observerState
        daemon.stopCapture()
        #expect(daemon.observerState == stopped)
    }

    @Test func aDaemonThatNeverStartedHasNothingAttached() throws {
        let state = try daemon().observerState
        #expect(state == Daemon.ObserverState())
    }
}

/// Browser awareness (design.md §8). Private-window detection is not
/// configurable, so its markers are part of the privacy contract.
@Suite struct BrowsersTests {
    @Test func everyChromiumBrowserIsAlsoABrowser() {
        for bundle in Browsers.chromiumBundleIDs {
            #expect(Browsers.isBrowser(bundle), "\(bundle) is chromium but not a browser")
        }
    }

    @Test func safariAndFirefoxAreBrowsersButNotChromium() {
        #expect(Browsers.isBrowser("com.apple.Safari"))
        #expect(Browsers.isBrowser("org.mozilla.firefox"))
        #expect(!Browsers.isChromium("com.apple.Safari"))
        #expect(!Browsers.isChromium("org.mozilla.firefox"))
    }

    @Test func nonBrowsersAreNeitherAndMatchingIsExact() {
        #expect(!Browsers.isBrowser("com.apple.dt.Xcode"))
        // A prefix or suffix of a real id must not slip through.
        #expect(!Browsers.isBrowser("com.apple.Safari.helper"))
        #expect(!Browsers.isBrowser("Safari"))
    }

    @Test func everyVendorsPrivateMarkerIsRecognized() {
        // Safari, Chrome, Firefox and Edge each word it differently.
        #expect(Browsers.isPrivateWindow(title: "Start Page — Private Browsing"))
        #expect(Browsers.isPrivateWindow(title: "New Tab (Incognito)"))
        #expect(Browsers.isPrivateWindow(title: "Mozilla Firefox (Private)"))
        #expect(Browsers.isPrivateWindow(title: "New tab - InPrivate"))
    }

    @Test func ordinaryTitlesAndAMissingTitleAreNotPrivate() {
        #expect(!Browsers.isPrivateWindow(title: "Inbox (23) — Gmail"))
        #expect(!Browsers.isPrivateWindow(title: nil))
        #expect(!Browsers.isPrivateWindow(title: ""))
    }
}
