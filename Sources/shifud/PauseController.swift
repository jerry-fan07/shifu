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

    var pausedUntil: Date? {
        guard let raw = try? String(contentsOf: ShifuPaths.pauseFile, encoding: .utf8),
              let expiry = TimeInterval(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        let date = Date(timeIntervalSince1970: expiry)
        return date > Date() ? date : nil
    }

    var isPaused: Bool { pausedUntil != nil }

    func startWatching() {
        let fd = open(ShifuPaths.home.path, O_EVTONLY)
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
