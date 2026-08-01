import Foundation
import Testing
@testable import ShifuCore

/// The two control files (design.md §8, §4.4). There is no IPC in Shifu — the
/// CLI, the daemon and the app agree only because they agree on these formats,
/// which is why the parse lives in one place and is tested once for all three.
///
/// Every case points the file at its own scratch directory rather than moving
/// `SHIFU_HOME`: that variable is process-global, so tests that mutate it can
/// only run one at a time and interfere with every other suite that does.
@Suite struct PauseFileTests {
    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shifu-pause-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func noFileMeansNotPaused() throws {
        let home = try scratch()
        #expect(PauseFile.expiry(home: home) == nil)
        #expect(!PauseFile.isPaused(home: home))
    }

    @Test func aFutureExpiryPausesAndRoundTripsToTheSecond() throws {
        let home = try scratch()
        let until = Date().addingTimeInterval(3_600)
        try PauseFile.pause(until: until, home: home)

        let expiry = try #require(PauseFile.expiry(home: home))
        #expect(abs(expiry.timeIntervalSince(until)) < 1)
        #expect(PauseFile.isPaused(home: home))
    }

    /// The property that stops a crashed CLI or a clock change from wedging
    /// capture off forever (ARCHITECTURE.md §6).
    @Test func anExpiryInThePastReadsAsNotPaused() throws {
        let home = try scratch()
        try PauseFile.pause(until: Date().addingTimeInterval(-60), home: home)
        #expect(PauseFile.expiry(home: home) == nil)
        #expect(!PauseFile.isPaused(home: home))
    }

    @Test func expiryIsJudgedAgainstTheCallersClock() throws {
        let home = try scratch()
        let until = Date().addingTimeInterval(600)
        try PauseFile.pause(until: until, home: home)
        #expect(PauseFile.expiry(now: until.addingTimeInterval(-1), home: home) != nil)
        #expect(PauseFile.expiry(now: until.addingTimeInterval(1), home: home) == nil)
    }

    @Test func resumeRemovesTheFile() throws {
        let home = try scratch()
        try PauseFile.pause(until: Date().addingTimeInterval(3_600), home: home)
        PauseFile.resume(home: home)
        #expect(!FileManager.default.fileExists(atPath: PauseFile.file(in: home).path))
        #expect(!PauseFile.isPaused(home: home))
    }

    @Test func resumingWhenNotPausedIsHarmless() throws {
        let home = try scratch()
        PauseFile.resume(home: home)
        PauseFile.resume(home: home)
        #expect(!PauseFile.isPaused(home: home))
    }

    /// The file is written by three processes and read by three; anything that
    /// isn't a finite number of seconds has to read as "not paused".
    @Test func garbageContentsReadAsNotPaused() throws {
        let home = try scratch()
        for junk in ["", "   ", "not a number", "9999-12-31", "0x10"] {
            try junk.write(to: PauseFile.file(in: home), atomically: true, encoding: .utf8)
            #expect(PauseFile.expiry(home: home) == nil, "'\(junk)' should not pause")
        }
    }

    /// `Double("1e400")` is `+infinity`, and a pause that never expires is
    /// precisely the wedged-off state the past-expiry rule exists to prevent.
    /// A truncated write or a corrupted file must fail *open*, not closed.
    @Test func aNonFiniteExpiryCannotWedgeCaptureOff() throws {
        let home = try scratch()
        for poison in ["1e400", "inf", "Infinity", "nan", "-inf"] {
            try poison.write(to: PauseFile.file(in: home), atomically: true, encoding: .utf8)
            #expect(PauseFile.expiry(home: home) == nil, "'\(poison)' should not pause")
        }
    }

    @Test func surroundingWhitespaceAndANewlineAreTolerated() throws {
        let home = try scratch()
        let expiry = Int(Date().addingTimeInterval(3_600).timeIntervalSince1970)
        try "  \(expiry)\n".write(to: PauseFile.file(in: home), atomically: true, encoding: .utf8)
        #expect(PauseFile.isPaused(home: home))
    }

    /// The file is unix **seconds**, not milliseconds. A millisecond value
    /// would read as a pause roughly 50,000 years long, so the format is worth
    /// pinning: what `pause` writes is what every reader expects.
    @Test func theFileIsWholeUnixSecondsAsASCIIDigits() throws {
        let home = try scratch()
        try PauseFile.pause(until: Date(timeIntervalSince1970: 4_102_444_800), home: home)
        let raw = try String(contentsOf: PauseFile.file(in: home), encoding: .utf8)
        #expect(raw == "4102444800")
    }

    @Test func theCLIDurationVocabulary() {
        #expect(PauseFile.duration("30m") == 1_800)
        #expect(PauseFile.duration("1h") == 3_600)
        #expect(PauseFile.duration("2h") == 7_200)
        #expect(PauseFile.duration("90m") == nil)
        #expect(PauseFile.duration("") == nil)
        #expect(PauseFile.duration("1H") == nil)
    }

    @Test func tomorrowIsTheNextMidnightNotTwentyFourHoursOut() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let evening = calendar.date(from: DateComponents(
            timeZone: calendar.timeZone, year: 2026, month: 6, day: 10, hour: 22))!

        let seconds: TimeInterval = try #require(
            PauseFile.duration("tomorrow", now: evening, calendar: calendar))
        #expect(seconds == 2 * 3_600)
    }
}

@Suite struct FocusModeFileTests {
    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shifu-focusmode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func presenceAloneIsTheState() throws {
        let home = try scratch()
        #expect(!FocusModeFile.isOn(home: home))
        try FocusModeFile.turnOn(home: home)
        #expect(FocusModeFile.isOn(home: home))
        FocusModeFile.turnOff(home: home)
        #expect(!FocusModeFile.isOn(home: home))
    }

    @Test func turningOnTwiceLeavesItOn() throws {
        let home = try scratch()
        try FocusModeFile.turnOn(home: home)
        try FocusModeFile.turnOn(home: home)
        #expect(FocusModeFile.isOn(home: home))
    }

    @Test func turningOffWhenAlreadyOffIsHarmless() throws {
        let home = try scratch()
        FocusModeFile.turnOff(home: home)
        #expect(!FocusModeFile.isOn(home: home))
    }

    /// The daemon watches *identity*, not existence, so a fast off→on has to
    /// present a new token — that is what makes it a new session rather than
    /// no change at all.
    @Test func aFastOffOnCyclePresentsANewToken() throws {
        let home = try scratch()
        let file = FocusModeFile.file(in: home)

        try FocusModeFile.turnOn(home: home)
        let first = try #require(ControlFileToken(at: file))
        FocusModeFile.turnOff(home: home)
        #expect(ControlFileToken(at: file) == nil)

        try FocusModeFile.turnOn(home: home)
        let second = try #require(ControlFileToken(at: file))
        #expect(first != second)
    }

    // MARK: - Adopting the pre-rename name

    /// Upgrading with Focus Mode left on. The state has to survive under the
    /// new name — and survive as the *same* token, because the daemon compares
    /// identity: a token change across a restart would read as the user having
    /// ended a session and begun another, and log an adherence row saying so.
    @Test func aLegacyFileIsAdoptedWithoutLookingLikeANewSession() throws {
        let home = try scratch()
        let legacy = FocusModeFile.legacyFile(in: home)
        try Data().write(to: legacy)
        let before = try #require(ControlFileToken(at: legacy))

        FocusModeFile.adoptLegacyName(home: home)

        #expect(FocusModeFile.isOn(home: home))
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        let after = try #require(ControlFileToken(at: FocusModeFile.file(in: home)))
        #expect(after == before)
    }

    /// The adoption is on every entry point, so no upgraded binary can read
    /// the old state as "off" merely by being the first one to run.
    @Test func everyEntryPointSeesALegacyFile() throws {
        for act in [{ (home: URL) in #expect(FocusModeFile.isOn(home: home)) },
                    { (home: URL) in
                        FocusModeFile.turnOff(home: home)
                        #expect(!FocusModeFile.isOn(home: home))
                    }] {
            let home = try scratch()
            try Data().write(to: FocusModeFile.legacyFile(in: home))
            act(home)
            #expect(!FileManager.default.fileExists(
                atPath: FocusModeFile.legacyFile(in: home).path))
        }
    }

    /// A mixed pair of binaries — an old daemon still toggling `work_mode`
    /// under a new app writing `focus_mode`. The new name is the live state,
    /// so the stale file loses rather than resurrecting an old toggle.
    @Test func theNewNameWinsWhenBothExist() throws {
        let home = try scratch()
        try FocusModeFile.turnOn(home: home)
        let live = try #require(ControlFileToken(at: FocusModeFile.file(in: home)))
        try Data().write(to: FocusModeFile.legacyFile(in: home))

        FocusModeFile.adoptLegacyName(home: home)

        #expect(FocusModeFile.isOn(home: home))
        #expect(!FileManager.default.fileExists(
            atPath: FocusModeFile.legacyFile(in: home).path))
        #expect(ControlFileToken(at: FocusModeFile.file(in: home)) == live)
    }

    @Test func adoptingWithNothingToAdoptLeavesTheStateAlone() throws {
        let home = try scratch()
        FocusModeFile.adoptLegacyName(home: home)
        #expect(!FocusModeFile.isOn(home: home))

        try FocusModeFile.turnOn(home: home)
        let token = try #require(ControlFileToken(at: FocusModeFile.file(in: home)))
        FocusModeFile.adoptLegacyName(home: home)
        #expect(ControlFileToken(at: FocusModeFile.file(in: home)) == token)
    }
}

/// `SHIFU_HOME` is the one override every process, test and perf harness uses
/// to stay off real data. Every case here goes through `ShifuHomeOverride`:
/// `.serialized` orders this suite's own cases, but swift-testing still runs
/// other suites alongside it, and `DigestGeneratorTests` moves the same
/// variable.
@Suite(.serialized) struct ShifuPathsTests {
    @Test func shifuHomeOverridesTheDefaultLocationAndEverythingHangsOffIt() {
        let scratch = "/tmp/shifu-paths-test-\(UUID().uuidString)"
        ShifuHomeOverride.with(scratch) {
            #expect(ShifuPaths.home.path == scratch)
            #expect(ShifuPaths.database.path == scratch + "/shifu.db")
            for path in [ShifuPaths.database, ShifuPaths.vault, ShifuPaths.digests,
                         ShifuPaths.logs, ShifuPaths.pauseFile, ShifuPaths.focusModeFile] {
                #expect(path.deletingLastPathComponent().path == scratch)
            }
        }
    }

    @Test func withoutTheOverrideHomeIsUnderTheUsersHomeDirectory() {
        ShifuHomeOverride.with(nil) {
            #expect(ShifuPaths.home.lastPathComponent == "Shifu")
            #expect(ShifuPaths.home.path.hasPrefix(
                FileManager.default.homeDirectoryForCurrentUser.path))
        }
    }

    /// `~/Shifu` holds a screen-capture trace; it is created owner-only (§8).
    @Test func theHomeDirectoryIsCreatedOwnerOnlyAndReCreationIsIdempotent() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("shifu-perm-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }

        try ShifuHomeOverride.with(scratch.path) {
            try ShifuPaths.ensureHomeExists()
            try ShifuPaths.ensureHomeExists()
            let attributes = try FileManager.default.attributesOfItem(atPath: scratch.path)
            #expect(attributes[.posixPermissions] as? Int == 0o700)
        }
    }
}
