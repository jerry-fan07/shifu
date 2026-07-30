import AppKit
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
/// A scratch `~/Shifu` for one test, so a pause is a real file without mutating
/// `SHIFU_HOME` — that variable is process-global and would serialize every test
/// that touched it.
private func scratchHome() throws -> URL {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("shifu-daemon-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    return home
}

/// A session whose state a test can drive, standing in for the window server.
/// A reference type because the daemon *queries* it on every decision — the
/// whole point is that flipping a field changes later answers.
private final class FakeSession: @unchecked Sendable {
    var locked = false
    var onConsole = true

    var probe: Daemon.SessionProbe {
        Daemon.SessionProbe(screenIsLocked: { self.locked }, isOnConsole: { self.onConsole })
    }
}

/// A daemon over an in-memory database and a probe that reads nothing, so the
/// lifecycle is exercised without touching AX, the screen, or the real `~/Shifu`.
@MainActor
private func makeDaemon(
    pausedUntil: Date? = nil, home: URL? = nil, session: FakeSession? = nil,
    recheckInterval: TimeInterval = Daemon.recheckInterval
) throws -> Daemon {
    let database = try ShifuDatabase.inMemory()
    let engine = CaptureEngine(
        recorder: ObservationRecorder(database: database),
        exclusions: try Exclusions(database: database),
        probe: CaptureEngine.Probe(
            focusedWindow: { _ in nil }, title: { _ in nil }, webAreaURL: { _ in nil },
            extractText: { _, _ in "" }, enableWebAccessibility: { _ in },
            ocrText: { _ in nil }))
    var pauseHome = home
    if let pausedUntil {
        let target = try pauseHome ?? scratchHome()
        try PauseFile.pause(until: pausedUntil, home: target)
        pauseHome = target
    }
    return Daemon(engine: engine, database: database,
                  pauseController: PauseController(home: pauseHome),
                  session: session?.probe ?? FakeSession().probe,
                  recheckInterval: recheckInterval)
}

@MainActor
@Suite(.serialized) struct DaemonTeardownTests {
    private func daemon() throws -> Daemon { try makeDaemon() }

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

/// A locked screen must end the session, not just idle through it.
///
/// The idle suspension in `heartbeatFired` cannot do this job: at the lock screen
/// the HID idle counter belongs to a session that isn't receiving events, so it
/// never crosses the threshold, and the heartbeat goes on refreshing one
/// `loginwindow` observation's `last_seen` for as long as the machine stays
/// locked. That produced a single 60-hour observation — and block — in the
/// dogfood ledger. Tearing capture down is what stops the refresh.
///
/// Sleep needs no case of its own here: nothing executes while a machine is
/// asleep, so the gap ends the session through the dedupe TTL
/// (`ObservationRecorderTests.dedupeStateExpiresPastTTLInsertsNewRow`). What sleep
/// *can* do is deliver a wake while the screen is still locked, which is the
/// first test below.
@MainActor
@Suite(.serialized) struct DaemonSuspensionTests {
    @Test func lockingTearsDownTheHeartbeatThatWouldKeepTheBlockOpen() throws {
        let session = FakeSession()
        let daemon = try makeDaemon(session: session)
        daemon.startCapture()
        #expect(daemon.observerState.heartbeat)

        session.locked = true
        daemon.sessionStateChanged()
        let suspended = daemon.observerState
        #expect(!suspended.capturing)
        #expect(!suspended.heartbeat)
        #expect(!suspended.workspaceObserver)
        #expect(!suspended.axObserver)
    }

    @Test func unlockingReattachesCapture() throws {
        let session = FakeSession()
        let daemon = try makeDaemon(session: session)
        daemon.startCapture()
        session.locked = true
        daemon.sessionStateChanged()

        session.locked = false
        daemon.sessionStateChanged()
        #expect(daemon.observerState.capturing)
        #expect(daemon.observerState.heartbeat)
        daemon.stopCapture()
    }

    /// **Sleep autolocks, then wake, then unlock — the everyday sequence.**
    ///
    /// `didWake` lands while the password prompt is still up: seconds later if you
    /// are sitting there, hours later if the lid was bumped or a scheduled wake
    /// fired. Treating wake as a resume would hand the heartbeat back to
    /// `loginwindow` for the whole lock, which is exactly the 60-hour block. Only
    /// the unlock may bring capture back — and because the lock is queried rather
    /// than remembered, that holds even though *no lock notification is delivered
    /// here at all* (one posted while the machine was asleep can be dropped).
    @Test func wakingBeforeTheUnlockDoesNotResumeCapture() throws {
        let session = FakeSession()
        let daemon = try makeDaemon(session: session)
        daemon.startCapture()

        session.locked = true         // slept, and autolocked while asleep
        daemon.sessionStateChanged()  // ← wake, the only edge delivered
        #expect(!daemon.observerState.capturing)
        #expect(!daemon.observerState.heartbeat)

        session.locked = false        // password typed
        daemon.sessionStateChanged()
        #expect(daemon.observerState.capturing)
        #expect(daemon.observerState.heartbeat)
        daemon.stopCapture()
    }

    /// A machine that does *not* autolock: waking it resumes capture, because
    /// nothing is holding it down. The block still splits on the sleep gap — that
    /// is the dedupe TTL's job, not this file's.
    @Test func wakingAnUnlockedMachineResumesCapture() throws {
        let daemon = try makeDaemon()
        daemon.startCapture()
        daemon.stopCapture()

        daemon.sessionStateChanged()   // wake, screen never locked
        #expect(daemon.observerState.capturing)
        daemon.stopCapture()
    }

    /// Fast user switching is the same failure shape as a lock — our session is
    /// in the background, so the idle counter is just as blind — and it is
    /// queried the same way, so it needs no state either.
    @Test func anotherSessionOnTheConsoleHoldsCaptureDown() throws {
        let session = FakeSession()
        let daemon = try makeDaemon(session: session)
        daemon.startCapture()

        session.onConsole = false
        daemon.sessionStateChanged()
        #expect(!daemon.observerState.capturing)

        session.onConsole = true
        daemon.sessionStateChanged()
        #expect(daemon.observerState.capturing)
        daemon.stopCapture()
    }

    /// Two independent reasons at once: the console came back but the screen is
    /// still locked, so capture stays down. Neither may speak for the other.
    @Test func oneReasonClearingIsNotEnoughToResume() throws {
        let session = FakeSession()
        let daemon = try makeDaemon(session: session)
        daemon.startCapture()

        session.locked = true
        session.onConsole = false
        daemon.sessionStateChanged()
        #expect(!daemon.observerState.capturing)

        session.onConsole = true
        daemon.sessionStateChanged()
        #expect(!daemon.observerState.capturing)

        session.locked = false
        daemon.sessionStateChanged()
        #expect(daemon.observerState.capturing)
        daemon.stopCapture()
    }

    /// Pause is a third reason, and the same rule holds: unlocking a machine the
    /// user paused must not resume the reading they paused to stop (invariant 5).
    @Test func unlockingWhilePausedDoesNotResumeCapture() throws {
        let session = FakeSession()
        let daemon = try makeDaemon(pausedUntil: Date().addingTimeInterval(3_600),
                                    session: session)
        session.locked = true
        daemon.sessionStateChanged()
        session.locked = false
        daemon.sessionStateChanged()

        #expect(!daemon.observerState.capturing)
        #expect(!daemon.observerState.heartbeat)
    }

    /// A daemon launched while the machine already sits locked — a LaunchAgent
    /// relaunch at 2am — hears no lock edge, because the lock already happened.
    /// Querying the screen rather than tracking it makes that fall out for free
    /// instead of needing its own seeding step.
    @Test func startingWhileLockedStartsSuspended() throws {
        let session = FakeSession()
        session.locked = true
        let daemon = try makeDaemon(home: try scratchHome(), session: session)
        daemon.start()
        #expect(!daemon.observerState.capturing)

        session.locked = false
        daemon.sessionStateChanged()
        #expect(daemon.observerState.capturing)
        daemon.stopCapture()
    }

    /// The handler tests above would all still pass if the daemon subscribed to
    /// the wrong notification, which is the easiest way for this to break in the
    /// field. `start()` installs the real observers, so posting a real name
    /// asserts the subscription rather than the handler.
    @Test func theRealWakeNotificationDrivesTheDecision() throws {
        let session = FakeSession()
        let daemon = try makeDaemon(home: try scratchHome(), session: session)
        daemon.start()
        #expect(daemon.observerState.systemStateObservers)
        #expect(daemon.observerState.capturing)

        session.locked = true
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didWakeNotification, object: nil)
        #expect(!daemon.observerState.capturing)
        #expect(!daemon.observerState.heartbeat)

        session.locked = false
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didWakeNotification, object: nil)
        #expect(daemon.observerState.capturing)
        daemon.stopCapture()
    }

    /// **The failure a real lock/unlock actually produced** (2026-07-29, macOS 26):
    /// capture went down the second the screen locked and then never came back —
    /// no unlock edge was ever delivered, or it arrived while the flag still read
    /// locked. So the daemon must not need one. While the window server holds
    /// capture down it re-asks on a timer, and *that* is what resumes.
    @Test func captureComesBackWithNoUnlockEdgeAtAll() throws {
        let session = FakeSession()
        let daemon = try makeDaemon(session: session)
        daemon.startCapture()

        session.locked = true
        daemon.sessionStateChanged()
        #expect(!daemon.observerState.capturing)
        // The timer is the standing promise that this state can end itself.
        #expect(daemon.observerState.recheckTimer)

        session.locked = false        // unlocked, and nothing tells the daemon
        daemon.recheckNow()           // what the timer does when it fires
        #expect(daemon.observerState.capturing)
        #expect(!daemon.observerState.recheckTimer)
        daemon.stopCapture()
    }

    /// The recheck has to fire **by itself**, which the test above does not show:
    /// it calls the timer's body directly, so it would pass just as well if the
    /// timer were never scheduled on a run loop. That is not a hypothetical
    /// failure — it is the difference between the fix working and the daemon
    /// sitting suspended forever, which is exactly what the real machine did. So
    /// this one schedules a genuine `Timer` and services the main run loop.
    @Test func theRecheckTimerFiresOnItsOwn() throws {
        let session = FakeSession()
        let daemon = try makeDaemon(session: session, recheckInterval: 0.05)
        daemon.startCapture()
        session.locked = true
        daemon.sessionStateChanged()
        #expect(!daemon.observerState.capturing)

        // No edge, no direct call: the only thing that can notice is the timer.
        session.locked = false
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        #expect(daemon.observerState.capturing)
        #expect(!daemon.observerState.recheckTimer)
        daemon.stopCapture()
    }

    /// The recheck exists for the window server, not for pause — `PauseController`
    /// already watches its file, and a timer per paused daemon would be a second
    /// mechanism for a solved problem.
    @Test func pauseAloneDoesNotArmTheRecheck() throws {
        let daemon = try makeDaemon(pausedUntil: Date().addingTimeInterval(3_600))
        daemon.sessionStateChanged()
        #expect(!daemon.observerState.capturing)
        #expect(!daemon.observerState.recheckTimer)
    }

    /// Locked *and* paused: the recheck runs while the lock holds, and stands down
    /// when only the pause is left, without resuming capture.
    @Test func theRecheckStandsDownWhenOnlyThePauseRemains() throws {
        let session = FakeSession()
        let daemon = try makeDaemon(pausedUntil: Date().addingTimeInterval(3_600),
                                    session: session)
        session.locked = true
        daemon.sessionStateChanged()
        #expect(daemon.observerState.recheckTimer)

        session.locked = false
        daemon.recheckNow()
        #expect(!daemon.observerState.recheckTimer)
        #expect(!daemon.observerState.capturing)
    }

    /// Repeated edges of the same kind — two locks with no unlock between them,
    /// an unlock with no lock before it. Nothing is counted, so nothing drifts.
    @Test func repeatedEdgesAreIdempotent() throws {
        let session = FakeSession()
        let daemon = try makeDaemon(session: session)
        daemon.startCapture()

        session.locked = true
        daemon.sessionStateChanged()
        let suspended = daemon.observerState
        daemon.sessionStateChanged()
        #expect(daemon.observerState == suspended)

        session.locked = false
        daemon.sessionStateChanged()
        let resumed = daemon.observerState
        daemon.sessionStateChanged()
        #expect(daemon.observerState == resumed)
        daemon.stopCapture()
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
