import AppKit
import ShifuCore

/// The rolling buffer's clock (design.md §3.6): a frame every few seconds, one
/// immediately whenever the ladder fires, and a trim behind each.
///
/// Three things about its lifecycle are load-bearing, and all three are the
/// same rule as the rest of the daemon:
///
/// 1. **It starts and stops with capture.** `Daemon.syncCapture` is the only
///    caller, so pause, a locked screen and another user on the console all
///    tear the recorder down for free — a feature that writes pixels must not
///    have a second, independent notion of when it is allowed to run
///    (invariant 5).
/// 2. **Exclusions are checked before the screenshot**, through the ladder's
///    own predicate (`CaptureEngine.isExcluded`), and the display grab filters
///    excluded apps out at the source (invariant 3).
/// 3. **It is off unless the user switched it on.** `RewindSettings.recording`
///    defaults to false, and flipping it off drops the buffer on the spot
///    rather than leaving frames to age out over the next half hour.
///
/// Deliberately *not* idle-gated, unlike the heartbeat: someone who walks away
/// and comes back expects the last half hour to exist, and the
/// privacy-sensitive cases (lock, pause) are covered by teardown above.
///
/// **This recorder deliberately exceeds the §3.4 CPU budget at its defaults.**
/// That is not drift — it was asked for, to try the shape on real use, and
/// `rewind.hot_minutes = 0` reverts to the in-budget flat cadence at any time.
/// The buffer now runs two rates: a **high-fidelity head** (`hot_minutes`,
/// default 5, at `hot_fps`, default 8) and a **tail** thinned to one frame per
/// `frame_seconds` behind it, so scrubbing the last few minutes is
/// frame-accurate while half an hour still fits on disk.
///
/// **Measured on an M4, 2026-08-07** (960 px): a warm display grab plus JPEG
/// encode is **5.6 ms of this process's own CPU** — its 66 ms of *wall* time is
/// almost all the window server working in another process — and the write plus
/// trim is 0.30 ms. The arithmetic that follows from that:
///
/// - At one frame per 5 s: 5.9 ms every 5 s, **0.12% of one core**, inside the
///   0.5% budget. This is what `hot_minutes = 0` restores.
/// - At 8 fps, **measured end-to-end on 2026-08-08**: two 60 s samples of the
///   installed daemon gave 13.6% and 12.3% of one core — **~15–17 ms per frame,
///   and ~27× the budget**. Note that this is *three times* what the 5.6 ms
///   isolated grab predicts (5.9 × 8 ≈ 4.5%); an 8 fps duty cycle costs more per
///   frame than a 0.2 fps one. The per-frame `trimBuffer` is the first suspect —
///   it sums the whole table's bytes on every frame, which at 8 fps and ~1 700
///   rows is 8 full scans a second — but that is a hypothesis, not a
///   measurement. RSS stayed at 50 MB, inside the 80 MB budget. Disk reached
///   117 MB five minutes in, tracking the ~211 MB a five-minute head predicts,
///   so `rewind.ceiling_mb` is now a bound that is actually reached.
///
/// Depth is free and cadence is not: the window is retention only, so 5 → 30
/// minutes multiplied the footprint by six and left the duty untouched, where
/// 0.2 → 8 fps multiplies the duty by forty. Fixing that means leaving this
/// one-shot `SCScreenshotManager` path for a persistent `SCStream` into a
/// hardware encoder (design.md §12); no dial here can. The first grab of a launch
/// is slower (~139 ms wall) because `SCShareableContent` enumerates every
/// window; it happens once. Halving the interval to the 2 s floor roughly
/// triples the duty and still clears the budget — but a much larger frame
/// width would not, which is why the width is a bounded dial.
@MainActor
final class RewindRecorder {
    /// The floor between a trigger-driven frame and the one before it. Window
    /// and title churn arrives in bursts at the 500 ms debounce, and a frame
    /// per burst member would put a display grab on the daemon's main actor
    /// several times a second — the §3.4 CPU budget's worst enemy.
    static let triggerFloor: TimeInterval = 1

    /// Everything the recorder reads from outside this process, behind one
    /// seam — the same trick, and the same reason, as `CaptureEngine.Probe`:
    /// what it refuses to capture is a claim about calls that never happen,
    /// and only a recording fake can assert that.
    struct Probe {
        var frontmost: () -> (bundle: String, pid: pid_t)?
        var focusedWindow: (pid_t) -> AXUIElement?
        var title: (AXUIElement) -> String?
        var webAreaURL: (AXUIElement) -> String?
        var grab: (Int, Set<String>) async throws -> RewindShot.Result?

        @MainActor
        static func live() -> Probe {
            let shot = RewindShot()
            return Probe(
                frontmost: {
                    guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
                    let pid = app.processIdentifier
                    return (app.bundleIdentifier ?? "unknown.\(pid)", pid)
                },
                focusedWindow: { AXHelper.focusedWindow(pid: $0) },
                title: { AXHelper.string($0, kAXTitleAttribute) },
                webAreaURL: { AXHelper.webAreaURL(in: $0) },
                grab: { try await shot.capture(width: $0, excludedBundles: $1) })
        }
    }

    private let store: RewindStore
    private let database: ShifuDatabase
    private let exclusions: Exclusions
    private let probe: Probe
    /// Where the request control files live, or nil for the real `~/Shifu` —
    /// the same override `PauseController` takes, and for the same reason: a
    /// test must be able to point one recorder somewhere else without touching
    /// `SHIFU_HOME`, which is process-global.
    private let home: URL?
    private let now: () -> Date
    /// Whether `schedule()` hands its timer to the run loop.
    ///
    /// False only in tests, and it is the difference between a deterministic
    /// suite and a flaky one. A test drives the clock through `now`, but a
    /// scheduled `Timer` answers to the *wall*, so at the hot rate's 125 ms a
    /// test that takes longer than that — under load, or on a slow machine —
    /// silently gains extra frames and fails on a count it never controlled.
    /// The timer is still created either way, so `isRunning` and the teardown
    /// assertions that back invariant 5 mean exactly what they mean in
    /// production; it simply never fires on its own, and the test says when a
    /// tick happens.
    private let schedulesOnRunLoop: Bool

    private var timer: Timer?
    private var settings = RewindSettings()
    private var inFlight = false
    private var lastFrameAt: Date = .distantPast
    private var lastDecimatedAt: Date = .distantPast
    /// The in-flight grab. Held only so a test can await the frame it just
    /// asked for; nothing in the daemon reads it.
    private(set) var frameTask: Task<Void, Never>?

    init(
        store: RewindStore, database: ShifuDatabase, exclusions: Exclusions,
        probe: Probe? = nil, home: URL? = nil, now: @escaping () -> Date = Date.init,
        schedulesOnRunLoop: Bool = true
    ) {
        self.store = store
        self.database = database
        self.exclusions = exclusions
        self.probe = probe ?? .live()
        self.home = home
        self.now = now
        self.schedulesOnRunLoop = schedulesOnRunLoop
    }

    /// Whether the recorder is currently wired up — `Daemon.ObserverState`
    /// reads this, so invariant 5 covers Rewind by assertion rather than by
    /// review.
    var isRunning: Bool { timer != nil }

    var isRecording: Bool { settings.recording }

    // MARK: - Lifecycle

    func start() {
        reloadSettings()
        guard settings.recording, timer == nil else { return }
        schedule()
        captureFrame(trigger: "start")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        // A request written a moment before capture went down must not survive
        // it — the daemon coming back must not honour it minutes later.
        RewindRequest.clearAll(home: home)
    }

    /// Re-reads the dials and applies the ones that changed. Called from the
    /// daemon's heartbeat, so the switch takes effect within one beat rather
    /// than at the next daemon restart (ARCHITECTURE §7's live-reload caveat).
    func reloadSettings() {
        let fresh = RewindSettings.load(database: database)
        let wasRecording = settings.recording
        let oldInterval = settings.captureInterval
        settings = fresh

        if fresh.recording, !wasRecording {
            schedule()
            captureFrame(trigger: "start")
        } else if !fresh.recording, wasRecording {
            timer?.invalidate()
            timer = nil
            // Switching off is not "stop taking new ones" — it is "there is no
            // buffer". Saved rewinds are the user's and survive; the rolling
            // frames were never asked for once the switch went off.
            try? store.purgeBuffer()
        } else if fresh.recording, fresh.captureInterval != oldInterval, timer != nil {
            schedule()
        }
    }

    /// The ladder fired — take a frame now rather than up to a whole interval
    /// later. This is what makes "sooner if a window trigger occurs" true:
    /// the moment you switch apps is exactly the moment a rewind needs.
    func noteTrigger() {
        guard settings.recording, timer != nil else { return }
        guard now().timeIntervalSince(lastFrameAt) >= currentTriggerFloor else { return }
        captureFrame(trigger: "window")
    }

    /// The floor is there to stop title churn putting several grabs a second on
    /// the main actor — which is exactly what the hot window does deliberately,
    /// so while it is on the floor drops to one capture interval.
    ///
    /// Without this the floor would swallow nearly every switch: at 8 fps a
    /// tick is never more than 125 ms old, so a 1 s floor means `noteTrigger`
    /// always bails and no frame is ever labelled `"window"`. That label is
    /// what tail decimation preserves a bucket by, so the flat floor would
    /// quietly cost the thinned tail its context switches — the frames most
    /// worth keeping.
    private var currentTriggerFloor: TimeInterval {
        settings.hasHotWindow ? settings.captureInterval : Self.triggerFloor
    }

    private func schedule() {
        timer?.invalidate()
        let timer = Timer(
            timeInterval: settings.captureInterval, repeats: true
        ) { _ in
            MainActor.assumeIsolated { [weak self] in self?.captureFrame(trigger: "tick") }
        }
        if schedulesOnRunLoop { RunLoop.main.add(timer, forMode: .common) }
        self.timer = timer
    }

    // MARK: - One frame

    func captureFrame(trigger: String) {
        guard settings.recording else { return }
        // Serialized like the OCR rung, and for the same reason: two display
        // grabs at once would double the one expensive thing this does.
        //
        // At the hot rate this guard is also the *real* ceiling on cost. A grab
        // is ~66 ms of wall time against a 125 ms tick at 8 fps, so the timer
        // usually wins the race — but a slow grab (the first of a launch is
        // ~139 ms) simply drops its tick rather than queueing, which is what
        // stops a busy window server from turning into a backlog of pending
        // captures. The buffer thins by a frame; nothing else changes.
        guard !inFlight else { return }

        let capturedAt = now()
        let capturedAtMs = Int64(capturedAt.timeIntervalSince1970 * 1_000)
        // After the last thing that can bail: `lastFrameAt` is the trigger
        // floor's memory of a frame actually taken, so a tick that recorded
        // nothing must not shut the floor for the next second.
        guard let front = probe.frontmost() else { return }
        lastFrameAt = capturedAt

        // Rung 0, before any pixel is read (invariant 3). The window's title
        // and URL are read only to *answer this question* — a private browser
        // window and an excluded domain are both refusals, not redactions.
        var title: String?
        var url: String?
        if let window = probe.focusedWindow(front.pid) {
            title = probe.title(window)
            if Browsers.isBrowser(front.bundle) { url = probe.webAreaURL(window) }
        }
        let source = RewindStore.Source(
            appBundle: front.bundle, windowTitle: title, url: url)
        if CaptureEngine.isExcluded(
            bundle: front.bundle, title: title, url: url, exclusions: exclusions) {
            // A row with no file: time passed here and nothing was taken, which
            // is what the rail draws as a hatched band. Recording the gap is
            // not recording the content — and the gap row keeps only the
            // bundle, since the title of an excluded window is content too.
            record(nil, at: capturedAtMs,
                   source: RewindStore.Source(appBundle: front.bundle), trigger: trigger)
            return
        }

        inFlight = true
        let width = settings.frameWidth
        let excludedBundles = exclusions.bundleIDs
        frameTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.inFlight = false }
            do {
                guard let shot = try await self.probe.grab(width, excludedBundles) else { return }
                self.record(shot, at: capturedAtMs, source: source, trigger: trigger)
            } catch {
                // Screen Recording permission missing, or the display went
                // away. Neither is a reason to stop the daemon (§10) — the
                // next tick asks again.
                log("rewind frame failed: \(error)")
            }
        }
    }

    private func record(
        _ shot: RewindShot.Result?, at capturedAt: Int64,
        source: RewindStore.Source, trigger: String
    ) {
        do {
            let bitmap = shot.map {
                RewindStore.Bitmap(data: $0.data, width: $0.width, height: $0.height)
            }
            try store.appendToBuffer(
                bitmap: bitmap, at: capturedAt, source: source, trigger: trigger)
            // Thinning the tail is an optimisation, not a bound, so it runs on
            // its own slower clock — once per bucket width. Decimating on every
            // frame would re-scan the whole tail eight times a second to find
            // the one bucket that has just aged in.
            if settings.hasHotWindow,
                now().timeIntervalSince(lastDecimatedAt) >= TimeInterval(settings.frameSeconds) {
                lastDecimatedAt = now()
                try store.decimateBuffer(
                    olderThan: capturedAt - settings.hotMs, bucketMs: settings.tailBucketMs)
            }
            // The window and the ceiling stay on every frame: both are promises
            // about what is on disk *now*, and at 8 fps a skipped one is eight
            // frames of overshoot per second on a bound the user set.
            try store.trimBuffer(
                olderThan: capturedAt - settings.bufferMs, ceilingBytes: settings.ceilingBytes)
        } catch {
            log("rewind write failed: \(error)")
        }
    }
}
