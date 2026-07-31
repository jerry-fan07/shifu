import Foundation
import ShifuCore
import Testing
@testable import ShifuApp

/// The Settings page's right-hand column is the one place in the app that
/// claims to say whether capture is *working*. A wrong number there is worse
/// than no number, so the split it reports is pinned here.
@Suite struct SettingsDiagnosticsTests {
    /// A day boundary well clear of any real clock, so "today" in these tests
    /// is unambiguous.
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private var todayStart: Int64 {
        Int64(Calendar.current.startOfDay(for: now).timeIntervalSince1970 * 1_000)
    }

    /// Seeded through the daemon's own write path rather than raw SQL: what
    /// the column counts has to be what actually lands, dedupe and all.
    private func record(
        _ database: ShifuDatabase, kind: CaptureKind, title: String, at offsetMs: Int64
    ) throws {
        try ObservationRecorder(database: database).record(
            .init(
                timestamp: todayStart + offsetMs, appBundle: "com.example.app",
                windowTitle: title, captureKind: kind,
                text: kind == .ax || kind == .ocr ? title : nil))
    }

    @Test func splitsTodaysCapturesByRung() throws {
        let database = try ShifuDatabase.inMemory()
        try record(database, kind: .ax, title: "one", at: 1_000)
        try record(database, kind: .ax, title: "two", at: 2_000)
        try record(database, kind: .ocr, title: "three", at: 3_000)
        try record(database, kind: .meta, title: "four", at: 4_000)
        try record(database, kind: .excluded, title: "five", at: 5_000)

        let diagnostics = SettingsDiagnostics.read(
            database: database, file: URL(fileURLWithPath: "/nonexistent"), now: now)
        #expect(diagnostics.text == 2)
        #expect(diagnostics.ocr == 1)
        #expect(diagnostics.metadata == 1)
        #expect(diagnostics.excluded == 1)
        #expect(diagnostics.captureTotal == 5)
    }

    /// Yesterday's work is not today's evidence: the column is answering "is
    /// it working *now*", and a total that included last week would answer yes
    /// forever after the daemon died.
    @Test func countsOnlyToday() throws {
        let database = try ShifuDatabase.inMemory()
        try record(database, kind: .ax, title: "today", at: 60_000)
        try record(database, kind: .ax, title: "yesterday", at: -3_600_000)

        let diagnostics = SettingsDiagnostics.read(
            database: database, file: URL(fileURLWithPath: "/nonexistent"), now: now)
        #expect(diagnostics.text == 1)
    }

    /// The blank state is the product's central claim rendered as a
    /// measurement, so it must be reachable: a fresh install reports nothing
    /// sent, not a zero-dollar spend.
    @Test func nothingSentReadsAsNothing() throws {
        let database = try ShifuDatabase.inMemory()
        let diagnostics = SettingsDiagnostics.read(
            database: database, file: URL(fileURLWithPath: "/nonexistent"), now: now)
        #expect(diagnostics.llmCalls == 0)
        #expect(diagnostics.llmCostLabel == nil)
        #expect(diagnostics.captureTotal == 0)
    }

    @Test func reportsCallsTokensAndSpend() throws {
        let database = try ShifuDatabase.inMemory()
        LLMUsage.record(
            .init(
                model: "deepseek-v4-flash", promptTokens: 900_000,
                cachedPromptTokens: 0, completionTokens: 100_000),
            at: todayStart + 1_000, database: database)

        let diagnostics = SettingsDiagnostics.read(
            database: database, file: URL(fileURLWithPath: "/nonexistent"), now: now)
        #expect(diagnostics.llmCalls == 1)
        #expect(diagnostics.llmTokensLabel == "1.0M")
        // 0.9M in at $0.14/M + 0.1M out at $0.28/M = $0.154.
        #expect(diagnostics.llmCostLabel == "≈ $0.154")
    }

    /// A missing database file leaves a dash rather than "0.0 MB" — the two
    /// mean opposite things on a page about whether anything is being stored.
    @Test func missingDatabaseFileReadsAsUnknown() throws {
        let database = try ShifuDatabase.inMemory()
        let diagnostics = SettingsDiagnostics.read(
            database: database, file: URL(fileURLWithPath: "/nonexistent"), now: now)
        #expect(diagnostics.databaseBytes == nil)
        #expect(diagnostics.databaseSizeLabel == "—")
        #expect(!diagnostics.databaseEncrypted)
    }

    @Test func sizeLabelKeepsOneDecimalOnlyWhileItMatters() {
        var small = SettingsDiagnostics()
        small.databaseBytes = Int64(3.4 * 1_048_576)
        #expect(small.databaseSizeLabel == "3.4 MB")

        var large = SettingsDiagnostics()
        large.databaseBytes = Int64(128.4 * 1_048_576)
        #expect(large.databaseSizeLabel == "128 MB")
    }
}
