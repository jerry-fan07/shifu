import Foundation
import Testing
@testable import ShifuCore

/// The describer's pure half (design.md §6.2). `RadarTests` drives the whole
/// pipeline against a mock backend; this pins the parsing and the honesty
/// gates directly, because those are what stand between "the model asserted a
/// number" and "the tab showed it".
@Suite struct RadarDescriptionParsingTests {
    private func parse(_ json: String) -> [Radar.Description] {
        Radar.parseDescriptions(json)
    }

    @Test func aCleanArrayParses() {
        let parsed = parse("""
        [{"id": 12, "verdict": "yes", "title": "Weekly invoice reconciliation",
          "suggestion": "Use Claude Code on a cron.", "setup_minutes": 45,
          "saved_minutes_weekly": 30, "teach": "launchd can run it unattended.",
          "confidence": 0.8}]
        """)
        #expect(parsed.count == 1)
        #expect(parsed[0].id == 12)
        #expect(parsed[0].verdict == "yes")
        #expect(parsed[0].setupMinutes == 45)
        #expect(parsed[0].savedMinutesWeekly == 30)
        #expect(parsed[0].confidence == 0.8)
    }

    @Test func jsonWrappedInProseIsRecovered() {
        let parsed = parse("""
        Here is my assessment:
        [{"id": 1, "title": "t", "suggestion": "s", "confidence": 0.9}]
        Let me know if you want more detail.
        """)
        #expect(parsed.count == 1)
        #expect(parsed[0].verdict == "yes")   // omitted verdict defaults to yes
    }

    /// "Models answer 45 and 45 minutes about equally often."
    @Test func numbersWrittenAsProseAreRead() {
        let parsed = parse("""
        [{"id": 1, "title": "t", "suggestion": "s", "setup_minutes": "45 minutes",
          "saved_minutes_weekly": "30", "confidence": "0.7"}]
        """)
        #expect(parsed[0].setupMinutes == 45)
        #expect(parsed[0].savedMinutesWeekly == 30)
        #expect(parsed[0].confidence == 0.7)
    }

    /// A range ("2-4 hours") is not a number. It has to read as *missing*, so
    /// the row stays pending rather than being gated on a guess.
    @Test func anUnparseableNumberIsMissingRatherThanZero() {
        let parsed = parse("""
        [{"id": 1, "title": "t", "suggestion": "s", "setup_minutes": "about an hour",
          "saved_minutes_weekly": "1.5-2", "confidence": 0.9}]
        """)
        #expect(parsed[0].setupMinutes == nil)
        #expect(parsed[0].savedMinutesWeekly == nil)
    }

    @Test func entriesMissingTheFieldsAVerdictNeedsAreDropped() {
        let parsed = parse("""
        [{"id": 1, "title": "t", "suggestion": "s", "confidence": 0.9},
         {"verdict": "yes", "title": "no id", "suggestion": "s"},
         {"id": 3, "suggestion": "no title"},
         {"id": 4, "title": "no suggestion"}]
        """)
        #expect(parsed.map(\.id) == [1])
    }

    @Test func garbageYieldsNothingRatherThanThrowing() {
        #expect(parse("").isEmpty)
        #expect(parse("no json at all").isEmpty)
        #expect(parse("[").isEmpty)
        #expect(parse("]not[").isEmpty)
        #expect(parse("{\"id\": 1}").isEmpty)   // an object, not an array
        #expect(parse("[]").isEmpty)
    }

    /// The tab renders these; an unbounded string from the model would blow
    /// the row's layout out.
    @Test func proseFieldsAreCappedAtTheirRenderableLength() {
        let long = String(repeating: "x", count: 5_000)
        let parsed = parse("""
        [{"id": 1, "title": "\(long)", "suggestion": "\(long)",
          "teach": "\(long)", "confidence": 0.9}]
        """)
        #expect(parsed[0].title.count == 80)
        #expect(parsed[0].suggestion.count == 600)
        #expect(parsed[0].teach?.count == 240)
    }

    @Test func verdictIsCaseInsensitive() {
        let parsed = parse("""
        [{"id": 1, "verdict": "NO", "title": "t", "suggestion": "s", "confidence": 0.9}]
        """)
        #expect(parsed[0].verdict == "no")
    }
}

/// The worthwhileness gate. "Ground every claim in the evidence" is a prompt
/// rule, and prompt rules are requests — these are the rules in code.
@Suite struct RadarOutcomeTests {
    private func description(
        verdict: String = "yes", setup: Double? = 30, saved: Double? = 60,
        confidence: Double = 0.9
    ) -> Radar.Description {
        Radar.Description(
            id: 1, verdict: verdict, title: "t", suggestion: "s",
            setupMinutes: setup, savedMinutesWeekly: saved, teach: nil,
            confidence: confidence)
    }

    @Test func aConfidentPayingSuggestionIsAccepted() {
        #expect(Radar.outcome(description(), observedWeeklyMinutes: 90)
            == .accepted(savedMinutesWeekly: 60))
    }

    @Test func aNoIsRejectedHoweverGoodItsNumbersLook() {
        #expect(Radar.outcome(description(verdict: "no", setup: 1, saved: 600),
                              observedWeeklyMinutes: 600) == .rejected)
    }

    @Test func belowTheConfidenceFloorIsRejected() {
        let justUnder = Radar.confidenceFloor - 0.01
        #expect(Radar.outcome(description(confidence: justUnder),
                              observedWeeklyMinutes: 90) == .rejected)
        #expect(Radar.outcome(description(confidence: Radar.confidenceFloor),
                              observedWeeklyMinutes: 90) != .rejected)
    }

    /// A workflow that costs 40 minutes a week cannot be made to save 600.
    @Test func theSavingIsHeldToWhatWasActuallyObserved() {
        #expect(Radar.outcome(description(setup: 30, saved: 600), observedWeeklyMinutes: 40)
            == .accepted(savedMinutesWeekly: 40))
    }

    @Test func setupMustPayForItselfInsideThePaybackWindow() {
        let saved: Double = 30
        let limit = Radar.maxPaybackWeeks * saved
        #expect(Radar.outcome(description(setup: limit, saved: saved),
                              observedWeeklyMinutes: saved) != .rejected)
        #expect(Radar.outcome(description(setup: limit + 1, saved: saved),
                              observedWeeklyMinutes: saved) == .rejected)
    }

    /// Not a no: a formatting slip shouldn't bury a real suggestion, so the
    /// row stays pending and is asked about again next week.
    @Test func aYesWithoutNumbersIsUnansweredRatherThanRejected() {
        #expect(Radar.outcome(description(setup: nil), observedWeeklyMinutes: 90)
            == .unanswered)
        #expect(Radar.outcome(description(saved: nil), observedWeeklyMinutes: 90)
            == .unanswered)
    }

    @Test func nonsensicalNumbersAreUnansweredNotAccepted() {
        #expect(Radar.outcome(description(saved: 0), observedWeeklyMinutes: 90) == .unanswered)
        #expect(Radar.outcome(description(saved: -5), observedWeeklyMinutes: 90) == .unanswered)
        #expect(Radar.outcome(description(setup: -5), observedWeeklyMinutes: 90) == .unanswered)
    }

    /// Zero observed minutes must not make the payback gate divide the saving
    /// down to nothing and reject everything.
    @Test func anUnobservedWorkflowStillGetsAFloorOfOneMinute() {
        #expect(Radar.outcome(description(setup: 1, saved: 10), observedWeeklyMinutes: 0)
            == .accepted(savedMinutesWeekly: 1))
    }

    @Test func aPartialVerdictIsTreatedAsAYes() {
        #expect(Radar.outcome(description(verdict: "partial"), observedWeeklyMinutes: 90)
            != .rejected)
    }
}
