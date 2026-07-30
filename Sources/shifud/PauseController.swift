import Foundation
import ShifuCore

/// Watches the pause control file (design.md §8). The CLI writes a unix-seconds
/// expiry to `~/Shifu/pause_until`; while it is in the future, capture is torn
/// down — not just gated.
@MainActor
final class PauseController {
    var onChange: ((_ paused: Bool) -> Void)?

    private var dirSource: DispatchSourceFileSystemObject?
    private var resumeTimer: Timer?
    private var wasPaused = false

    /// Where `pause_until` lives, or nil for the real `~/Shifu` — the same
    /// override every `PauseFile` entry point takes, and for the same reason: a
    /// test can point one controller somewhere else without mutating
    /// `SHIFU_HOME`, which is process-global and serializes everything that
    /// touches it.
    private let home: URL?

    init(home: URL? = nil) {
        self.home = home
    }

    var pausedUntil: Date? { PauseFile.expiry(home: home) }

    var isPaused: Bool { pausedUntil != nil }

    func startWatching() {
        let fd = open((home ?? ShifuPaths.home).path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write], queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.evaluate() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        dirSource = source
        evaluate()
    }

    private func evaluate() {
        let paused = isPaused
        if paused, let until = pausedUntil {
            // Wake exactly at expiry to resume.
            resumeTimer?.invalidate()
            let timer = Timer(fire: until.addingTimeInterval(1), interval: 0, repeats: false) { _ in
                MainActor.assumeIsolated { [weak self] in self?.evaluate() }
            }
            RunLoop.main.add(timer, forMode: .common)
            resumeTimer = timer
        } else {
            resumeTimer?.invalidate()
            resumeTimer = nil
        }
        if paused != wasPaused {
            wasPaused = paused
            onChange?(paused)
        }
    }
}
