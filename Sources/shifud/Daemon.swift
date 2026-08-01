import AppKit
import ApplicationServices
import ShifuCore

/// Event wiring for the capture daemon (design.md §3.1): app activation,
/// AX window/title changes, heartbeat, idle suspension, pause teardown.
@MainActor
final class Daemon: NSObject {
    static let idleThreshold: TimeInterval = 300   // 5 min without HID input
    static let titleDebounce: TimeInterval = 0.5
    /// How often to re-ask the window server while it is holding capture down
    /// (`syncRecheckTimer`). Bounds how much capture an unlock can lose.
    static let recheckInterval: TimeInterval = 5

    private let engine: CaptureEngine
    private let database: ShifuDatabase
    private let pauseController: PauseController

    private var workspaceObserverInstalled = false
    private var heartbeat: Timer?
    private var analyzerTimer: Timer?
    private var analyzerProcess: Process?
    private var axObserver: AXObserver?
    private var observedPid: pid_t?
    private var debounceWork: DispatchWorkItem?
    private var capturing = false
    private var systemStateObserversInstalled = false
    private var recheckTimer: Timer?
    private let session: SessionProbe
    /// Overridable so a test can assert the timer genuinely fires on the run
    /// loop within a test's patience, rather than only that its body works.
    private let recheckInterval: TimeInterval

    /// Last-applied interval values, so `reloadIntervals()` can tell a real
    /// change from a no-op. Seeded from the catalog defaults.
    private var currentHeartbeat = TimeInterval(SettingsCatalog.heartbeatSeconds.defaultValue)
    private var currentAnalyzerInterval =
        TimeInterval(SettingsCatalog.analysisIntervalSeconds.defaultValue)

    init(
        engine: CaptureEngine, database: ShifuDatabase,
        pauseController: PauseController = PauseController(),
        session: SessionProbe = .live,
        recheckInterval: TimeInterval = Daemon.recheckInterval
    ) {
        self.engine = engine
        self.database = database
        self.pauseController = pauseController
        self.session = session
        self.recheckInterval = recheckInterval
    }

    func start() {
        reportPermissions()
        AXHelper.installMessagingTimeout(seconds: 1)
        pauseController.onChange = { [weak self] paused in
            guard let self else { return }
            if paused {
                log("paused until \(self.pauseController.pausedUntil?.description ?? "?") — observers torn down")
            } else {
                log("resumed — observers reattached")
            }
            self.syncCapture()
            self.reloadIntervals()
        }
        pauseController.startWatching()
        installSystemStateObservers()
        reloadIntervals()   // builds the analyzer timer; heartbeat waits for startCapture()
        if pauseController.isPaused {
            log("starting paused (pause_until is in the future)")
        }
        // Decides from the *current* state, so a daemon launched while the
        // machine sits locked starts suspended without needing an edge.
        syncCapture()
    }

    /// The only place capture is turned on or off. Every reason it can be down —
    /// a user pause (§8), a locked screen, another user on the console — is
    /// re-read here on every edge, so no edge can clear another's teardown:
    /// unlocking a paused machine must not resume the capture the user paused,
    /// and waking a locked one must not resume it either, since `didWake` lands
    /// well before the password is typed.
    private func syncCapture() {
        let reasons = suspensions
        if reasons.isEmpty != capturing {
            log(reasons.isEmpty
                ? "capture active"
                : "capture down (\(reasons.joined(separator: ", "))) — session ends here")
        }
        if reasons.isEmpty { startCapture() } else { stopCapture() }
        syncRecheckTimer()
    }

    /// Re-asks the window server while it is the thing holding capture down, so
    /// coming back never depends on a notification arriving.
    ///
    /// **Measured, not defensive**, over four real lock/unlock trials on this
    /// machine (2026-07-29, macOS 26). Locking always suspended capture the same
    /// second, and held it clean — 16 minutes locked with not one row inserted or
    /// `last_seen` bumped. Unlocking was *not* always reliable. In one trial
    /// `com.apple.screenIsUnlocked` arrived with the flag already clear and
    /// capture came back in about a second; in another the daemon never resumed at
    /// all, still suspended 13 seconds later. The notification is therefore
    /// delivered on this OS but is **not ordered against the flag it describes**,
    /// so a re-decide prompted by it can read a screen that still says locked —
    /// after which an edge-driven daemon waits forever. Querying state instead of
    /// remembering it keeps the answer from being *wrong*; nothing about it makes
    /// the answer *timely*. That is this timer's job, and it is why the
    /// notifications are an optimization for latency rather than the correctness
    /// mechanism. Note the asymmetry that makes this worth a timer: a missed lock
    /// costs one filtered lock-screen block, a missed unlock costs every
    /// observation until the daemon restarts.
    ///
    /// Costs one dictionary read every `recheckInterval`, and only while the
    /// machine is locked or switched away — which is exactly when nothing else is
    /// happening. It never captures; it only re-decides. Pause is deliberately
    /// not a reason to run it: `PauseController` watches that file already.
    private func syncRecheckTimer() {
        guard suspendedBySession else {
            recheckTimer?.invalidate()
            recheckTimer = nil
            return
        }
        guard recheckTimer == nil else { return }
        let timer = Timer(timeInterval: recheckInterval, repeats: true) { _ in
            MainActor.assumeIsolated { [weak self] in self?.recheckNow() }
        }
        RunLoop.main.add(timer, forMode: .common)
        recheckTimer = timer
    }

    /// One recheck, the timer's whole body. Exposed so a test drives the same
    /// path the timer takes rather than a lookalike of it.
    func recheckNow() { syncCapture() }

    /// Everything currently keeping capture down, in human words for the log.
    /// Empty means capture should be running.
    ///
    /// Every reason is *asked for* rather than remembered, so there is no
    /// suspension state to get stuck — but see `recheckTimer`: an answer this
    /// fresh is still only as timely as whatever last asked for it.
    private var suspensions: [String] {
        var reasons: [String] = []
        if session.screenIsLocked() { reasons.append("screen locked") }
        if !session.isOnConsole() { reasons.append("another session on the console") }
        if pauseController.isPaused { reasons.append("paused by the user") }
        return reasons
    }

    /// True while the window server — not the pause file — is what holds capture
    /// down. `recheckTimer` runs exactly then.
    private var suspendedBySession: Bool {
        session.screenIsLocked() || !session.isOnConsole()
    }

    // MARK: - Capture lifecycle (pause = real teardown, §8)

    /// What is currently wired up. Invariant 5 — "pause tears down observers,
    /// it doesn't just gate writes" (design.md §8) — is a statement about this
    /// struct, so exposing it turns a hand review into an assertion.
    struct ObserverState: Equatable {
        var capturing = false
        var workspaceObserver = false
        var heartbeat = false
        var axObserver = false
        var debounce = false
        /// Deliberately *not* torn down by pause: the analyzer only touches
        /// already-captured data, so it keeps running while capture is off.
        var analyzerTimer = false
        /// Also deliberately not torn down by pause — they are what notices the
        /// machine came back, so a paused-then-slept daemon still resumes on the
        /// right edge.
        var systemStateObservers = false
        /// Live only while the window server is holding capture down, and it is
        /// what ends that state — so "capture can always come back" is an
        /// assertion here rather than a hope about notification delivery.
        var recheckTimer = false
    }

    var observerState: ObserverState {
        ObserverState(
            capturing: capturing,
            workspaceObserver: workspaceObserverInstalled,
            heartbeat: heartbeat != nil,
            axObserver: axObserver != nil,
            debounce: debounceWork != nil,
            analyzerTimer: analyzerTimer != nil,
            systemStateObservers: systemStateObserversInstalled,
            recheckTimer: recheckTimer != nil)
    }

    func startCapture() {
        guard !capturing else { return }
        capturing = true

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil
        )
        workspaceObserverInstalled = true

        reloadIntervals()   // rebuilds the heartbeat stopCapture() tore down

        if let app = NSWorkspace.shared.frontmostApplication {
            attachAXObserver(to: app)
            engine.capture(app: app, trigger: "startup")
        }
    }

    func stopCapture() {
        guard capturing else { return }
        capturing = false
        if workspaceObserverInstalled {
            NSWorkspace.shared.notificationCenter.removeObserver(
                self, name: NSWorkspace.didActivateApplicationNotification, object: nil
            )
            workspaceObserverInstalled = false
        }
        heartbeat?.invalidate()
        heartbeat = nil
        debounceWork?.cancel()
        debounceWork = nil
        detachAXObserver()
    }

    /// NSWorkspace posts this on the main thread; the class is @MainActor.
    @objc private func appActivated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else { return }
        attachAXObserver(to: app)
        engine.capture(app: app, trigger: "activate")
    }

    // MARK: - Screen lock (§3.1)

    /// Screen lock has no `NSWorkspace` notification; these are the long-standing
    /// distributed ones macOS posts for it.
    private static let screenLocked = Notification.Name("com.apple.screenIsLocked")
    private static let screenUnlocked = Notification.Name("com.apple.screenIsUnlocked")

    /// What the daemon asks the window server about the session it is watching.
    /// Injectable for the same reason `CaptureEngine.Probe` is: a test can drive
    /// a locked screen or a backgrounded session without having one.
    struct SessionProbe: Sendable {
        var screenIsLocked: @Sendable () -> Bool
        var isOnConsole: @Sendable () -> Bool

        /// Both flags **default to "don't suspend"** when the key is missing,
        /// which is the safe direction: an unreadable key degrades to capturing
        /// (a stray lock-screen block, filtered from every display) rather than
        /// to silently capturing nothing at all. `CGSSessionScreenIsLocked` is in
        /// fact absent whenever the screen is unlocked, so for it that is not a
        /// fallback but the documented encoding.
        static let live = SessionProbe(
            screenIsLocked: { flag("CGSSessionScreenIsLocked") ?? false },
            isOnConsole: { flag("kCGSSessionOnConsoleKey") ?? true })

        /// The flags are CFBooleans that could as easily have been CFNumbers, so
        /// read them as `NSNumber` — that bridges both, where `as? Bool` would
        /// report a locked screen as unlocked if the type ever changed.
        private static func flag(_ key: String) -> Bool? {
            guard let session = CGSessionCopyCurrentDictionary() as NSDictionary? else { return nil }
            return (session[key] as? NSNumber)?.boolValue
        }
    }

    /// Ends the session when the screen locks, instead of leaving one block open
    /// across the gap.
    ///
    /// The idle suspension in `heartbeatFired` does not cover this.
    /// `secondsSinceLastInput` reports the *user session's* HID idle time, and at
    /// the lock screen that session is not the one receiving events, so the
    /// counter never climbs past the threshold. The heartbeat then captures
    /// `loginwindow` every interval; each capture is a near-duplicate of the last
    /// (both content-free `meta`, so `isNearDuplicate` is trivially true), and
    /// every hit slides that row's dedupe TTL forward again — so
    /// `ObservationRecorder` keeps bumping one row's `last_seen` for as long as
    /// the machine stays locked. The dogfood ledger holds a single observation
    /// spanning 60 hours that way, and the 60-hour activity block built from it.
    ///
    /// Tearing capture down breaks that loop: with no heartbeat there is nothing
    /// to bump, the row's dedupe TTL expires during the gap, and the next capture
    /// starts a fresh observation that the sessionizer reads as a new block
    /// (`Sessionizer.gapThresholdMs`). A lock shorter than that TTL still joins
    /// the previous block, which is correct — 30 seconds is not a boundary.
    ///
    /// **Sleep needs no handling of its own.** While the machine is asleep
    /// nothing executes: no timer fires, no capture is taken, no `last_seen` is
    /// bumped. On wake the wall clock has moved past the dedupe TTL, so the next
    /// capture inserts a new row and the sessionizer splits the block there —
    /// `ObservationRecorderTests.dedupeStateExpiresPastTTLInsertsNewRow` is that
    /// guarantee. `didWake` is still subscribed, but only as a *trigger to
    /// re-decide*: a lock posted while the machine was asleep can be dropped, and
    /// waking is not unlocking, so the one thing the daemon must not do on wake
    /// is assume it may capture again.
    ///
    /// These observers outlive pause on purpose (see `ObserverState`), so they
    /// are installed once from `start()` and never removed.
    private func installSystemStateObservers() {
        guard !systemStateObserversInstalled else { return }
        // Every notification points at the same handler: none of them carries
        // state, they only ask the daemon to look at the session again.
        // Both centers deliver on the main run loop, and the class is @MainActor.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification,
                     NSWorkspace.sessionDidResignActiveNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            workspace.addObserver(self, selector: #selector(sessionStateChanged),
                                  name: name, object: nil)
        }
        let distributed = DistributedNotificationCenter.default()
        for name in [Self.screenLocked, Self.screenUnlocked] {
            distributed.addObserver(self, selector: #selector(sessionStateChanged),
                                    name: name, object: nil)
        }
        systemStateObserversInstalled = true
    }

    /// The screen locked or unlocked, the machine woke, or the console changed
    /// hands. *Which* of those it was is deliberately not a question this handler
    /// asks — it re-reads the session and lets `syncCapture` decide.
    @objc func sessionStateChanged() { syncCapture() }

    // MARK: - Heartbeat & idle (§3.1)

    private func heartbeatFired() {
        // Before the idle guard: an idle machine must still pick up new values.
        reloadIntervals()
        guard Self.secondsSinceLastInput() < Self.idleThreshold else { return }  // idle: suspend
        guard Date().timeIntervalSince(engine.lastCaptureAt) >= currentHeartbeat - 1 else { return }
        engine.captureFrontmost(trigger: "heartbeat")
    }

    /// Lazy idle check — min over the common HID event kinds.
    static func secondsSinceLastInput() -> TimeInterval {
        let kinds: [CGEventType] = [.keyDown, .mouseMoved, .leftMouseDown, .scrollWheel]
        return kinds.map {
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0)
        }.min() ?? 0
    }

    // MARK: - AX observation (window focus / title changes)

    private func attachAXObserver(to app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard pid != observedPid else { return }
        detachAXObserver()

        var observer: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let daemon = Unmanaged<Daemon>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { daemon.windowChanged() }
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }

        let element = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for notification in [kAXFocusedWindowChangedNotification, kAXTitleChangedNotification] {
            AXObserverAddNotification(observer, element, notification as CFString, refcon)
        }
        CFRunLoopAddSource(
            CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode
        )
        axObserver = observer
        observedPid = pid
    }

    private func detachAXObserver() {
        if let observer = axObserver {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode
            )
        }
        axObserver = nil
        observedPid = nil
    }

    /// Window/title change, debounced 500 ms (§3.1).
    private func windowChanged() {
        debounceWork?.cancel()
        let work = DispatchWorkItem {
            MainActor.assumeIsolated { [weak self] in
                self?.engine.captureFrontmost(trigger: "window")
            }
        }
        debounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.titleDebounce, execute: work)
    }

    // MARK: - Interval settings (design.md §9)

    /// Applies the user's current interval settings, rebuilding a timer only
    /// when its value actually changed (or when it doesn't exist yet).
    ///
    /// The changed-guard is load-bearing, not an optimization: rebuilding the
    /// analyzer timer on every heartbeat would reset its hourly countdown each
    /// minute and it would never fire.
    ///
    /// Idempotent, so it's safe to call from anywhere — and it is called from
    /// four places, because no single one covers every state: `startCapture()`,
    /// `heartbeatFired()`, the pause edge, and `runAnalyzer()` (the only one
    /// that still runs while paused).
    private func reloadIntervals() {
        let beat = TimeInterval(Settings.value(SettingsCatalog.heartbeatSeconds, database: database))
        // `capturing` guard: pause is a real teardown (design.md §8) — never
        // resurrect the heartbeat here while capture is meant to be stopped.
        if capturing, beat != currentHeartbeat || heartbeat == nil {
            heartbeat?.invalidate()
            let timer = Timer(timeInterval: beat, repeats: true) { _ in
                MainActor.assumeIsolated { [weak self] in self?.heartbeatFired() }
            }
            RunLoop.main.add(timer, forMode: .common)
            heartbeat = timer
            if beat != currentHeartbeat { log("heartbeat interval now \(Int(beat))s") }
        }
        currentHeartbeat = beat

        let cadence = TimeInterval(
            Settings.value(SettingsCatalog.analysisIntervalSeconds, database: database))
        if cadence != currentAnalyzerInterval || analyzerTimer == nil {
            analyzerTimer?.invalidate()
            let timer = Timer(timeInterval: cadence, repeats: true) { _ in
                MainActor.assumeIsolated { [weak self] in self?.runAnalyzer() }
            }
            RunLoop.main.add(timer, forMode: .common)
            analyzerTimer = timer
            if cadence != currentAnalyzerInterval { log("analysis interval now \(Int(cadence))s") }
        }
        currentAnalyzerInterval = cadence
    }

    // MARK: - Analyzer scheduling (§2.2)

    /// Spawns shifu-analyzer on the user's analysis interval. A separate process
    /// so analysis spikes can never make the capture path feel heavy; it
    /// self-gates on battery. Runs even while paused — it only processes
    /// already-captured data, which is also why it re-reads settings here: with
    /// the heartbeat torn down, this is the only live reload path left.
    private func runAnalyzer() {
        reloadIntervals()
        if let existing = analyzerProcess, existing.isRunning { return }
        guard let analyzerURL = ShifuPaths.helper("shifu-analyzer") else {
            log("analyzer not found next to shifud or in ~/Shifu/bin — skipping")
            return
        }
        let process = Process()
        process.executableURL = analyzerURL
        process.qualityOfService = .utility
        do {
            try process.run()
            analyzerProcess = process
        } catch {
            log("failed to launch analyzer: \(error)")
        }
    }

    // MARK: - Permissions (§10: degrade, don't die)

    private func reportPermissions() {
        if !AXIsProcessTrusted() {
            log("WARNING: Accessibility permission missing — metadata-only capture. " +
                "Grant in System Settings → Privacy & Security → Accessibility.")
        }
        if !CGPreflightScreenCaptureAccess() {
            log("WARNING: Screen Recording permission missing — OCR rung disabled. " +
                "Grant in System Settings → Privacy & Security → Screen Recording.")
        }
    }
}

func log(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    print("[\(stamp)] \(message)")
}
