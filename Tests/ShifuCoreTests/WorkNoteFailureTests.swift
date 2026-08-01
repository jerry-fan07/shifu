import Foundation
import Testing
@testable import ShifuCore

/// What a day note does when its prose never arrives.
///
/// That path had no coverage at all, and it ran for three days deleting the
/// prose of the densest days in the dogfood vault while `run`'s `try?` kept
/// it quiet: the note was written with the *new* content hash before the
/// narrative was attempted, so a failed call left the day stamped as
/// described with no prose — and a completed day's evidence never changes
/// again, so it could never be retried.
///
/// Fixtures come from `WorkNoteCompilerTests`; these live in their own file
/// only because that one is at the lint's file-length cap.

/// Plays a script of outcomes in order, repeating the last one once the
/// script runs out — so a test can assert "and then it settles" without
/// padding the script with copies.
private final class ScriptedBackend: LLMBackend, @unchecked Sendable {
    let name = "scripted"
    private let lock = NSLock()
    private var script: [Result<String, LLMError>]
    private var last: Result<String, LLMError>
    private var callCount = 0

    init(_ script: [Result<String, LLMError>]) {
        self.script = script
        self.last = script.last ?? .success("")
    }

    var calls: Int { lock.withLock { callCount } }

    func complete(prompt: String, maxTokens: Int) async throws -> String {
        let outcome: Result<String, LLMError> = lock.withLock {
            callCount += 1
            guard !script.isEmpty else { return last }
            last = script.removeFirst()
            return last
        }
        return try outcome.get()
    }
}

private let goodProse = "- **09:00–10:00** — chased the observer leak; landed the fix"

extension WorkNoteCompilerTests {
    private var taskKey: String { "topic:debugging-capture-daemon" }

    @Test func aFailedNarrativeKeepsTheProseItAlreadyHadAndTriesAgain() async throws {
        let database = try ShifuDatabase.inMemory()
        let vault = try makeVault(database)
        let better = "- **09:00–16:20** — chased the leak, then ran the perf harness"
        let backend = ScriptedBackend([
            .success(goodProse), .failure(.badResponse("upstream said no")), .success(better)
        ])
        let dayStr = WorkNoteCompiler.dayString(ms(day1), calendar: calendar)

        try insertActivity(database, start: day1.addingTimeInterval(9 * 3_600), minutes: 90,
                           sampleText: "AX observer teardown in pause()")
        var summary = try await compile(database, vault, backend: backend, from: day1, to: day2)
        #expect(summary.narrativesGenerated == 1)
        let first = try #require(vault.workNote(day: dayStr, taskKey: taskKey))
        #expect(first.sessionsProse == goodProse)

        // The day grows, so prose is owed again — and this time the call fails.
        try insertActivity(database, start: day1.addingTimeInterval(16 * 3_600), minutes: 20,
                           sampleText: "perf harness output")
        summary = try await compile(database, vault, backend: backend, from: day1, to: day2)
        #expect(summary.narrativesGenerated == 0)
        #expect(summary.narrativesFailed == 1)

        let afterFailure = try #require(vault.workNote(day: dayStr, taskKey: taskKey))
        // The last good pass's prose survives…
        #expect(afterFailure.sessionsProse == goodProse)
        // …the deterministic half still tracks the day…
        #expect(afterFailure.sessions.count == 2)
        // …and the hash never moved ahead of the prose, so the day is still owed.
        #expect(afterFailure.contentHash == first.contentHash)

        summary = try await compile(database, vault, backend: backend, from: day1, to: day2)
        #expect(summary.narrativesGenerated == 1)
        let healed = try #require(vault.workNote(day: dayStr, taskKey: taskKey))
        #expect(healed.sessionsProse == better)
        #expect(healed.contentHash != first.contentHash)
    }

    /// A day that outgrows its answer reserve keeps the bullets it did write.
    @Test func aTruncatedNarrativeKeepsItsWholeBulletsRatherThanNothing() async throws {
        let database = try ShifuDatabase.inMemory()
        let vault = try makeVault(database)
        let backend = ScriptedBackend([.failure(.truncated(
            partial: "- **09:00–10:00** — chased the observer leak\n- **10:00–10:30** — ran the per",
            detail: "hit max_tokens=2500"))])
        try insertActivity(database, start: day1.addingTimeInterval(9 * 3_600), minutes: 90,
                           sampleText: "AX observer teardown in pause()")

        let summary = try await compile(database, vault, backend: backend, from: day1, to: day2)
        #expect(summary.narrativesGenerated == 1)
        #expect(summary.narrativesFailed == 0)

        let note = try #require(vault.workNote(
            day: WorkNoteCompiler.dayString(ms(day1), calendar: calendar), taskKey: taskKey))
        #expect(note.sessionsProse == "- **09:00–10:00** — chased the observer leak")
    }

    /// The same erasure by another route: compiling with the LLM turned off
    /// used to write the new hash and null prose, so one backend-less run
    /// wiped every note it touched and marked the days done.
    @Test func compilingWithNoBackendLeavesExistingProseAlone() async throws {
        let database = try ShifuDatabase.inMemory()
        let vault = try makeVault(database)
        let backend = ScriptedBackend([.success(goodProse)])
        let dayStr = WorkNoteCompiler.dayString(ms(day1), calendar: calendar)

        try insertActivity(database, start: day1.addingTimeInterval(9 * 3_600), minutes: 90,
                           sampleText: "AX observer teardown in pause()")
        _ = try await compile(database, vault, backend: backend, from: day1, to: day2)
        let withProse = try #require(vault.workNote(day: dayStr, taskKey: taskKey))
        #expect(withProse.sessionsProse == goodProse)

        try insertActivity(database, start: day1.addingTimeInterval(16 * 3_600), minutes: 20,
                           sampleText: "perf harness output")
        _ = try await compile(database, vault, backend: nil, from: day1, to: day2)

        let keyless = try #require(vault.workNote(day: dayStr, taskKey: taskKey))
        #expect(keyless.sessionsProse == withProse.sessionsProse)
        #expect(keyless.contentHash == withProse.contentHash)

        // And the day is still owed, so turning the backend back on pays once.
        _ = try await compile(database, vault, backend: backend, from: day1, to: day2)
        #expect(backend.calls == 2)
    }

    /// Recovery for the days the erasure already blanked. Their hash says
    /// described and their body has no prose, and a completed day's evidence
    /// never changes again — so without this they stay empty forever.
    @Test func aBlankedNoteIsReopenedEvenThoughItsHashSaysDescribed() async throws {
        let database = try ShifuDatabase.inMemory()
        let vault = try makeVault(database)
        let backend = ScriptedBackend([.success(goodProse)])
        let dayStr = WorkNoteCompiler.dayString(ms(day1), calendar: calendar)

        try insertActivity(database, start: day1.addingTimeInterval(9 * 3_600), minutes: 90,
                           sampleText: "AX observer teardown in pause()")
        _ = try await compile(database, vault, backend: backend, from: day1, to: day2)
        #expect(backend.calls == 1)

        // Exactly what the bug left behind: the day's own hash, no prose.
        var blanked = try #require(vault.workNote(day: dayStr, taskKey: taskKey))
        blanked.sessionsProse = nil
        blanked.detailProse = nil
        try vault.saveWork(blanked)

        _ = try await compile(database, vault, backend: backend, from: day1, to: day2)
        #expect(backend.calls == 2)
        let healed = try #require(vault.workNote(day: dayStr, taskKey: taskKey))
        #expect(healed.sessionsProse == goodProse)

        // And it settles: a described day is unchanged again, so no third call.
        _ = try await compile(database, vault, backend: backend, from: day1, to: day2)
        #expect(backend.calls == 2)
    }

    /// The heal must not reopen days that were never owed prose — a
    /// six-minute glance has no narrative by design, not by failure.
    @Test func anInsubstantialDayStaysUnchangedWithoutProse() async throws {
        let database = try ShifuDatabase.inMemory()
        let vault = try makeVault(database)
        let backend = ScriptedBackend([.success(goodProse)])
        try insertActivity(database, start: day1.addingTimeInterval(9 * 3_600), minutes: 6,
                           sampleText: "dashboard glance")

        _ = try await compile(database, vault, backend: backend, from: day1, to: day2)
        #expect(backend.calls == 0)
        _ = try await compile(database, vault, backend: backend, from: day1, to: day2)
        #expect(backend.calls == 0)
    }
}
