import Foundation
import GRDB
import Testing
@testable import ShifuCore

/// The shapes both Load suites build from: a fixed noon "now", blocks placed
/// a day into a rolling week so they never straddle a boundary, a habit worked
/// every week, and a deadline standing.
struct WorkloadFixture {
    let hour: Int64 = 3_600_000
    let day: Int64 = 86_400_000
    let week: Int64 = 7 * 86_400_000
    /// A fixed "now" far from any epoch edge, at noon so day arithmetic in the
    /// deadline tests is unambiguous whatever the machine's zone.
    let now: Int64 = 1_700_000_000_000 + 12 * 3_600_000

    func block(
        _ category: String, task: Int64? = 1, name: String? = nil,
        weeksAgo: Int, hours: Double, theme: (Int64, String)? = nil
    ) -> Workload.Block {
        // Placed one day into the week so it never straddles a boundary.
        let end = now - Int64(weeksAgo) * week - day
        let ms = Int64(hours * Double(hour))
        return Workload.Block(
            startedAt: end - ms, endedAt: end, category: category,
            taskID: task, taskName: name ?? task.map { "task \($0)" },
            themeID: theme?.0, themeName: theme?.1)
    }

    /// A task worked every week for `weeks` weeks — the established habit
    /// most status tests start from.
    func habit(
        task: Int64, hours: Double, weeks: ClosedRange<Int>, category: String = "work"
    ) -> [Workload.Block] {
        weeks.map { block(category, task: task, weeksAgo: $0, hours: hours) }
    }

    func read(
        _ blocks: [Workload.Block], deadlines: [DeadlineHorizon.Standing] = [],
        unit: Workload.Unit = .task
    ) -> Workload.Reading {
        Workload.read(blocks: blocks, deadlines: deadlines, unit: unit, now: now)
    }

    func standing(
        id: Int64 = 1, task: Int64? = 1, dueInDays: Int, targetHours: Double? = nil,
        loggedHours: Double = 0, createdDaysAgo: Int = 30, done: Bool = false
    ) -> DeadlineHorizon.Standing {
        DeadlineHorizon.Standing(
            deadline: Deadline(
                id: id, title: "Draft", dueAt: now + Int64(dueInDays) * day, allDay: true,
                taskID: task, targetMs: targetHours.map { Int64($0 * Double(hour)) },
                createdAt: now - Int64(createdDaysAgo) * day,
                doneAt: done ? now : nil),
            loggedMs: Int64(loggedHours * Double(hour)), taskName: "task")
    }
}

/// The Load reading (design.md §4.6): what counts as a front, how a week is
/// bucketed, what each status and verdict needs before it will say so, and
/// how a deadline becomes a pace. Nearly every threshold here exists to make
/// the reading say nothing rather than something shaky, so most tests pin
/// the *refusal* as much as the claim.
@Suite struct WorkloadTests {
    private let fx = WorkloadFixture()

    // MARK: - What is a front

    @Test func theDominanceVoteIsAmongClassifiedCategoriesOnly() {
        // The real shape (task 2420 on 2026-10-02): more unclassified than
        // learning, nothing else. Neutral sits out the vote, so it is a front.
        let reading = fx.read([
            fx.block("unclassified", weeksAgo: 0, hours: 1.2),
            fx.block("learning", weeksAgo: 0, hours: 1.1)
        ])
        #expect(reading.fronts.map(\.taskID) == [1])
    }

    @Test func aSocialTaskIsNeverAFront() {
        let reading = fx.read([
            fx.block("social", weeksAgo: 0, hours: 5),
            fx.block("work", weeksAgo: 0, hours: 1)
        ])
        #expect(reading.fronts.isEmpty)
    }

    @Test func aTaskUnderTheFloorIsNotAFrontUnlessADeadlineRidesOnIt() {
        let blocks = [fx.block("work", weeksAgo: 0, hours: 0.5)]
        #expect(fx.read(blocks).fronts.isEmpty)
        let promised = fx.read(blocks, deadlines: [fx.standing(dueInDays: 10, targetHours: 4)])
        #expect(promised.fronts.count == 1)
        #expect(promised.fronts.first?.pace?.deadlineID == 1)
    }

    @Test func timeOlderThanFourWeeksDoesNotKeepAFrontAlive() {
        let reading = fx.read([fx.block("work", weeksAgo: 5, hours: 10)])
        #expect(reading.fronts.isEmpty)
        // …but it does count in the week's history.
        #expect(reading.tracked[5] == 10 * fx.hour)
    }

    // MARK: - Bucketing

    @Test func aBlockStraddlingAWeekBoundaryIsSplitAcrossBoth() {
        let boundary = fx.now - fx.week
        let reading = fx.read([
            Workload.Block(
                startedAt: boundary - fx.hour, endedAt: boundary + 2 * fx.hour,
                category: "work", taskID: 1, taskName: "t")
        ])
        #expect(reading.tracked[0] == 2 * fx.hour)
        #expect(reading.tracked[1] == fx.hour)
    }

    @Test func aBlockStillOpenCountsOnlyWhatItHasLived() {
        let reading = fx.read([
            Workload.Block(
                startedAt: fx.now - fx.hour, endedAt: fx.now + 3 * fx.hour,
                category: "work", taskID: 1, taskName: "t")
        ])
        #expect(reading.tracked[0] == fx.hour)
        #expect(reading.capacity[0] == fx.hour)
    }

    // MARK: - Capacity

    @Test func capacityIsTimeOnFocusedTasksWhateverTheBlockSaysPlusUnplacedFocusedBlocks() {
        let reading = fx.read([
            // A work task's unclassified OCR hour is still an hour of that task.
            fx.block("work", task: 1, weeksAgo: 0, hours: 2),
            fx.block("unclassified", task: 1, weeksAgo: 0, hours: 1),
            // A social task's time is tracked, not capacity.
            fx.block("social", task: 2, weeksAgo: 0, hours: 3),
            // Unplaced blocks vote for themselves.
            fx.block("learning", task: nil, weeksAgo: 0, hours: 1),
            fx.block("entertainment", task: nil, weeksAgo: 0, hours: 1)
        ])
        #expect(reading.capacity[0] == 4 * fx.hour)
        #expect(reading.tracked[0] == 8 * fx.hour)
    }

    // MARK: - Status

    @Test func aFrontFirstSeenThisFortnightIsNew() {
        let reading = fx.read([fx.block("work", weeksAgo: 0, hours: 2)])
        #expect(reading.fronts.first?.status == .new)
    }

    @Test func anUntouchedFortnightIsQuiet() {
        let reading = fx.read(fx.habit(task: 1, hours: 2, weeks: 2...4))
        #expect(reading.fronts.first?.status == .quiet)
        #expect(reading.quiet.map(\.taskID) == [1])
    }

    @Test func slippingNeedsAnEstablishedHabitWorthKeeping() {
        // Four hours a week for four weeks, then twenty minutes: slipping.
        let slipped = fx.habit(task: 1, hours: 4, weeks: 1...4)
            + [fx.block("work", weeksAgo: 0, hours: 0.33)]
        #expect(fx.read(slipped).fronts.first?.status == .slipping)

        // The same drop off a habit of fifteen minutes a week: not worth a word.
        let tiny = fx.habit(task: 1, hours: 0.25, weeks: 1...4)
            + [fx.block("work", weeksAgo: 0, hours: 0.01)]
            + [fx.block("work", weeksAgo: 5, hours: 0.5)]  // first seen long ago
        #expect(fx.read(tiny).fronts.first?.status != .slipping)

        // One big week three weeks back and a glance since isn't a habit
        // either — it is a front that has gone quiet.
        let spike = [fx.block("work", weeksAgo: 3, hours: 16), fx.block("work", weeksAgo: 2, hours: 0.2)]
        #expect(fx.read(spike).fronts.first?.status == .quiet)
    }

    @Test func risingAndSteadyReadAgainstTheFourWeekMean() {
        let rising = fx.habit(task: 1, hours: 2, weeks: 1...4) + [fx.block("work", weeksAgo: 0, hours: 3.5)]
        #expect(fx.read(rising).fronts.first?.status == .rising)
        let steady = fx.habit(task: 1, hours: 2, weeks: 0...4)
        #expect(fx.read(steady).fronts.first?.status == .steady)
    }

    // MARK: - The week

    @Test func theBaselineNeedsThreeOfTheLastFourWeeks() {
        let two = fx.habit(task: 1, hours: 5, weeks: 1...2)
        #expect(fx.read(two).baselineMs == nil)
        #expect(fx.read(two).verdict == .tooEarly)

        let four = fx.habit(task: 1, hours: 5, weeks: 1...4)
        #expect(fx.read(four).baselineMs == 5 * fx.hour)
    }

    @Test func theBaselineIsAMedianSoOneBigWeekDoesNotSetIt() {
        let blocks = [
            fx.block("work", weeksAgo: 1, hours: 4), fx.block("work", weeksAgo: 2, hours: 30),
            fx.block("work", weeksAgo: 3, hours: 5), fx.block("work", weeksAgo: 4, hours: 6)
        ]
        #expect(fx.read(blocks).baselineMs == Int64(5.5 * Double(fx.hour)))
    }

    @Test func effectiveFrontsIsTheEntropyFigure() {
        #expect(Workload.effectiveCount([]) == 0)
        #expect(Workload.effectiveCount([5, 0]) == 1)
        #expect(abs(Workload.effectiveCount([3, 3, 3, 3]) - 4) < 1e-9)
        // Twelve fronts at twenty minutes behind one at six hours is ~5.3, not 13.
        let lopsided = [Int64(6 * 60)] + Array(repeating: Int64(20), count: 12)
        #expect(Workload.effectiveCount(lopsided) > 5)
        #expect(Workload.effectiveCount(lopsided) < 6)
    }
}

/// The verdict, the deadline paces, the two lists, the theme lens, the copy
/// and the read — the half of the Load reading that sits over the fronts.
@Suite struct WorkloadVerdictTests {
    private let fx = WorkloadFixture()

    // MARK: - Verdicts

    @Test func slackNeedsTheScreenToHaveBeenJustAsBusy() {
        // Four weeks of five focused hours and three social hours, then a
        // week of one focused hour — with the social hours still there.
        var busy = fx.habit(task: 1, hours: 5, weeks: 1...4)
            + fx.habit(task: 2, hours: 3, weeks: 1...4, category: "social")
        busy += [fx.block("work", task: 1, weeksAgo: 0, hours: 1), fx.block("social", task: 2, weeksAgo: 0, hours: 6)]
        #expect(fx.read(busy).verdict == .slack)

        // The same focused drop with the social hours gone too: away, not slack.
        var gone = fx.habit(task: 1, hours: 5, weeks: 1...4)
            + fx.habit(task: 2, hours: 3, weeks: 1...4, category: "social")
        gone += [fx.block("work", task: 1, weeksAgo: 0, hours: 1)]
        #expect(fx.read(gone).verdict == .away)
    }

    @Test func overCommittedWhenDeadlinesNeedMoreThanTheFrontsHaveBeenGetting() {
        let blocks = fx.habit(task: 1, hours: 5, weeks: 0...4)
        // 40 h still owed in 10 days is 28 h/wk against a 5 h/wk habit.
        let reading = fx.read(blocks, deadlines: [fx.standing(dueInDays: 10, targetHours: 40)])
        #expect(reading.verdict == .overCommitted)
        #expect(reading.demandMsPerWeek == 28 * fx.hour)
        #expect(reading.giveTime.map(\.taskID) == [1])
    }

    @Test func spreadThinNeedsManyEffectiveFrontsAndSeveralSlipping() {
        // Eight fronts, even habits; two of them collapse this week. Six even
        // fronts behave like six, so the week is spread; and 12 of the 16 h
        // baseline is still 75%, so it isn't slack.
        var blocks: [Workload.Block] = []
        for task in Int64(1)...8 {
            blocks += fx.habit(task: task, hours: 2, weeks: 1...4)
            blocks.append(fx.block("work", task: task, weeksAgo: 0, hours: task <= 2 ? 0.1 : 2))
        }
        let reading = fx.read(blocks)
        #expect(reading.slipping.count == 2)
        #expect(reading.effectiveFronts > 5)
        #expect(reading.verdict == .spreadThin)

        // The same with one slipping: holding.
        var oneSlip: [Workload.Block] = []
        for task in Int64(1)...8 {
            oneSlip += fx.habit(task: task, hours: 2, weeks: 1...4)
            oneSlip.append(fx.block("work", task: task, weeksAgo: 0, hours: task == 1 ? 0.1 : 2))
        }
        #expect(fx.read(oneSlip).verdict == .holding)
    }

    @Test func aSteadyWeekHolds() {
        let reading = fx.read(fx.habit(task: 1, hours: 5, weeks: 0...4))
        #expect(reading.verdict == .holding)
        #expect(reading.giveTime.isEmpty)
        #expect(reading.quiet.isEmpty)
    }

    // MARK: - Deadlines as pace

    @Test func anOverduePromiseIsFlaggedNotDividedIntoInfinity() {
        let reading = fx.read(
            fx.habit(task: 1, hours: 2, weeks: 0...4),
            deadlines: [fx.standing(dueInDays: -3, targetHours: 10, loggedHours: 4)])
        let pace = reading.fronts.first?.pace
        #expect(pace?.isOverdue == true)
        #expect(pace?.neededMsPerWeek == nil)
        #expect(pace?.remainingMs == 6 * fx.hour)
        #expect(reading.demandMsPerWeek == 0)
        #expect(reading.verdict == .holding)
        // Still owed, so still on the list.
        #expect(reading.giveTime.map(\.taskID) == [1])
    }

    @Test func aDateOnlyDeadlineCarriesNoDemand() {
        let reading = fx.read(fx.habit(task: 1, hours: 2, weeks: 0...4), deadlines: [fx.standing(dueInDays: 3)])
        #expect(reading.fronts.first?.pace?.neededMsPerWeek == nil)
        #expect(reading.fronts.first?.pace?.isBehind == false)
        #expect(reading.demandMsPerWeek == 0)
    }

    @Test func aMetTargetIsNeitherBehindNorDemand() {
        let reading = fx.read(
            fx.habit(task: 1, hours: 2, weeks: 0...4),
            deadlines: [fx.standing(dueInDays: 3, targetHours: 4, loggedHours: 5)])
        #expect(reading.fronts.first?.pace?.remainingMs == 0)
        #expect(reading.fronts.first?.pace?.isBehind == false)
        #expect(reading.demandMsPerWeek == 0)
    }

    @Test func aYoungDeadlineIsMeasuredSinceItWasMade() {
        // Made two days ago; one fx.hour since. Scaled to a week that is 3.5 h/wk,
        // not the fx.week's whole 8 h — the promise hasn't had a week yet.
        let blocks = [
            // Six days ago, before the promise: a week's figure would count it.
            Workload.Block(startedAt: fx.now - 6 * fx.day, endedAt: fx.now - 6 * fx.day + 7 * fx.hour,
                           category: "work", taskID: 1, taskName: "t"),
            Workload.Block(startedAt: fx.now - fx.day, endedAt: fx.now - fx.day + fx.hour,
                           category: "work", taskID: 1, taskName: "t")
        ]
        let reading = fx.read(blocks, deadlines: [fx.standing(dueInDays: 14, targetHours: 20, createdDaysAgo: 2)])
        #expect(reading.fronts.first?.pace?.gettingMsPerWeek == Int64(3.5 * Double(fx.hour)))
    }

    @Test func behindIsAMarginNotAnEquality() {
        // Needs 7 h/wk (14 h in 14 days); getting 6 — inside the margin.
        let onPace = fx.read(
            fx.habit(task: 1, hours: 6, weeks: 0...4),
            deadlines: [fx.standing(dueInDays: 14, targetHours: 14)])
        #expect(onPace.fronts.first?.pace?.isBehind == false)
        // Getting 2: behind.
        let behind = fx.read(
            fx.habit(task: 1, hours: 2, weeks: 0...4),
            deadlines: [fx.standing(dueInDays: 14, targetHours: 14)])
        #expect(behind.fronts.first?.pace?.isBehind == true)
    }

    @Test func aDoneDeadlineAndATasklessOneStayOutOfThePace() {
        let reading = fx.read(
            fx.habit(task: 1, hours: 2, weeks: 0...4),
            deadlines: [
                fx.standing(id: 1, dueInDays: 2, targetHours: 50, done: true),
                fx.standing(id: 2, task: nil, dueInDays: 2, targetHours: 50),
                fx.standing(id: 3, task: 9, dueInDays: 2)   // a task with no blocks
            ])
        #expect(reading.fronts.first?.pace == nil)
        #expect(reading.demandMsPerWeek == 0)
        #expect(reading.unattached.map(\.deadline.id) == [2, 3])
    }

    @Test func theSoonestOpenDeadlineIsTheOnePaced() {
        let reading = fx.read(
            fx.habit(task: 1, hours: 2, weeks: 0...4),
            deadlines: [fx.standing(id: 1, dueInDays: 30), fx.standing(id: 2, dueInDays: 5)])
        #expect(reading.fronts.first?.pace?.deadlineID == 2)
    }

    // MARK: - Lists

    @Test func giveTimePutsDeadlinesFirstThenTheLargerHabit() {
        var blocks = fx.habit(task: 1, hours: 2, weeks: 1...4) + [fx.block("work", task: 1, weeksAgo: 0, hours: 0.1)]
        blocks += fx.habit(task: 2, hours: 6, weeks: 1...4) + [fx.block("work", task: 2, weeksAgo: 0, hours: 0.1)]
        blocks += fx.habit(task: 3, hours: 1, weeks: 0...4)
        let reading = fx.read(blocks, deadlines: [fx.standing(task: 3, dueInDays: 5, targetHours: 20)])
        #expect(reading.giveTime.map(\.taskID) == [3, 2, 1])
    }

    @Test func frontsAreOrderedByThisWeekThenByHabit() {
        let blocks = fx.habit(task: 1, hours: 1, weeks: 0...4) + fx.habit(task: 2, hours: 3, weeks: 0...4)
        #expect(fx.read(blocks).fronts.map(\.taskID) == [2, 1])
    }

    // MARK: - Themes as the unit

    @Test func theThemeLensGroupsByThemeAndVotesTheSameWay() {
        let research = (Int64(8), "Research")
        let chatter = (Int64(9), "Personal Communication")
        let blocks = [
            fx.block("work", task: 1, weeksAgo: 0, hours: 2, theme: research),
            fx.block("learning", task: 2, weeksAgo: 0, hours: 1, theme: research),
            fx.block("communication", task: 3, weeksAgo: 0, hours: 4, theme: chatter),
            // Filed nowhere: tracked, never a theme front.
            fx.block("work", task: 4, weeksAgo: 0, hours: 1)
        ]
        let reading = fx.read(blocks, deadlines: [fx.standing(task: 1, dueInDays: 3, targetHours: 9)], unit: .theme)
        #expect(reading.fronts.map(\.themeID) == [8])
        #expect(reading.fronts.first?.name == "Research")
        #expect(reading.fronts.first?.thisWeekMs == 3 * fx.hour)
        // Deadlines are per task; the theme lens is about the hours.
        #expect(reading.fronts.first?.pace == nil)
        // Capacity is a fact about the week, whatever the lens.
        #expect(reading.capacity[0] == 4 * fx.hour)
    }

    @Test func aTasksThemeIsTheOneMostOfItsTimeSitsIn() {
        let blocks = [
            fx.block("work", task: 1, weeksAgo: 0, hours: 3, theme: (8, "Research")),
            fx.block("work", task: 1, weeksAgo: 0, hours: 1, theme: (3, "Internships"))
        ]
        #expect(fx.read(blocks).fronts.first?.themeName == "Research")
    }

    // MARK: - The copy

    @Test func figuresPrintAsHoursAndMinutes() {
        #expect(WorkloadCopy.hours(0) == "0m")
        #expect(WorkloadCopy.hours(40 * 60_000) == "40m")
        #expect(WorkloadCopy.hours(2 * fx.hour) == "2h")
        #expect(WorkloadCopy.hours(2 * fx.hour + 5 * 60_000) == "2h 5m")
    }

    @Test func everyVerdictLineNamesItsFigures() {
        let reading = fx.read(fx.habit(task: 1, hours: 5, weeks: 0...4))
        #expect(reading.verdict == .holding)
        #expect(WorkloadCopy.line(reading).contains("5h"))
        #expect(WorkloadCopy.title(.spreadThin) == "Spread thin")
    }

    // MARK: - The read

    @Test func theStoreResolvesTasksAndOnlyNamedThemes() throws {
        let database = try ShifuDatabase.inMemory()
        try database.queue.write { db in
            try db.execute(
                sql: "INSERT INTO tasks (key, name, created_at, last_active_at) VALUES (?, ?, ?, ?)",
                arguments: ["sem:thesis", "Thesis", 0, 0])
            try db.execute(
                sql: "INSERT INTO themes (key, name, created_at, last_active_at) VALUES (?, ?, ?, ?)",
                arguments: ["thm:phd", "PhD", 0, 0])
            for (theme, start) in [("thm:phd", fx.now - 3 * fx.hour), ("thm:proposal", fx.now - 2 * fx.hour)] {
                try db.execute(
                    sql: """
                        INSERT INTO activities
                          (started_at, ended_at, app_bundle, category, source, task_id, theme_key)
                        VALUES (?, ?, 'com.apple.Pages', 'work', 'rules', 1, ?)
                        """,
                    arguments: [start, start + fx.hour, theme])
            }
            // Outside the window entirely.
            try db.execute(
                sql: """
                    INSERT INTO activities (started_at, ended_at, app_bundle, category, source)
                    VALUES (?, ?, 'com.apple.Pages', 'work', 'rules')
                    """,
                arguments: [fx.now - 9 * fx.week, fx.now - 9 * fx.week + fx.hour])
        }
        let blocks = try WorkloadStore.blocks(database: database, now: fx.now)
        #expect(blocks.count == 2)
        #expect(blocks.map(\.taskName) == ["Thesis", "Thesis"])
        #expect(blocks.map(\.themeName) == ["PhD", nil])

        let reading = try WorkloadStore.reading(database: database, now: fx.now)
        #expect(reading.fronts.map(\.name) == ["Thesis"])
        #expect(reading.fronts.first?.themeName == "PhD")
    }
}
