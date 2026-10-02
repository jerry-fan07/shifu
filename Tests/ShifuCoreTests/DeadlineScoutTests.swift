import Foundation
import Testing
@testable import ShifuCore

/// The scout and its scorer (design.md §4.7).
///
/// What is pinned here is the *ranking*, on lines lifted from the real
/// corpus: the graded submission lands at the top, the dining-hall hour at
/// the bottom, and the two idioms the August measurement was full of ("due
/// to", Shifu's own window) never become a hit at all. The thresholds
/// themselves are re-earned with `shifu due scan --dry` against a dogfood
/// copy; these cases guard the signals that produced them.
@Suite struct DeadlineScoutTests {
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        cal.locale = Locale(identifier: "en_US")
        return cal
    }

    private func moment(_ text: String, hour: Int = 10) -> Int64 {
        let parts = text.split(separator: "-").map { Int($0)! }
        let components = DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: hour)
        return Int64(calendar.date(from: components)!.timeIntervalSince1970 * 1_000)
    }

    private func source(
        app: String = "com.google.Chrome", domain: String? = nil, title: String? = nil,
        task: Int64? = nil, seen: String = "2026-09-20"
    ) -> DeadlineScout.Source {
        DeadlineScout.Source(appBundle: app, domain: domain, windowTitle: title, taskID: task,
                             seenAt: moment(seen))
    }

    private func scan(_ text: String?, _ source: DeadlineScout.Source) -> [DeadlineScout.Hit] {
        DeadlineScout.scan(text: text, source: source, calendar: calendar)
    }

    // MARK: - The top of the ranking

    @Test func aGradedSubmissionOnACoursePageIsCritical() throws {
        let hit = try #require(scan(
            "Late Due Date: Sep 25 at 12:00PM",
            source(domain: "gradescope.com",
                   title: "Fall 2026 CSCI 1420 Dashboard | Gradescope - Google Chrome - Jerry (Work)",
                   task: 7)).first)
        #expect(hit.category == .submission)
        #expect(hit.tier == .critical)
        #expect(hit.title == "Late Due Date")
        #expect(hit.context == "Fall 2026 CSCI 1420 Dashboard")
        #expect(hit.dueAt == moment("2026-09-25", hour: 12))
        #expect(!hit.allDay)
        #expect(hit.key == "2026-09-25|late-due-date")
    }

    /// "by <date>" is a commitment on its own, whatever the line is about.
    @Test func aDateWrittenAsABoundIsAHitWithoutATriggerWord() throws {
        let hit = try #require(scan(
            "Interview invitation offered, sign up by Monday 11:59",
            source(app: "com.apple.mail", title: "All Inboxes", task: 3, seen: "2026-09-26")).first)
        #expect(hit.tier == .critical)
        #expect(hit.signals.contains("bound"))
        let bare = try #require(scan("please email each other by Oct 1",
                                     source(app: "com.apple.mail", seen: "2026-09-20")).first)
        #expect(bare.category == .submission)
        #expect(bare.signals.first == "by:+3")
    }

    @Test func anApplicationClosingInMailIsHigh() throws {
        let hit = try #require(scan(
            "TIP applications close September 20th., $50 course fee",
            source(app: "com.apple.mail", title: "Inbox", seen: "2026-09-10")).first)
        #expect(hit.category == .application)
        #expect(hit.tier == .high)
    }

    // MARK: - The bottom of the ranking

    /// The campus dining dashboard: "closes dinner in 28 minutes", "opens
    /// Sunday at 5 PM". Opening hours, never a deadline.
    @Test func openingHoursSinkToLow() {
        let hits = scan(
            "Sharpe Refectory closes dinner in 28 minutes. Ivy Room opens Sunday at 5 PM.",
            source(title: "4 of 8 open · Brown Dining - Google Chrome - Jerry", task: 2))
        #expect(hits.allSatisfy { $0.tier == .low })
        let gym = scan("Nelson Fitness Center closes at 11:30 PM Mon–Thu.", source(app: "com.conductor.app"))
        #expect(gym.isEmpty)   // no date at all
    }

    /// A calendar date beside a clock is a deadline even when the verb is
    /// "close": the hours penalty is for weekday-and-clock shapes only.
    @Test func aFormClosingOnADateIsNotOpeningHours() throws {
        let hit = try #require(scan("The form will close on 10/15 at 11:59pm.",
                                    source(app: "com.apple.mail", title: "Inbox", seen: "2026-10-02")).first)
        #expect(!hit.signals.contains("hours:-6"))
        #expect(hit.tier >= .normal)
    }

    @Test func dueToIsNeverADueDate() {
        let hits = scan(
            "Due to a mandatory faculty meeting tomorrow, office hours move.",
            source(domain: "edstem.org"))
        #expect(hits.allSatisfy { $0.category != .submission })
        #expect(hits.allSatisfy { !$0.signals.contains { $0.hasPrefix("due") } })
    }

    @Test func shifusOwnWindowIsNeverASource() {
        let hits = scan("3 cards due today · median interval 1 day", source(app: "com.shifu.app"))
        #expect(hits.isEmpty)
        #expect(scan("due tomorrow", source(app: "unknown.4242")).isEmpty)
    }

    @Test func feedsSearchesAndCodeArePenalised() throws {
        let video = try #require(scan("Watch every out-of-market Sunday afternoon game",
                                      source(domain: "youtube.com", task: 1)).first)
        #expect(video.tier == .low)
        #expect(video.signals.contains("noise-domain:-3"))
        let search = try #require(scan(
            "The ICPC NENA Regional Contest will take place on Sunday, November 8, 2026.",
            source(domain: "google.com",
                   title: "Northeast North America Regional Contest - Google Search")).first)
        #expect(search.signals.contains("search:-2"))
        #expect(search.tier <= .normal)
        let listing = scan(".rw-r--r--@ 28k jerryfan 1 Oct 04:11 reports/report.md",
                           source(app: "com.mitchellh.ghostty"))
        #expect(listing.allSatisfy { $0.tier == .low })
        let changelog = scan("release notes for Nov 8 live in CHANGELOG.md",
                             source(app: "com.mitchellh.ghostty", seen: "2026-10-02"))
        #expect(changelog.isEmpty)   // below the floor: not even a remembered row
    }

    @Test func historyAndPastTenseAreNotComingUp() throws {
        let news = try #require(scan(
            "On February 25, he brought twelve students to the ICPC's 2022 Regional Contest.",
            source(domain: "cs.brown.edu", seen: "2026-10-02")).first)
        #expect(news.signals.contains("history:-2"))
        let past = try #require(scan("the add deadline was Sept. 16, after which a late fee applies",
                                     source(seen: "2026-09-01")).first)
        #expect(past.signals.contains("past:-2"))
    }

    // MARK: - Words

    @Test func theWindowTitleIsReadAsALineToo() throws {
        let hit = try #require(scan(nil, source(
            app: "com.apple.iCal", title: "Duolingo Thrive Intern — apply by Oct 10 (eligible)",
            seen: "2026-10-02")).first)
        #expect(hit.category == .application)
        #expect(hit.title == "Duolingo Thrive Intern — apply (eligible)")
        #expect(hit.context == nil)   // the title *is* the line
    }

    /// The same RSVP line under four Mail window titles, one of them chewed
    /// by OCR: one key.
    @Test func theKeyIgnoresTheWindowAndTrailingPunctuation() throws {
        let one = try #require(scan("RSVP here by Monday, September 28",
                                    source(app: "com.apple.mail", title: "All Inboxes", seen: "2026-09-22")).first)
        let two = try #require(scan("RSVP here by Monday, September 28-",
                                    source(app: "com.apple.mail", title: "Inbox — Brown – 5,760 messages",
                                           seen: "2026-09-23")).first)
        #expect(one.key == two.key)
        #expect(one.key == "2026-09-28|rsvp-here")
    }

    @Test func titlesDropTheDateAndItsBracketsAndStayShort() throws {
        let reminder = try #require(scan("Reminder: DRP Applications (due Friday!)",
                                         source(domain: "edstem.org", seen: "2026-09-28")).first)
        #expect(reminder.title == "Reminder: DRP Applications")
        let long = String(repeating: "word ", count: 60) + "due Oct 20"
        let hit = try #require(scan(long, source(seen: "2026-10-02")).first)
        #expect(hit.title.count <= DeadlineScout.titleLimit + 1)
        #expect(hit.title.hasSuffix("…"))
        #expect(hit.evidence.count <= DeadlineScout.evidenceLimit)
    }

    /// One hit per line, on its first date: a syllabus line listing four
    /// due dates is one row, not four.
    @Test func oneHitPerLine() {
        let hits = scan("There will be four homework assignments, due on Oct 9, Oct 23, Nov 6, Nov 29.",
                        source(domain: "coursetools.brown.edu", seen: "2026-10-02"))
        #expect(hits.count == 1)
        #expect(hits.first?.dueAt == moment("2026-10-09", hour: 0))
    }

    @Test func repeatedLinesInOneObservationCountOnce() {
        let hits = scan("HW 1 Due (Oct 2)\nHW 1 Due (Oct 2)\nHW 2 Due (Oct 23)",
                        source(app: "com.apple.Preview", seen: "2026-09-25"))
        #expect(hits.count == 2)
    }

    // MARK: - Tiers

    @Test func tierCutPoints() {
        #expect(DeadlineScout.Tier.of(score: 9) == .critical)
        #expect(DeadlineScout.Tier.of(score: 8) == .high)
        #expect(DeadlineScout.Tier.of(score: 6) == .high)
        #expect(DeadlineScout.Tier.of(score: 5) == .normal)
        #expect(DeadlineScout.Tier.of(score: 2) == .normal)
        #expect(DeadlineScout.Tier.of(score: 1) == .low)
        #expect(DeadlineScout.Tier.of(score: -2) == .low)
        #expect(DeadlineScout.Tier.critical > DeadlineScout.Tier.high)
        #expect(DeadlineScout.Tier.high > DeadlineScout.Tier.normal)
        #expect(DeadlineScout.Tier.normal > DeadlineScout.Tier.low)
    }
}
