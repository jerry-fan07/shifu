import AppKit
import ApplicationServices
import ShifuCore

/// Event wiring for the capture daemon (design.md §3.1): app activation,
/// AX window/title changes, heartbeat, idle suspension, pause teardown.
@MainActor
final class Daemon: NSObject {
    static let idleThreshold: TimeInterval = 300   // 5 min without HID input
    static let heartbeatInterval: TimeInterval = 60
    static let titleDebounce: TimeInterval = 0.5

    private let engine: CaptureEngine
    private let pauseController = PauseController()

    private var workspaceObserverInstalled = false
    private var heartbeat: Timer?
    private var analyzerTimer: Timer?
    private var analyzerProcess: Process?
    private var axObserver: AXObserver?
    private var observedPid: pid_t?
    private var debounceWork: DispatchWorkItem?
    private var capturing = false

    init(engine: CaptureEngine) {
        self.engine = engine
    }

    func start() {
        reportPermissions()
        pauseController.onChange = { [weak self] paused in
            guard let self else { return }
            if paused {
                log("paused until \(self.pauseController.pausedUntil?.description ?? "?") — observers torn down")
                self.stopCapture()
            } else {
                log("resumed — observers reattached")
                self.startCapture()
            }
        }
        pauseController.startWatching()
        scheduleAnalyzer()
        if pauseController.isPaused {
            log("starting paused (pause_until is in the future)")
        } else {
            startCapture()
        }
    }

    // MARK: - Capture lifecycle (pause = real teardown, §8)

    private func startCapture() {
        guard !capturing else { return }
        capturing = true

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil
        )
        workspaceObserverInstalled = true

        let timer = Timer(timeInterval: Self.heartbeatInterval, repeats: true) { _ in
            MainActor.assumeIsolated { [weak self] in self?.heartbeatFired() }
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeat = timer

        if let app = NSWorkspace.shared.frontmostApplication {
            attachAXObserver(to: app)
            engine.capture(app: app, trigger: "startup")
        }
    }

    private func stopCapture() {
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

    // MARK: - Heartbeat & idle (§3.1)

    private func heartbeatFired() {
        guard Self.secondsSinceLastInput() < Self.idleThreshold else { return }  // idle: suspend
        guard Date().timeIntervalSince(engine.lastCaptureAt) >= Self.heartbeatInterval - 1 else { return }
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

    // MARK: - Analyzer scheduling (§2.2)

    /// Spawns shifu-analyzer hourly. A separate process so analysis spikes can
    /// never make the capture path feel heavy; it self-gates on battery.
    /// Runs even while paused — it only processes already-captured data.
    private func scheduleAnalyzer() {
        let timer = Timer(timeInterval: 3_600, repeats: true) { _ in
            MainActor.assumeIsolated { [weak self] in self?.runAnalyzer() }
        }
        RunLoop.main.add(timer, forMode: .common)
        analyzerTimer = timer
    }

    private func runAnalyzer() {
        if let existing = analyzerProcess, existing.isRunning { return }
        let selfPath = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let analyzerURL = selfPath.deletingLastPathComponent()
            .appendingPathComponent("shifu-analyzer")
        guard FileManager.default.isExecutableFile(atPath: analyzerURL.path) else {
            log("analyzer not found next to shifud (\(analyzerURL.path)) — skipping")
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
