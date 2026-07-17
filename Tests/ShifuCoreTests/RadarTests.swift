import Foundation
import GRDB
import Testing
@testable import ShifuCore

private func act(_ start: Int64, _ durationMs: Int64, bundle: String = "com.apple.Safari",
                 domain: String? = nil) -> Activity {
    Activity(startedAt: start, endedAt: start + durationMs, appBundle: bundle,
             domain: domain, category: .work)
}

@Suite struct PatternMinerTests {
    @Test func findsRecurringNgram() {
        // gmail → sheets → github ritual, 6 times over the window.
        var activities: [Activity] = []
        var time: Int64 = 0
        for _ in 0..<6 {
            activities.append(act(time, 120_000, domain: "gmail.com")); time += 200_000
            activities.append(act(time, 240_000, domain: "docs.google.com")); time += 300_000
            activities.append(act(time, 120_000, domain: "github.com")); time += 86_400_000
        }
        let patterns = PatternMiner.mine(activities)
        let ngram = patterns.first { $0.kind == "ngram" }
        #expect(ngram != nil)
        #expect(ngram!.key.contains("gmail.com → docs.google.com → github.com"))
        #expect(ngram!.occurrences == 6)
    }

    @Test func findsFrequentShortVisits() {
        // A dashboard checked ~12×/day for 30 s over 14 days.
        var activities: [Activity] = []
        var time: Int64 = 0
        for _ in 0..<(12 * 14) {
            activities.append(act(time, 30_000, domain: "grafana.example.com"))
            time += 7_000_000
        }
        let patterns = PatternMiner.mine(activities)
        let freq = patterns.first { $0.kind == "frequent_visit" }
        #expect(freq != nil)
        #expect(freq!.key == "freq:grafana.example.com")
        #expect(freq!.estMinutesSavedWeekly > 30)
    }

    @Test func findsAlternationRuns() {
        // 4 bouts of rapid sheets↔terminal copying, 6 blocks each.
        var activities: [Activity] = []
        var time: Int64 = 0
        for _ in 0..<4 {
            for index in 0..<6 {
                let domain = index % 2 == 0 ? "docs.google.com" : nil
                let bundle = index % 2 == 0 ? "com.apple.Safari" : "com.apple.Terminal"
                activities.append(act(time, 45_000, bundle: bundle, domain: domain))
                time += 50_000
            }
            activities.append(act(time, 600_000, bundle: "com.apple.dt.Xcode"))
            time += 700_000
        }
        let patterns = PatternMiner.mine(activities)
        let alt = patterns.first { $0.kind == "alternation" }
        #expect(alt != nil)
        #expect(alt!.key == "alt:Terminal ↔ docs.google.com")
        #expect(alt!.occurrences == 4)
    }

    @Test func quietDayYieldsNothing() {
        let activities = [
            act(0, 3_600_000, bundle: "com.apple.dt.Xcode"),
            act(4_000_000, 1_800_000, domain: "github.com")
        ]
        #expect(PatternMiner.mine(activities).isEmpty)
    }
}

@Suite struct RadarTests {
    private func pattern(_ key: String, occurrences: Int = 6) -> PatternMiner.Pattern {
        .init(key: key, kind: "ngram", evidence: "seen \(occurrences)×",
              occurrences: occurrences, avgMinutes: 3, estMinutesSavedWeekly: 12)
    }

    @Test func upsertInsertsThenUpdates() throws {
        let db = try ShifuDatabase.inMemory()
        #expect(try Radar.upsert(patterns: [pattern("ngram:a")], database: db) == 1)
        #expect(try Radar.upsert(patterns: [pattern("ngram:a", occurrences: 8)], database: db) == 0)
        let all = try Radar.active(database: db)
        #expect(all.count == 1)
        #expect(all[0].occurrences == 8)
    }

    @Test func dismissedStaysDismissedUntilFrequencyDoubles() throws {
        let db = try ShifuDatabase.inMemory()
        try Radar.upsert(patterns: [pattern("ngram:a", occurrences: 6)], database: db)
        try Radar.dismiss(try Radar.active(database: db)[0], database: db)
        #expect(try Radar.active(database: db).isEmpty)

        // 11× is < 2×6 → stays dismissed.
        try Radar.upsert(patterns: [pattern("ngram:a", occurrences: 11)], database: db)
        #expect(try Radar.active(database: db).isEmpty)

        // 12× doubles the dismissal frequency → resurfaces (§6.2).
        try Radar.upsert(patterns: [pattern("ngram:a", occurrences: 12)], database: db)
        #expect(try Radar.active(database: db).count == 1)
    }

    @Test func snoozeExpires() throws {
        let db = try ShifuDatabase.inMemory()
        let now = Date()
        try Radar.upsert(patterns: [pattern("ngram:a")], database: db, now: now)
        try Radar.snooze(try Radar.active(database: db)[0], days: 30, database: db, now: now)
        #expect(try Radar.active(database: db).isEmpty)

        // Re-mine before expiry: still snoozed. After expiry: back.
        try Radar.upsert(patterns: [pattern("ngram:a")], database: db,
                         now: now.addingTimeInterval(10 * 86_400))
        #expect(try Radar.active(database: db).isEmpty)
        try Radar.upsert(patterns: [pattern("ngram:a")], database: db,
                         now: now.addingTimeInterval(31 * 86_400))
        #expect(try Radar.active(database: db).count == 1)
    }

    @Test func describerParsesAndUpdates() async throws {
        struct Mock: LLMBackend {
            let name = "mock"
            func complete(prompt: String, maxTokens: Int) async throws -> String {
                #"[{"id": 1, "title": "Morning ritual (~12 min/week)", "suggestion": "Script it.", "confidence": 0.7}]"#
            }
        }
        let db = try ShifuDatabase.inMemory()
        try Radar.upsert(patterns: [pattern("ngram:a")], database: db)
        let updated = try await Radar.describe(database: db, backend: Mock())
        #expect(updated == 1)
        let all = try Radar.active(database: db)
        #expect(all[0].title == "Morning ritual (~12 min/week)")
        #expect(all[0].confidence == 0.7)
        #expect(all[0].automationPrompt.contains("Morning ritual"))
    }
}
