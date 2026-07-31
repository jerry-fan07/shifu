import Foundation
import GRDB
import Testing
@testable import ShifuCore

/// A fixed Monday, so "weekday mornings" is a fact about the fixture and not
/// about the day the suite happens to run.
private enum Fixture {
    static let calendar = Calendar.current

    static var monday: Date {
        var date = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_760_000_000))
        while calendar.component(.weekday, from: date) != 2 {
            date = calendar.date(byAdding: .day, value: 1, to: date)!
        }
        return date
    }

    static func ms(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1_000) }
    static func day(_ offset: Int, hour: Double) -> Date {
        monday.addingTimeInterval(Double(offset) * 86_400 + hour * 3_600)
    }
}

/// The deterministic half of the radar (design.md §6.1): which tasks earn a
/// dossier, what the dossier carries, and — the regression that motivated the
/// rewrite — what never becomes a candidate at all.
@Suite struct PatternMinerTests {
    private let calendar = Fixture.calendar
    private var monday: Date { Fixture.monday }
    private func ms(_ date: Date) -> Int64 { Fixture.ms(date) }
    private func day(_ offset: Int, hour: Double) -> Date { Fixture.day(offset, hour: hour) }

    /// The mining window: the fixture week plus slack on both sides.
    private var window: (from: Int64, to: Int64) {
        (ms(monday) - 86_400_000, ms(monday) + 15 * 86_400_000)
    }

    @discardableResult
    private func insert(
        _ database: ShifuDatabase, start: Date, minutes: Double,
        app: String = "com.apple.Safari", domain: String? = nil, topic: String? = nil,
        category: ShifuCore.Category = .work, title: String? = nil, text: String? = nil
    ) throws -> Int64 {
        try database.queue.write { db in
            var activity = Activity(
                startedAt: ms(start), endedAt: ms(start) + Int64(minutes * 60_000),
                appBundle: app, domain: domain, category: category, topic: topic)
            try activity.insert(db)
            guard title != nil || text != nil else { return activity.id! }
            try db.execute(sql: """
                INSERT INTO observations
                    (started_at, last_seen, app_bundle, window_title, capture_kind, text, session_id)
                VALUES (?, ?, ?, ?, 'ax', ?, ?)
                """, arguments: [ms(start), ms(start), app, title, text, activity.id])
            return activity.id!
        }
    }

    private func group(_ database: ShifuDatabase) throws {
        try TaskGrouper.run(database: database, from: window.from, to: window.to,
                            calendar: calendar)
    }

    private func mine(_ database: ShifuDatabase) throws -> [PatternMiner.Candidate] {
        try PatternMiner.mine(database: database, from: window.from, to: window.to,
                              calendar: calendar)
    }

    // MARK: - Tasks

    @Test func recurringTaskBecomesCandidateWithScheduleAndSources() throws {
        let database = try ShifuDatabase.inMemory()
        for offset in 0..<5 {                       // Mon–Fri, 9:30
            let start = day(offset, hour: 9.5)
            try insert(database, start: start, minutes: 25, domain: "stripe.com",
                       topic: "reconciling invoices", title: "Payouts – Stripe",
                       text: "payout 4,120.00 settled")
            try insert(database, start: start.addingTimeInterval(1_800), minutes: 15,
                       domain: "docs.google.com", topic: "reconciling invoices",
                       title: "Q3 invoices – Google Sheets")
        }
        try group(database)

        let candidates = try mine(database)
        #expect(candidates.count == 1)
        let candidate = try #require(candidates.first)
        #expect(candidate.key == "task:topic:reconciling-invoices")
        #expect(candidate.kind == .task)
        #expect(candidate.name == "reconciling invoices")
        // Recurrence is days, not blocks: that is what a dismissal remembers.
        #expect(candidate.daysActive == 5)
        #expect(candidate.occurrences == 5)
        #expect(candidate.totalMinutes == 200)
        #expect(candidate.weeklyMinutes == 100)
        #expect(candidate.schedule.hasPrefix("weekday mornings"))
        #expect(candidate.sources.map(\.label) == ["stripe.com", "docs.google.com"])
        #expect(candidate.sources[0].minutes == 125)
        // The context §6.2 always specified and never had.
        #expect(candidate.titles.contains("Payouts – Stripe"))
        #expect(candidate.textSample.contains("payout"))
        #expect(candidate.logSummaries.count == PatternMiner.logSummaryLimit)
        #expect(candidate.evidenceLine.contains("3.3h over 5 days"))
        #expect(candidate.evidenceLine.contains("stripe.com"))
    }

    @Test func oneOffAndThinTasksNeverBecomeCandidates() throws {
        let database = try ShifuDatabase.inMemory()
        // Substantial, but a single day: nothing recurs, so nothing pays back.
        try insert(database, start: day(0, hour: 13), minutes: 180,
                   app: "com.apple.dt.Xcode", topic: "porting the parser")
        // Recurring, but three minutes a day.
        for offset in 0..<5 {
            try insert(database, start: day(offset, hour: 8), minutes: 3,
                       domain: "weather.com", topic: "checking the weather")
        }
        // Two days is under the recurrence bar on its own…
        for offset in 0..<2 {
            try insert(database, start: day(offset, hour: 16), minutes: 20,
                       app: "com.apple.dt.Xcode", topic: "chasing a flaky test")
        }
        try group(database)
        #expect(try mine(database).isEmpty)

        // …until there are real hours behind it, which is the second door in
        // (`substantialMinutes`) — the only one a week-old `sem:` task can use.
        for offset in 0..<2 {
            try insert(database, start: day(offset, hour: 17), minutes: 40,
                       app: "com.apple.dt.Xcode", topic: "chasing a flaky test")
        }
        try group(database)
        #expect(try mine(database).map(\.key) == ["task:topic:chasing-a-flaky-test"])
    }

    @Test func theTwoDoorsIntoADossier() {
        #expect(PatternMiner.qualifies(daysActive: 3, totalMinutes: 20))
        #expect(!PatternMiner.qualifies(daysActive: 3, totalMinutes: 19))
        #expect(!PatternMiner.qualifies(daysActive: 2, totalMinutes: 59))
        #expect(PatternMiner.qualifies(daysActive: 2, totalMinutes: 60))
        #expect(!PatternMiner.qualifies(daysActive: 1, totalMinutes: 600))
    }

    /// The dogfood screenshot, as a regression: everything that used to fill
    /// this tab, mined together, must yield nothing at all.
    @Test func containersLeisureAndSystemNoiseNeverBecomeCandidates() throws {
        let database = try ShifuDatabase.inMemory()
        // 1. Leisure that recurs daily and is substantial — still not work.
        for offset in 0..<5 {
            try insert(database, start: day(offset, hour: 21), minutes: 45,
                       domain: "reddit.com", topic: "browsing reddit",
                       category: .entertainment, title: "r/all")
        }
        // 2. The screenshot's top suggestion: google.com, hundreds of short
        //    visits. Substantial in aggregate, meaningless as a workflow.
        for offset in 0..<12 {
            for visit in 0..<12 {
                try insert(database, start: day(offset, hour: 9 + Double(visit) / 3),
                           minutes: 0.5, domain: "google.com")
            }
        }
        // 3. Containers: the two heaviest tasks in the real ledger are a
        //    terminal and a code host, and neither names any work.
        for offset in 0..<13 {
            try insert(database, start: day(offset, hour: 11), minutes: 90,
                       app: "com.mitchellh.ghostty", title: "~/code")
            try insert(database, start: day(offset, hour: 15), minutes: 40,
                       domain: "github.com", title: "shifu · pull requests")
        }
        // 4. Browser chrome arriving as a domain — the one kind of system
        //    noise that still reaches a dossier, since it comes in as a
        //    domain on a real browser rather than as a shell's own bundle.
        for offset in 0..<14 {
            for visit in 0..<12 {
                try insert(database, start: day(offset, hour: 9 + Double(visit) / 2),
                           minutes: 0.4, domain: "omnibox-popup.top-chrome")
            }
        }
        try group(database)

        #expect(try mine(database).isEmpty)
    }

    // The dossier used to carry its own system-shell clause, and this suite
    // hand-built an `app:com.apple.loginwindow` task to prove it — a real
    // dogfood row, minted before the grouper barred the bundle and accruing
    // time daily since. That state is unreachable now: `LedgerBuilder` writes
    // no shell block, and `v26-system-shell-purge` deleted the rows and the
    // tasks they had minted.

    @Test func alternationBecomesATaskSignalNotItsOwnSuggestion() throws {
        let database = try ShifuDatabase.inMemory()
        for offset in 0..<5 {                       // one copying bout a day
            for step in 0..<8 {
                let safari = step % 2 == 0
                try insert(database, start: day(offset, hour: 14).addingTimeInterval(Double(step) * 90),
                           minutes: 1,
                           app: safari ? "com.apple.Safari" : "com.apple.Terminal",
                           domain: safari ? "docs.google.com" : nil,
                           topic: "moving numbers into the sheet")
            }
        }
        try group(database)

        let candidates = try mine(database)
        #expect(candidates.count == 1)
        let candidate = try #require(candidates.first)
        #expect(candidate.kind == .task)
        let signal = try #require(candidate.signals.first)
        #expect(signal.contains("Terminal ↔ docs.google.com"))
        #expect(signal.contains("5 bouts"))
    }

    // MARK: - Polling

    @Test func pollingCandidateExcludesSearchDomains() throws {
        let database = try ShifuDatabase.inMemory()
        for offset in 0..<14 {
            for visit in 0..<12 {
                let start = day(offset, hour: 9 + Double(visit) / 2)
                try insert(database, start: start, minutes: 0.5,
                           domain: "grafana.example.com", title: "Grafana – API latency")
                try insert(database, start: start.addingTimeInterval(60), minutes: 0.5,
                           domain: "duckduckgo.com")
            }
        }
        try group(database)

        let candidates = try mine(database)
        #expect(candidates.count == 1)
        let candidate = try #require(candidates.first)
        #expect(candidate.key == "freq:grafana.example.com")
        #expect(candidate.kind == .polling)
        #expect(candidate.occurrences == 168)
        #expect(candidate.daysActive == 14)
        // The glances themselves are the evidence, not a source list.
        #expect(candidate.evidenceLine.hasPrefix("168 visits over 14 days, avg 0.5 min"))
        // The signal adds the rate and the reading, not the counts again.
        #expect(try #require(candidate.signals.first)
            .contains("~12 visits on each of those days, every one of them a glance"))
        #expect(candidate.titles.contains("Grafana – API latency"))
    }

    @Test func aPollingDomainDeepInsideATaskIsStillNotAnAlertingGap() throws {
        let database = try ShifuDatabase.inMemory()
        // The dashboard is only this task's *fourth* source, behind three
        // heavier ones — the case a top-3 source list would miss.
        for offset in 0..<14 {
            for (index, domain) in ["github.com", "datadog.com", "sentry.io"].enumerated() {
                try insert(database, start: day(offset, hour: 10 + Double(index)), minutes: 20,
                           domain: domain, topic: "watching the rollout")
            }
            for visit in 0..<12 {
                try insert(database, start: day(offset, hour: 9 + Double(visit) / 2),
                           minutes: 0.5, domain: "grafana.example.com",
                           topic: "watching the rollout")
            }
        }
        try group(database)

        #expect(try mine(database).map(\.key) == ["task:topic:watching-the-rollout"])
    }

    @Test func privateBlocksNeverReachADossier() throws {
        let database = try ShifuDatabase.inMemory()
        for offset in 0..<5 {
            try insert(database, start: day(offset, hour: 9.5), minutes: 30,
                       domain: "stripe.com", topic: "reconciling invoices",
                       title: "Payouts – Stripe", text: "payout settled")
            // Private time is counted opaquely and never inspected (§8). These
            // blocks predate the rule that keeps them out of a task, so they
            // carry a task_id — the dossier must still not read them.
            try insert(database, start: day(offset, hour: 10.5), minutes: 30,
                       domain: "chase.com", category: .privateTime,
                       title: "Chase – account summary", text: "balance 12,004.11")
        }
        try group(database)
        try database.queue.write { db in
            try db.execute(sql: """
                UPDATE activities SET task_id = (SELECT id FROM tasks LIMIT 1)
                WHERE category = 'private'
                """)
        }

        let candidate = try #require(try mine(database).first)
        #expect(candidate.sources.map(\.label) == ["stripe.com"])
        #expect(candidate.totalMinutes == 150)
        #expect(!candidate.titles.contains { $0.contains("Chase") })
        #expect(!candidate.textSample.contains("12,004.11"))
    }

    @Test func aDomainInsideARealTaskIsNotAnAlertingGap() throws {
        let database = try ShifuDatabase.inMemory()
        // Same glance pattern, but every visit belongs to named work: the
        // suggestion should be about the work, not about the domain.
        for offset in 0..<14 {
            for visit in 0..<12 {
                try insert(database, start: day(offset, hour: 9 + Double(visit) / 2),
                           minutes: 0.5, domain: "grafana.example.com",
                           topic: "watching the rollout")
            }
        }
        try group(database)

        let candidates = try mine(database)
        #expect(candidates.map(\.key) == ["task:topic:watching-the-rollout"])
    }
}

/// The miner's pure stats, over rows rather than a database.
@Suite struct PatternMinerStatsTests {
    private let calendar = Fixture.calendar
    private func ms(_ date: Date) -> Int64 { Fixture.ms(date) }
    private func day(_ offset: Int, hour: Double) -> Date { Fixture.day(offset, hour: hour) }

    @Test func scheduleLineNamesTheShapeOnlyWhenThereIsOne() {
        let mornings = [9.25, 10.0, 9.5, 11.0, 10.5].enumerated().map { offset, hour in
            ms(day(offset, hour: hour))
        }
        #expect(PatternMiner.scheduleLine(starts: mornings, calendar: calendar)
            == "weekday mornings, usually 9–10")

        let scattered = [8.0, 13.0, 19.0, 22.0, 3.0].enumerated().map { offset, hour in
            ms(day(offset, hour: hour))
        }
        #expect(PatternMiner.scheduleLine(starts: scattered, calendar: calendar)
            == "weekdays, spread across the day")

        let saturdays = (0..<3).map { ms(day(5 + $0 * 7, hour: 20.0)) }
        #expect(PatternMiner.scheduleLine(starts: saturdays, calendar: calendar)
            == "weekend evenings, usually around 20:00")

        // The late-night bucket wraps midnight: 23:30 and 00:30 are one shape,
        // not a range from 0 to 23.
        let lateNights = (0..<6).map { index in
            ms(day(index / 2, hour: index.isMultiple(of: 2) ? 23.5 : 24.5))
        }
        #expect(PatternMiner.scheduleLine(starts: lateNights, calendar: calendar)
            == "weekday late nights, usually 23–0")

        #expect(PatternMiner.scheduleLine(starts: [], calendar: calendar) == "no regular time")
    }

    @Test func aSettledBlockEndsABoutRatherThanCancellingIt() {
        func block(_ start: Int64, _ seconds: Int64, _ label: String) -> PatternMiner.Block {
            PatternMiner.Block(startedAt: start * 1_000, durationMs: seconds * 1_000,
                               label: label, category: .work)
        }
        // Four quick hops, then the user settles into a long stretch. The run
        // extension used to absorb the long block and veto the whole bout.
        var blocks: [PatternMiner.Block] = []
        var clock: Int64 = 0
        for bout in 0..<3 {
            for step in 0..<4 {
                blocks.append(block(clock, 30, step.isMultiple(of: 2) ? "sheet" : "Terminal"))
                clock += 40
            }
            blocks.append(block(clock, 600, "Terminal"))
            clock += 700 + Int64(bout) * 86_400
        }
        let signal = try? #require(PatternMiner.alternationSignal(blocks))
        #expect(signal?.contains("3 bouts") == true)
        #expect(signal?.contains("Terminal ↔ sheet") == true)
    }

    @Test func dominantCategoryIsTimeWeightedNotBlockCounted() {
        func block(_ minutes: Int64, _ category: ShifuCore.Category) -> PatternMiner.Block {
            PatternMiner.Block(startedAt: 0, durationMs: minutes * 60_000,
                               label: "x", category: category)
        }
        let blocks = [block(90, .work)] + Array(repeating: block(2, .social), count: 8)
        #expect(PatternMiner.dominantCategory(blocks) == .work)
        #expect(!PatternMiner.isLeisure(.work))
        #expect(PatternMiner.isLeisure(.entertainment))
        #expect(PatternMiner.dominantCategory([]) == nil)
    }

    @Test func searchDomainsCoverEveryGoogleTLD() {
        #expect(PatternMiner.isSearchDomain("google.com"))
        #expect(PatternMiner.isSearchDomain("google.co.uk"))
        #expect(PatternMiner.isSearchDomain("duckduckgo.com"))
        #expect(!PatternMiner.isSearchDomain("mail.google.com"))
        #expect(!PatternMiner.isSearchDomain("grafana.example.com"))
    }

    @Test func onlyKeysThatNameIntentAndRealSitesQualify() {
        #expect(PatternMiner.namesIntent(taskKey: "sem:booking-flights-for-the-sf-trip"))
        #expect(PatternMiner.namesIntent(taskKey: "topic:debugging-capture-daemon"))
        #expect(!PatternMiner.namesIntent(taskKey: "app:com.mitchellh.ghostty"))
        #expect(!PatternMiner.namesIntent(taskKey: "domain:github.com"))

        #expect(PatternMiner.isRealSite("grafana.example.com"))
        #expect(!PatternMiner.isRealSite("omnibox-popup.top-chrome"))
        #expect(!PatternMiner.isRealSite("new-tab-page"))
        #expect(!PatternMiner.isRealSite("contextual-tasks"))
    }
}
