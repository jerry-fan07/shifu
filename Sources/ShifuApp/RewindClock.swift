import Combine
import Foundation
import ShifuCore

/// The transport state a Rewind player is in: playing or not, how fast, and
/// where the playhead sits in *footage time* (design.md §3.6).
///
/// It deliberately knows nothing about frames. `RewindPlayback` does the
/// arithmetic and the page resolves the moment against whatever frame list it
/// is drawing, which is what lets one clock drive both players — the live
/// buffer, whose frame list changes under it every five seconds, and a saved
/// rewind, whose list never moves.
///
/// The pulse carries *measured* wall time rather than the nominal interval, so
/// a run loop busy laying out the page plays back at the right speed instead of
/// in slow motion. `RewindPlayback.maxTickSeconds` caps a stalled tick.
@MainActor final class RewindClock: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var rate: Double = 1
    /// Footage time under the playhead, in milliseconds since the epoch. Nil is
    /// the live end — the head of the buffer, or the last frame of a clip.
    @Published var moment: Double?

    /// Seconds of wall clock since the previous pulse, while playing.
    let pulse = PassthroughSubject<TimeInterval, Never>()

    private var timer: Timer?
    private var lastTick: TimeInterval = 0

    /// 30 Hz: fast enough that a scrub during playback looks continuous, slow
    /// enough that the tick itself costs nothing. The *frame* rate is whatever
    /// the footage has — the clock only decides which one to show.
    private static let tickInterval: TimeInterval = 1.0 / 30

    // MARK: - Transport

    func play() {
        guard !isPlaying else { return }
        isPlaying = true
        lastTick = ProcessInfo.processInfo.systemUptime
        // `.common` mode, not the default one: a timer on the default mode
        // stops dead while the user drags the rail, which is exactly when
        // playback stopping is most visible.
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func pause() {
        timer?.invalidate()
        timer = nil
        isPlaying = false
    }

    func toggle() {
        if isPlaying { pause() } else { play() }
    }

    /// The speed button. Cycling rather than a menu because this control has to
    /// work identically in the page and inside the borderless fullscreen
    /// window, where a panel-drawing dropdown has no business.
    func cycleRate() {
        rate = RewindPlayback.nextRate(after: rate)
    }

    /// Moving the playhead by hand — a scrub, a step, a skip, "jump to now".
    /// Playback continues from wherever it lands, like a real transport.
    func seek(to moment: Double?) {
        self.moment = moment
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - lastTick
        lastTick = now
        pulse.send(elapsed)
    }
}
