import Foundation

/// The words and places `DeadlineScout` reads its signals from (design.md
/// §4.7). Kept apart from the scorer so the lists can be read as lists.
///
/// Every entry here was put in because the dogfood corpus showed it mattering
/// in one direction or the other: "closes" is a hard deadline on an
/// application page and a dining-hall hour on the campus dashboard, and the
/// scorer can only tell them apart because both facts are written down.
enum ScoutLexicon {
    struct Trigger: Equatable {
        /// The matched word, for the signal trace.
        var word: String
        var category: DeadlineScout.Category
        /// How much the phrasing commits: 3 is a hard date, 2 an action
        /// with a date, 1 a dated occasion, 0 a dated announcement.
        var strength: Int
    }

    private struct Rule {
        var pattern: String
        var category: DeadlineScout.Category
        var strength: Int

        init(_ pattern: String, _ category: DeadlineScout.Category, _ strength: Int) {
            self.pattern = pattern
            self.category = category
            self.strength = strength
        }
    }

    /// Ordered strongest first, and the first match wins — so "applications
    /// close September 25" reads as a hard application deadline rather than
    /// an event, and "midterm" beats "lecture" in the same line.
    private static let triggers: [Rule] = [
        // Hard dates.
        // "due to" is a cause, never a date — the one idiom the August sample
        // was full of.
        Rule("\\b(?:late )?due(?! to\\b)(?: date)?\\b", .submission, 3),
        Rule("\\bdeadline\\b", .submission, 3),
        Rule("\\b(?:must|needs? to) be (?:submitted|received|returned|completed|in)\\b", .submission, 3),
        Rule("\\bno later than\\b", .submission, 3),
        Rule("\\b(?:exam|midterm|finals?\\b(?! (?:score|standings|result)))\\b", .exam, 3),
        Rule("\\b(?:applications?|registration|enrollment|nominations?|submissions?|voting|sign-?ups?|"
         + "rsvp|early bird|priority|window|form|survey|poll) (?:is |are )?(?:now )?"
         + "(?:closes?|closing|ends?|opens?|open|due|closed)\\b", .application, 3),
        Rule("\\b(?:closes?|closing|ends?(?! up\\b)|expires?|expiring|expiration|cutoff|cut-off|"
         + "last (?:day|chance|call)|final (?:day|call|reminder))\\b", .admin, 3),
        Rule("\\b(?:accept|respond|reply|confirm|decide|let (?:me|us) know)\\b.{0,40}\\bby\\b", .admin, 3),
        // Actions with a date.
        Rule("\\b(?:rsvp|register|sign ?up|apply|enroll|nominate|submit|turn in|hand in|upload|renew|"
         + "pay|book|reserve|schedule|vote|withdraw|drop|declare)\\b", .application, 2),
        Rule("\\b(?:quiz|problem ?set|pset|homework|hw ?\\d*|assignment|project|essay|paper|lab report|"
         + "report|draft|thesis|presentation|demo|checkpoint|milestone)\\b", .submission, 2),
        Rule("\\b(?:interview|phone screen|onsite|offer|audition|tryout)\\b", .application, 2),
        Rule("\\b(?:tuition|rent|invoice|bill|payment|fee|tax(?:es)?|lease|visa|passport|renewal|"
         + "subscription|trial|grade option|add/drop|shopping period|housing|lottery)\\b", .admin, 2),
        Rule("\\b(?:flight|boarding|departs?|departure|check-?in|checkout|reservation|itinerary|train|"
         + "hotel|airbnb)\\b", .travel, 2),
        // Dated occasions.
        Rule("\\b(?:meeting|appointment|office hours|1:1|standup|sync|call|hackathon|competition|contest|"
         + "conference|summit|workshop|webinar|seminar|talk|lecture|panel|info session|career fair|"
         + "fair|showcase|ceremony|orientation|retreat|game|match|tournament|concert|show|party|dinner|"
         + "lunch|brunch|celebration|gathering|event)\\b", .event, 1),
        Rule("\\b(?:scholarship|fellowship|grant|internship|co-op|job|position|opening|program|cohort|"
         + "bootcamp|course|class|section)\\b", .application, 1),
        Rule("\\b(?:sale|discount|promo|coupon|giveaway|% off|\\$\\d+ off|free shipping|deal)\\b", .offer, 1),
        // Dated announcements.
        Rule("\\b(?:starts?|starting|begins?|beginning|opens?|opening|kicks? off|kickoff|launch(?:es|ing)?|"
         + "releas(?:e|es|ed|ing)|ships?|available|drops?|premieres?|airs?|save the date|mark your "
         + "calendar|upcoming|coming up|reminder|don'?t forget|happening)\\b", .release, 0)
    ]

    private static let compiled: [(regex: NSRegularExpression, rule: Rule)] =
        triggers.map { (regex($0.pattern), $0) }

    static func trigger(in lowered: String) -> Trigger? {
        let range = NSRange(lowered.startIndex..., in: lowered)
        for entry in compiled {
            guard let match = entry.regex.firstMatch(in: lowered, range: range),
                  let swiftRange = Range(match.range, in: lowered)
            else { continue }
            var word = String(lowered[swiftRange])
            if word.count > 24 { word = String(word.prefix(24)) }
            return Trigger(word: word, category: entry.rule.category, strength: entry.rule.strength)
        }
        return nil
    }

    // MARK: - Places

    /// Apps where a dated line is usually addressed to the user: mail,
    /// calendar, messages, and the places classes and jobs are run from.
    private static let commitmentApps: Set<String> = [
        "com.apple.mail", "com.microsoft.outlook", "com.readdle.smartemail-macos",
        "com.superhuman.electron", "com.apple.ical", "com.flexibits.fantastical2.mac",
        "com.apple.mobilesms", "com.apple.reminders", "com.apple.notes", "notion.id",
        "com.tinyspeck.slackmacgap", "com.hnc.discord", "us.zoom.xos", "com.culturedcode.thingsmac",
        "com.todoist.mac.todoist", "com.omnigroup.omnifocus4"
    ]
    private static let commitmentDomains = [
        "gradescope.com", "instructure.com", "canvas.", "blackboard.com", "moodle", "piazza.com",
        "edstem.org", "cab.brown.edu", "brown.edu", ".edu", "workday.com", "myworkday.com",
        "joinhandshake.com", "greenhouse.io", "lever.co", "ashbyhq.com", "icims.com", "smartrecruiters.com",
        "workable.com", "myinterview.com", "hirevue.com", "mail.google.com", "outlook.live.com",
        "outlook.office.com", "calendar.google.com", "commonapp.org", "applyweb.com", "slideroom.com",
        "devpost.com", "luma.com", "lu.ma", "eventbrite.com", "partiful.com", "meetup.com", "cvent.com",
        "ticketmaster.com", "airbnb.com", "expedia.com", "kayak.com", "booking.com", "delta.com",
        "united.com", "aa.com", "jetblue.com", "southwest.com", "amtrak.com", "irs.gov", "studentaid.gov",
        "fafsa.gov", "uscis.gov", "state.gov", "dmv."
    ]
    /// Where a date is almost always somebody else's: feeds, sports, markets,
    /// video, news.
    private static let noiseDomains = [
        "x.com", "twitter.com", "reddit.com", "youtube.com", "instagram.com", "tiktok.com",
        "facebook.com", "threads.net", "bsky.app", "linkedin.com/feed", "kalshi.com", "polymarket.com",
        "espn.com", "nfl.com", "nba.com", "mlb.com", "premierleague.com", "news.google.com",
        "nytimes.com", "washingtonpost.com", "theguardian.com", "bbc.", "cnn.com", "bloomberg.com",
        "wsj.com", "techcrunch.com", "theverge.com", "hackernews", "news.ycombinator.com", "wikipedia.org",
        "netflix.com", "hulu.com", "twitch.tv", "spotify.com"
    ]
    /// Terminals, editors, agents, and the tools that run them. Dated text
    /// there is code, logs and transcripts — which discuss deadlines without
    /// having them.
    private static let developerBundles = [
        "com.mitchellh.ghostty", "com.apple.terminal", "com.googlecode.iterm2", "dev.warp.warp-stable",
        "com.microsoft.vscode", "com.apple.dt.xcode", "com.todesktop.230313mzl4w4u92", "com.jetbrains.",
        "com.sublimetext", "com.anthropic.claudefordesktop", "com.openai.chat", "com.conductor.app",
        "com.github.githubclient", "com.figma.desktop", "com.docker.docker", "com.postmanlabs.mac",
        "com.tinyapp.tableplus", "dev.zed.zed", "com.meta.endo"
    ]

    /// The user's own dev server and the code hosts: dates there are data.
    private static let developerDomains = [
        "localhost", "127.0.0.1", "0.0.0.0", "github.com", "gitlab.com", "stackoverflow.com",
        "developer.apple.com", "docs.", "npmjs.com", "pypi.org", "crates.io", "huggingface.co",
        "claude.ai", "chatgpt.com", "chat.deepseek.com", "muse.ai", "gemini.google.com"
    ]

    /// Shifu's own windows and bundle-less processes: never a source. The
    /// August measurement's loudest false positive was Shifu reading its
    /// review queue back to itself.
    static func isIgnoredBundle(_ bundle: String) -> Bool {
        let lowered = bundle.lowercased()
        return lowered.hasPrefix("com.shifu.") || lowered.hasPrefix("unknown.")
            || lowered == "com.apple.loginwindow" || lowered == "com.apple.dock"
    }

    static func isCommitmentApp(_ bundle: String) -> Bool {
        commitmentApps.contains(bundle.lowercased())
    }

    static func isDeveloperBundle(_ bundle: String) -> Bool {
        let lowered = bundle.lowercased()
        return developerBundles.contains { lowered.hasPrefix($0) }
    }

    static func isDeveloperDomain(_ domain: String) -> Bool {
        let lowered = domain.lowercased()
        return developerDomains.contains { lowered.hasPrefix($0) || lowered.hasSuffix($0) }
    }

    static func isCommitmentDomain(_ domain: String) -> Bool {
        let lowered = domain.lowercased()
        return commitmentDomains.contains { lowered.hasSuffix($0) || lowered.contains($0) }
    }

    static func isNoiseDomain(_ domain: String) -> Bool {
        let lowered = domain.lowercased()
        return noiseDomains.contains { lowered.hasSuffix($0) || lowered.contains($0) }
    }

    /// A search results tab: the dates in it belong to the results.
    static func isSearchResults(_ title: String?) -> Bool {
        guard let lowered = title?.lowercased() else { return false }
        return lowered.contains(" - google search") || lowered.contains(" - bing")
            || lowered.contains(" at duckduckgo") || lowered.contains("search results")
            || lowered.hasPrefix("searching")   // Mail's search list: old subjects, stale dates
    }

    // MARK: - Phrasing

    /// "closes at 11:30 PM", "opens tomorrow at 7:30 AM": a clock right after
    /// an open/close verb. Only read when the line's date is a weekday or a
    /// relative word — with a calendar date in it, "the form will close on
    /// 10/15 at 11:59pm" is a deadline, not opening hours.
    private static let hoursClock = regex(
        "\\b(?:opens?|closes?|closing|closed|open|hours?)\\b(?: (?:at|in|until|till|from|on|tomorrow|today|"
        + "tonight|every|daily|dinner|lunch|breakfast|late))*\\s*(?:at|in|until|till|from|–|-)?\\s*"
        + "\\d{1,2}(?::\\d{2})?\\s*(?:am|pm|a\\.m\\.|p\\.m\\.)")
    /// Opening-hours shapes that are never a deadline whatever the date form.
    private static let hoursAlways = regex(
        "\\bin \\d+ (?:minutes?|mins?|hours?|hrs?)\\b"
        + "|\\b(?:mon|tue|wed|thu|fri|sat|sun)[a-z]*\\s*[–-]\\s*(?:mon|tue|wed|thu|fri|sat|sun)[a-z]*\\b"
        + "|\\bnext to close\\b|\\bopen (?:now|late|24)\\b|\\bdining\\b|\\brefectory\\b|\\bhours of operation\\b")
    /// A year before the one the line was seen in: the sentence is history.
    private static let yearPattern = regex("\\b(19\\d\\d|20\\d\\d)\\b")
    private static let metadata = regex(
        "\\b(?:last (?:opened|modified|edited|updated|viewed|synced)|posted|published|updated|"
        + "created|uploaded|released|modified|edited|sent|received|joined|added|archived|since)\\b"
        + "(?: (?:by|on|at))?(?: me)?(?: on)?\\s*:?\\s*$")
    /// "by <date>", "before <date>", "no later than <date>": the date is a
    /// bound, whatever else the line says.
    private static let bound = regex(
        "\\b(?:by|before|until|till|through|no later than|prior to|on or before)\\s*$")
    private static let youPattern = regex("\\b(?:you|your|you're|yours|hi [a-z]+,|dear [a-z]+)\\b")
    private static let datedFile = regex(
        "\\b\\d{4}-\\d{2}-\\d{2}[-_][a-z0-9]|\\.(?:md|swift|py|js|ts|txt|json|log|csv|pdf|png)\\b")
    private static let pastWords = regex("\\b(?:was|were|had|ago|since|happened|took place|held|back in)\\b")

    static func isHoursOfOperation(_ lowered: String, calendarDate: Bool) -> Bool {
        matches(hoursAlways, lowered) || (!calendarDate && matches(hoursClock, lowered))
    }

    /// Whether the line mentions a year earlier than the one it was seen in.
    static func mentionsHistory(_ lowered: String, seenYear: Int) -> Bool {
        let range = NSRange(lowered.startIndex..., in: lowered)
        return yearPattern.matches(in: lowered, range: range).contains { match in
            guard let swiftRange = Range(match.range, in: lowered), let year = Int(lowered[swiftRange])
            else { return false }
            return year < seenYear
        }
    }
    static func addressesReader(_ lowered: String) -> Bool { matches(youPattern, lowered) }
    static func isDatedFilename(_ lowered: String) -> Bool { matches(datedFile, lowered) }

    /// "Last opened by me May 30, 2026", "Posted Sep 24" — a timestamp on a
    /// thing, not a date to meet. Judged on the words just before the date
    /// rather than the whole line, because an email about a deadline can
    /// also say when it was sent.
    static func isTimestampMetadata(before range: Range<String.Index>, in line: String) -> Bool {
        matches(metadata, lead(line, before: range))
    }

    /// Past tense within a few words before the date: "was Sept. 16",
    /// "held on October 1".
    static func isPastTense(before range: Range<String.Index>, in line: String) -> Bool {
        matches(pastWords, lead(line, before: range))
    }

    /// Whether the date is written as a bound — "by Monday", "before Oct 6".
    static func isBound(before range: Range<String.Index>, in line: String) -> Bool {
        matches(bound, lead(line, before: range))
    }

    /// The couple of dozen characters before a date, lowercased.
    private static func lead(_ line: String, before range: Range<String.Index>) -> String {
        let head = line[..<range.lowerBound]
        return String(head.suffix(28)).lowercased()
    }

    /// The window title with the browser's and the app's suffixes removed:
    /// "Fall 2026 CSCI 1420 Dashboard | Gradescope - Google Chrome - Jerry
    /// (Work)" → "Fall 2026 CSCI 1420 Dashboard". Nil when the title is the
    /// line itself, or says nothing.
    static func windowContext(_ title: String?, line: String) -> String? {
        guard var text = title?.trimmingCharacters(in: .whitespaces), text != line else { return nil }
        for separator in [" - Google Chrome", " — Mozilla Firefox", " - Safari", " – Arc", " | ", " — ", " – "] {
            if let range = text.range(of: separator) { text = String(text[..<range.lowerBound]) }
        }
        text = text.replacingOccurrences(of: "^\\(\\d+\\)\\s*|^\\d+ (?:of \\d+ )?open(?: now)? · ", with: "",
                                         options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespaces)
        guard text.count >= 3, text.count <= 80, text != line else { return nil }
        return text
    }

    // MARK: - Pieces

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
