import Foundation
import Testing
@testable import ShifuCore

@Suite struct NoteProseLineTests {
    @Test func plainProseIsOneParagraph() {
        let lines = NoteProse.lines("The day spanned several workstreams.")
        #expect(lines == [NoteProse.Line(text: "The day spanned several workstreams.")])
    }

    @Test func blankLinesSeparateParagraphs() {
        let lines = NoteProse.lines("first\n\nsecond")
        #expect(lines.map(\.text) == ["first", "second"])
        #expect(lines.allSatisfy { $0.kind == .paragraph })
    }

    @Test func unmarkedLineUnderAnOpenOneIsFoldedIntoIt() {
        // A hard-wrapped source line is one paragraph, not two.
        let lines = NoteProse.lines("- a bullet that\n  wrapped in the file")
        #expect(lines.count == 1)
        #expect(lines[0].kind == .bullet(marker: "•"))
        #expect(lines[0].text == "a bullet that\nwrapped in the file")
    }

    @Test func headingsCarryTheirLevel() {
        let lines = NoteProse.lines("## Sessions\n### Learned / decided\ntext")
        #expect(lines[0].kind == .heading(level: 2))
        #expect(lines[0].text == "Sessions")
        #expect(lines[1].kind == .heading(level: 3))
        #expect(lines[2].kind == .paragraph)   // a heading doesn't stay open
        #expect(lines[2].text == "text")
    }

    @Test func hashWithoutASpaceIsNotAHeading() {
        #expect(NoteProse.heading("#1 priority") == nil)
        #expect(NoteProse.heading("#### too deep") == nil)
    }

    @Test func bulletMarkers() {
        let lines = NoteProse.lines("- one\n* two\n1. three\n2) four")
        #expect(lines.map(\.kind) == [
            .bullet(marker: "•"), .bullet(marker: "•"),
            .bullet(marker: "1."), .bullet(marker: "2.")
        ])
        #expect(lines.map(\.text) == ["one", "two", "three", "four"])
    }

    @Test func aMarkerCutOffByAnInlineSpanIsStillABullet() {
        // "- `code` first" reaches the line pass as "- " with the content in
        // the next run; the trailing space distinguishes it from a bare "-".
        #expect(NoteProse.lines("- ")
            == [NoteProse.Line(kind: .bullet(marker: "•"), text: "")])
        #expect(NoteProse.lines("3. ")
            == [NoteProse.Line(kind: .bullet(marker: "3."), text: "")])
        #expect(NoteProse.lines("-") == [NoteProse.Line(text: "-")])
    }

    @Test func aMinusSignIsNotABullet() {
        #expect(NoteProse.bullet("-3 degrees") == nil)
        #expect(NoteProse.bullet("2026-07-31 was the day") == nil)
    }

    @Test func sessionLeadSplitsOffItsSpan() {
        let lines = NoteProse.lines("**09:44–10:39** — Built the forecast band.")
        #expect(lines[0].kind == .session(span: "09:44–10:39"))
        #expect(lines[0].text == "Built the forecast band.")
    }

    @Test func sessionLeadSurvivesAListMarkerAndAPairOfSpans() {
        // Both shapes the model actually emits (WorkNoteNarrative's prompt).
        let lines = NoteProse.lines("- **13:10–13:12, 14:38–14:40** - Two stretches.")
        #expect(lines[0].kind == .session(span: "13:10–13:12, 14:38–14:40"))
        #expect(lines[0].text == "Two stretches.")
    }

    @Test func datedLeadsSplitOffTheirSpan() {
        let range = NoteProse.lines("- **2026-07-19 to 2026-07-27** — Daily browsing.")
        #expect(range == [NoteProse.Line(
            kind: .dated(span: "2026-07-19 to 2026-07-27"), text: "Daily browsing.")])
        let single = NoteProse.lines("**2026-07-28** — Intensive session.")
        #expect(single.first?.kind == .dated(span: "2026-07-28"))
    }

    @Test func aBoldLeadWithADateInASentenceIsNotDated() {
        // The bold run has to be dates and joiners only — a date mentioned
        // inside a bold clause is emphasis, not a timeline row.
        let lines = NoteProse.lines("**Shipped 2026-07-28 late** — notes.")
        #expect(lines.first?.kind == .paragraph)
    }

    @Test func dayLabelsCompactTheMargin() {
        #expect(NoteProse.dayLabel("2026-07-28") == "Jul 28")
        #expect(NoteProse.dayLabel("2026-07-19 to 2026-07-27") == "Jul 19–27")
        #expect(NoteProse.dayLabel("2026-07-29–2026-08-02") == "Jul 29–Aug 2")
        // The month-name form a titled phase's parenthetical is written in.
        #expect(NoteProse.dayLabel("July 20–25") == "Jul 20–25")
        #expect(NoteProse.dayLabel("July 27") == "Jul 27")
        #expect(NoteProse.dayLabel("July 29 to August 2") == "Jul 29–Aug 2")
        // Unparseable leads come back as written rather than half-formatted.
        #expect(NoteProse.dayLabel("sometime") == "sometime")
    }

    @Test func aTitledPhaseWithAParentheticalDateIsDated() {
        let lines = NoteProse.lines(
            "- **Capture daemon debugging (July 20–25)** — Investigated idle thresholds.")
        #expect(lines == [NoteProse.Line(
            kind: .dated(span: "July 20–25"),
            text: "**Capture daemon debugging** — Investigated idle thresholds.")])
        // A parenthetical that is not a date is an ordinary bold lead-in.
        let plain = NoteProse.lines("- **Radar rewrite (WIP)** — Sketched the pass.")
        #expect(plain.first?.kind == .bullet(marker: "•"))
    }

    @Test func aBareMonthNameLeadIsDatedToo() {
        let lines = NoteProse.lines("- **July 17–26**: Only day-note headers.")
        #expect(lines == [NoteProse.Line(
            kind: .dated(span: "July 17–26"), text: "Only day-note headers.")])
        // A bold phrase that merely starts with a month name is not a date.
        let march = NoteProse.lines("- **March on Washington** — Read the history.")
        #expect(march.first?.kind == .bullet(marker: "•"))
    }

    @Test func spanDatesPlaceALeadOnTheCalendar() throws {
        let range = try #require(NoteProse.spanDates("2026-07-19 to 2026-07-27"))
        let calendar = Calendar(identifier: .gregorian)
        #expect(calendar.dateComponents(
            [.day], from: range.lowerBound, to: range.upperBound).day == 8)
        let single = try #require(NoteProse.spanDates("July 27"))
        #expect(single.lowerBound == single.upperBound)
        #expect(NoteProse.spanDates("sometime") == nil)
    }

    @Test func aTimelineHeadingDeclaresClaims() {
        #expect(NoteProse.shape(
            of: ["Cost Model Analysis: Investigated July 30th usage data.",
                 "Verification: Confirmed the build passes all tests."],
            under: "Timeline") == .claims)
    }

    @Test func labelBreaksSplitAtAnEarlyColon() throws {
        let split = try #require(NoteProse.labelBreak(
            "Verification: Confirmed the build passes all tests."))
        #expect(split.head == 12)
        #expect(split.tail == 14)
        // A colon deep inside a sentence, or after a finished one, is not a
        // label's.
        #expect(NoteProse.labelBreak(
            "The daemon was rebuilt twice. Root cause: a stale binary.") == nil)
        #expect(NoteProse.labelBreak("No seam in this sentence at all") == nil)
    }

    @Test func aBoldLeadInThatIsNotATimeIsNotASession() {
        #expect(NoteProse.session("**Note:** read this") == nil)
        #expect(NoteProse.session("**bold** start") == nil)
    }

    @Test func aContinuingRunStartsMidLine() {
        // What CardTextView hands back after cutting an inline code span out
        // of the middle of a bullet: the tail is the same line, and the "- "
        // shape inside it is not a new bullet.
        let lines = NoteProse.lines(" - the retry flag\n- next item", continuing: true)
        #expect(lines.count == 2)
        #expect(lines[0].continuesPrevious)
        #expect(lines[0].text == " - the retry flag")
        #expect(lines[1].kind == .bullet(marker: "•"))
    }

    @Test func theSpaceBeforeAnInlineSpanSurvives() {
        // The run ends where the caller cut a code span out of it, so its last
        // space is the gap between two words, not indentation.
        let lines = NoteProse.lines("- Started a ")
        #expect(lines[0].text == "Started a ")
    }

    @Test func aRunStartingWithANewlineClosesTheOpenLine() {
        let lines = NoteProse.lines("\nafter", continuing: true)
        #expect(lines.count == 1)
        #expect(!lines[0].continuesPrevious)
        #expect(lines[0].text == "after")
    }

    @Test func theRealWorkNoteBodyReadsAsItsSections() {
        let body = """
        claudefordesktop, app — developing Shifu

        ## Sessions
        **00:00–01:06** — Reviewed a cost-reduction plan.

        ## Notes
        ### Learned / decided
        - Tests needed to be written red first.
        - The chart should be columns, not a heatmap.
        """
        let kinds = NoteProse.lines(body).map(\.kind)
        #expect(kinds == [
            .paragraph,
            .heading(level: 2), .session(span: "00:00–01:06"),
            .heading(level: 2), .heading(level: 3),
            .bullet(marker: "•"), .bullet(marker: "•")
        ])
    }
}

@Suite struct NoteProseShapeTests {
    private let learned = [
        "A Mac App Store build cannot use Accessibility APIs against other processes, "
            + "so Shifu's capture ladder would lose roughly 80% of its text.",
        "Qwen 3.5-4B was chosen as the first local-model probe instead of Bonsai 27B "
            + "because it runs on mainline llama.cpp."
    ]
    private let problems = [
        "The ribbon axis sat a row off → recomputed it from the clock window.",
        "The highlight marker read as two marks → replaced with one glowing ball."
    ]

    @Test func aListOfArrowsIsPairs() throws {
        #expect(NoteProse.shape(of: problems) == .pairs)
        let split = try #require(NoteProse.pairBreak(problems[0]))
        let head = String(problems[0].prefix(split.head))
        let tail = String(problems[0].dropFirst(split.tail))
        #expect(head == "The ribbon axis sat a row off")
        #expect(tail == "recomputed it from the clock window.")
    }

    @Test func aListOfLongClaimsIsClaims() throws {
        #expect(NoteProse.shape(of: learned) == .claims)
        let split = try #require(NoteProse.claimBreak(learned[0]))
        let claim = String(learned[0].prefix(split.head))
        #expect(claim.hasSuffix("other processes"))
        #expect(split.lead == "so ")
    }

    @Test func shortBulletsStayPlain() {
        // A card's list, not a document's: splitting these reads as a stutter.
        #expect(NoteProse.shape(of: ["Relations take a gap", "Operators take a space"])
            == .plain)
    }

    @Test func aBreakTooEarlyIsNotAClaim() {
        // "Fixed; " at character 5 is punctuation, not a claim and its reason.
        #expect(NoteProse.claimBreak(
            "Fixed; the analyzer now writes the note before it indexes the file.") == nil)
    }

    @Test func aLoneItemIsNeverAShape() {
        #expect(NoteProse.shape(of: [problems[0]]) == .plain)
    }

    @Test func theContractHeadingsDeclareTheirShape() {
        // One straying bullet — or a lone one — degrades a row, not the
        // section: the §2.1 heading already said what the list is.
        #expect(NoteProse.shape(
            of: problems + ["Still chasing the unlock race."],
            under: "Problems → fixes") == .pairs)
        #expect(NoteProse.shape(of: [problems[0]], under: "Problems → fixes") == .pairs)
        #expect(NoteProse.shape(
            of: learned + ["Short one."], under: "Learned / decided") == .claims)
        #expect(NoteProse.shape(of: [learned[0]], under: "Learned / decided") == .claims)
    }

    @Test func aHeadingCannotForcePairsOntoArrowlessBullets() {
        // The section the model filled with plain sentences: no bullet bears
        // the heading's shape out, so the sentences win.
        #expect(NoteProse.shape(
            of: ["Nothing broke today.", "The build stayed green."],
            under: "Problems → fixes") == .plain)
    }

    @Test func otherHeadingsLeaveTheGrammarInCharge() {
        #expect(NoteProse.shape(of: problems, under: "Open questions") == .pairs)
        #expect(NoteProse.shape(
            of: ["Relations take a gap", "Operators take a space"],
            under: "Open questions") == .plain)
    }

    @Test func wikiLinksAreTheirOwnKind() {
        let lines = NoteProse.lines("## Captured\n- [[Due-cards load-ahead band]]\n- [[Qwen]]")
        #expect(lines[1].kind == .link(target: "Due-cards load-ahead band"))
        #expect(lines[2].kind == .link(target: "Qwen"))
    }
}

@Suite struct NoteProseDayTests {
    private let stretches = [
        NoteProse.Span(start: "00:00", end: "01:06"),
        NoteProse.Span(start: "01:38", end: "02:17"),
        NoteProse.Span(start: "02:46", end: "03:27"),
        NoteProse.Span(start: "09:44", end: "10:39")
    ]

    @Test func theTitleIsTheSummarysSecondHalf() {
        #expect(NoteProse.dayTitle(
            "claudefordesktop, app — researching AI harness building; developing Shifu app")
            == "Researching AI harness building · developing Shifu app")
    }

    @Test func aSummaryWithNoSourcesIsItsOwnTitle() {
        #expect(NoteProse.dayTitle("debugging capture daemon") == "Debugging capture daemon")
    }

    @Test func aDayTheClassifierNeverNamedHasNoTitle() {
        // The whole line is the sources, which the head already sets as chips.
        #expect(NoteProse.dayTitle("ghostty, claudefordesktop",
                                   sources: ["ghostty", "claudefordesktop"]) == "")
        #expect(NoteProse.dayTitle("ghostty — debugging", sources: ["ghostty"])
            == "Debugging")
    }

    @Test func theBracketIsTheOuterEdgeOfTheDay() {
        #expect(NoteProse.bracket(stretches) == "00:00→10:39")
        #expect(NoteProse.bracket([]) == nil)
    }

    @Test func aMergedLeadStillBracketsItsStretch() {
        #expect(NoteProse.span("13:10–13:12, 14:38–14:40")
            == NoteProse.Span(start: "13:10", end: "14:40"))
        #expect(NoteProse.Span(start: "09:44", end: "10:39").minutes == 584..<639)
    }

    @Test func aBlockKnowsHowManyStretchesItCovers() {
        let prose = """
        **00:00–03:27** — Resumed work through the CLI.

        **09:44–10:39** — Built the forecast band.
        """
        let blocks = NoteProse.sessionBlocks(prose, covering: stretches)
        #expect(blocks.count == 2)
        #expect(blocks[0].span == NoteProse.Span(start: "00:00", end: "03:27"))
        #expect(blocks[0].covers.count == 3)
        #expect(blocks[1].covers.count == 1)
        #expect(blocks[1].text == "Built the forecast band.")
    }
}

@Suite struct NoteProseInlineTests {
    /// The renderer's own parser, so these assert what the screen shows.
    private func rendered(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: NoteProse.inlineSafe(text),
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    /// Inline Markdown records a strikethrough as a presentation intent.
    private func isStruck(_ attributed: AttributedString) -> Bool {
        attributed.runs.contains(where: {
            $0.inlinePresentationIntent?.contains(.strikethrough) ?? false
        })
    }

    @Test func approximatelySignsAreNotStrikethrough() {
        let text = "downloads at ~3.8 GB instead of ~10 GB"
        let attributed = rendered(text)
        #expect(String(attributed.characters) == text)
        #expect(!isStruck(attributed))
    }

    @Test func realStrikethroughStillStrikes() {
        let attributed = rendered("the ~~old~~ new plan")
        #expect(String(attributed.characters) == "the old new plan")
        #expect(isStruck(attributed))
    }

    @Test func wikiLinkBracketsComeOff() {
        #expect(NoteProse.inlineSafe("- [[31-shifu-development]]")
            == "- 31-shifu-development")
    }

    @Test func textWithoutEitherShapeIsUntouched() {
        let text = "Nothing to escape here — **bold** and `code` are fine."
        #expect(NoteProse.inlineSafe(text) == text)
    }
}
