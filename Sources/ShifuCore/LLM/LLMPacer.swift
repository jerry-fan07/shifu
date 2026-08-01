import Foundation

/// Duty-cycle governor for a *local* LLM endpoint (design.md §4.2).
///
/// A local server pins the GPU for exactly as long as it computes, and the
/// analyzer's stages fire their calls back-to-back — so a catch-up run is
/// minutes of uninterrupted load, which is precisely what spins the fans:
/// they respond to sustained heat, not peaks. The pacer breaks that block
/// into bursts by resting before each call, proportionally to how long the
/// previous one took. At 40% duty a 30-second call is followed by 45 seconds
/// of rest; total work is unchanged, only spread thin enough to stay under
/// the fan threshold.
///
/// The duty is re-picked per call from two signals the caller injects:
/// whether the user is present (rest harder while they can hear the fans,
/// gentler once the screen locks or input goes idle) and the machine's
/// thermal state (`.serious` halves the duty whatever its source — another
/// app's heat still needs yielding to; `.critical` pauses outright). Both
/// are closures, and so is the sleep itself, so every branch is testable
/// without a clock.
///
/// One instance is shared by both model slots — their calls interleave on one
/// sequential pipeline, so pacing them as a single stream is what bounds the
/// GPU's duty, and a per-slot pacer would forget the other slot's last burst.
public actor LLMPacer {
    /// Rest is proportional to the previous call, but never longer than this:
    /// a runaway ten-minute prefill at low duty must not park the pipeline
    /// for the better part of an hour.
    public static let maxRestSeconds = 300.0
    /// One poll of a `.critical` machine — long enough to actually shed heat
    /// between reads, short enough to resume promptly once it clears.
    static let criticalPollSeconds = 30.0
    /// The floor no configuration or thermal halving can push duty below;
    /// matches the settings range so a hand-edited row can't stall the run.
    static let dutyPercentRange = 10...100

    public nonisolated let activeDutyPercent: Int
    public nonisolated let idleDutyPercent: Int
    private let userIsAway: @Sendable () -> Bool
    private let thermalState: @Sendable () -> ProcessInfo.ThermalState
    private let rest: @Sendable (Double) async -> Void
    private var lastCallSeconds: Double?

    public init(
        activeDutyPercent: Int, idleDutyPercent: Int,
        userIsAway: @escaping @Sendable () -> Bool,
        thermalState: @escaping @Sendable () -> ProcessInfo.ThermalState = {
            ProcessInfo.processInfo.thermalState
        },
        rest: @escaping @Sendable (Double) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    ) {
        self.activeDutyPercent = Self.clampDuty(activeDutyPercent)
        self.idleDutyPercent = Self.clampDuty(idleDutyPercent)
        self.userIsAway = userIsAway
        self.thermalState = thermalState
        self.rest = rest
    }

    /// Call before each LLM request. The first request of a run never waits —
    /// there is no burst to recover from yet.
    public func willCall() async {
        while thermalState() == .critical {
            await rest(Self.criticalPollSeconds)
        }
        guard let lastCallSeconds, lastCallSeconds > 0 else { return }
        let duty = Double(effectiveDutyPercent())
        guard duty < 100 else { return }
        await rest(min(lastCallSeconds * (100 / duty - 1), Self.maxRestSeconds))
    }

    /// Call after each LLM request with how long the server took. A failed
    /// request records nothing and the previous burst's rest stands.
    public func didCall(seconds: Double) {
        lastCallSeconds = max(seconds, 0)
    }

    private func effectiveDutyPercent() -> Int {
        let base = userIsAway() ? idleDutyPercent : activeDutyPercent
        guard thermalState() == .serious else { return base }
        return Self.clampDuty(base / 2)
    }

    private static func clampDuty(_ percent: Int) -> Int {
        min(max(percent, dutyPercentRange.lowerBound), dutyPercentRange.upperBound)
    }
}

extension LLMPacer {
    /// The production pacer, or nil when pacing doesn't apply: the endpoint
    /// is a cloud host (the network round trip is the rest, and sleeping
    /// between calls would only slow the pipeline without cooling anything)
    /// or both duties are dialed to 100.
    public static func ifLocal(
        database: ShifuDatabase, userIsAway: @escaping @Sendable () -> Bool
    ) -> LLMPacer? {
        guard let base = try? Settings.get(Settings.deepseekBaseURLKey, database: database),
              let host = URL(string: base)?.host, isLoopback(host)
        else { return nil }
        let active = Settings.value(SettingsCatalog.llmDutyActive, database: database)
        let idle = Settings.value(SettingsCatalog.llmDutyIdle, database: database)
        guard active < 100 || idle < 100 else { return nil }
        return LLMPacer(
            activeDutyPercent: active, idleDutyPercent: idle, userIsAway: userIsAway)
    }

    /// "On this Mac" means loopback, nothing broader: a LAN server's heat is
    /// some other machine's problem.
    static func isLoopback(_ host: String) -> Bool {
        ["localhost", "127.0.0.1", "::1", "0.0.0.0"].contains(host.lowercased())
    }
}
