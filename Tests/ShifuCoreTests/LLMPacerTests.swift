import Foundation
import Testing
@testable import ShifuCore

/// The duty-cycle math behind quiet local inference (design.md §4.2). Every
/// signal the pacer reads — presence, thermal state, the sleep itself — is a
/// closure, so each branch pins without a clock or a real GPU burn.
@Suite struct LLMPacerTests {
    /// Thread-safe capture for the injected closures: the recorded rests and
    /// the mutable presence/thermal state a test flips mid-run.
    private final class Signals: @unchecked Sendable {
        private let lock = NSLock()
        private var restsStorage: [Double] = []
        private var awayStorage = false
        private var thermalStorage: ProcessInfo.ThermalState = .nominal

        var rests: [Double] {
            lock.lock(); defer { lock.unlock() }
            return restsStorage
        }
        var away: Bool {
            get { lock.lock(); defer { lock.unlock() }; return awayStorage }
            set { lock.lock(); awayStorage = newValue; lock.unlock() }
        }
        var thermal: ProcessInfo.ThermalState {
            get { lock.lock(); defer { lock.unlock() }; return thermalStorage }
            set { lock.lock(); thermalStorage = newValue; lock.unlock() }
        }
        func recordRest(_ seconds: Double) {
            lock.lock(); restsStorage.append(seconds); lock.unlock()
        }
    }

    private static func makePacer(
        active: Int, idle: Int, signals: Signals
    ) -> LLMPacer {
        LLMPacer(
            activeDutyPercent: active, idleDutyPercent: idle,
            userIsAway: { signals.away },
            thermalState: { signals.thermal },
            rest: { signals.recordRest($0) })
    }

    @Test func theFirstCallNeverRests() async {
        let signals = Signals()
        let pacer = Self.makePacer(active: 40, idle: 75, signals: signals)
        await pacer.willCall()
        #expect(signals.rests.isEmpty)
    }

    @Test func restIsProportionalToThePreviousCall() async {
        let signals = Signals()
        let pacer = Self.makePacer(active: 40, idle: 75, signals: signals)
        await pacer.didCall(seconds: 10)
        await pacer.willCall()
        // 40% duty: rest (100/40 − 1) = 1.5× the burst.
        #expect(signals.rests == [15])
    }

    @Test func awaySwitchesToTheIdleDutyAndBackWithinOneCall() async {
        let signals = Signals()
        let pacer = Self.makePacer(active: 50, idle: 75, signals: signals)
        await pacer.didCall(seconds: 30)
        signals.away = true
        await pacer.willCall()   // 75%: rest 30 × (1/3) = 10
        await pacer.didCall(seconds: 30)
        signals.away = false
        await pacer.willCall()   // 50%: rest 30 × 1 = 30
        #expect(signals.rests.count == 2)
        #expect(abs(signals.rests[0] - 10) < 0.001)  // 100/75 is not exact in binary
        #expect(signals.rests[1] == 30)
    }

    @Test func seriousThermalPressureHalvesTheDuty() async {
        let signals = Signals()
        let pacer = Self.makePacer(active: 40, idle: 75, signals: signals)
        await pacer.didCall(seconds: 10)
        signals.thermal = .serious
        await pacer.willCall()
        // 40% halved to 20%: rest (100/20 − 1) = 4× the burst.
        #expect(signals.rests == [40])
    }

    @Test func criticalThermalPressurePausesUntilItDrops() async {
        // Thermal reads as critical until two poll sleeps have happened, so
        // the loop is provably re-checking after each rest rather than
        // deciding once.
        let signals = Signals()
        let pacer = LLMPacer(
            activeDutyPercent: 100, idleDutyPercent: 100,
            userIsAway: { false },
            thermalState: { signals.rests.count >= 2 ? .nominal : .critical },
            rest: { signals.recordRest($0) })
        await pacer.willCall()
        #expect(signals.rests == [LLMPacer.criticalPollSeconds, LLMPacer.criticalPollSeconds])
    }

    @Test func fullDutyNeverRests() async {
        let signals = Signals()
        let pacer = Self.makePacer(active: 100, idle: 100, signals: signals)
        await pacer.didCall(seconds: 120)
        await pacer.willCall()
        #expect(signals.rests.isEmpty)
    }

    @Test func restIsCappedForRunawayBursts() async {
        let signals = Signals()
        let pacer = Self.makePacer(active: 10, idle: 75, signals: signals)
        await pacer.didCall(seconds: 600)
        await pacer.willCall()
        // Uncapped this would be 600 × 9 = 5400s of rest.
        #expect(signals.rests == [LLMPacer.maxRestSeconds])
    }

    @Test func dutyBelowTheFloorIsClampedNotHonored() async {
        let signals = Signals()
        let pacer = Self.makePacer(active: 1, idle: 75, signals: signals)
        await pacer.didCall(seconds: 10)
        await pacer.willCall()
        // Clamped to 10%: rest 9× the burst, not 99×.
        #expect(signals.rests == [90])
    }

    // MARK: - ifLocal factory

    @Test func cloudAndUnsetEndpointsGetNoPacer() throws {
        let database = try ShifuDatabase.inMemory()
        #expect(LLMPacer.ifLocal(database: database, userIsAway: { false }) == nil)
        try Settings.set(Settings.deepseekBaseURLKey,
                         to: "https://api.deepseek.com", database: database)
        #expect(LLMPacer.ifLocal(database: database, userIsAway: { false }) == nil)
    }

    @Test func aLoopbackEndpointGetsAPacerUnlessDutyIsFull() throws {
        let database = try ShifuDatabase.inMemory()
        try Settings.set(Settings.deepseekBaseURLKey,
                         to: "http://127.0.0.1:8080/v1", database: database)
        #expect(LLMPacer.ifLocal(database: database, userIsAway: { false }) != nil)

        try Settings.set(SettingsCatalog.llmDutyActive, to: 100, database: database)
        try Settings.set(SettingsCatalog.llmDutyIdle, to: 100, database: database)
        #expect(LLMPacer.ifLocal(database: database, userIsAway: { false }) == nil)
    }

    @Test func loopbackMeansThisMacOnly() {
        #expect(LLMPacer.isLoopback("localhost"))
        #expect(LLMPacer.isLoopback("127.0.0.1"))
        #expect(LLMPacer.isLoopback("::1"))
        // A LAN server's heat is some other machine's problem.
        #expect(!LLMPacer.isLoopback("192.168.1.20"))
        #expect(!LLMPacer.isLoopback("api.deepseek.com"))
    }
}
