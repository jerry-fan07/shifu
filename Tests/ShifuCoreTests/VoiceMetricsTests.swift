import Foundation
import Testing
@testable import ShifuCore

/// The measured half of a voice profile (voice.md §3.1). Every claim here is
/// about a fixed string, because that is the whole point of this half: it is
/// the part of the profile that can be wrong in a way a test can catch.
@Suite struct VoiceMetricsTests {
    /// Two hundred-ish words with deliberate habits: em dashes, no semicolons,
    /// contractions throughout, first person, no intensifiers.
    private let dashy = """
        I don't think we should ship this on Friday — the migration hasn't been run \
        against a real database yet, and I'd rather find out on Monday. Here's what I'd \
        do instead.

        Cut the release to the two changes that are already verified. That's the search \
        fix and the crash on launch. Everything else can wait a week — nothing in it is \
        urgent, whatever the ticket says.

        I'll take the migration myself over the weekend if it helps. It's a couple of \
        hours of work and I'd rather own it than hand someone a half-finished branch on \
        Monday morning. Let me know either way and I'll start tonight.
        """

    /// The same content in a stiffer register: no contractions, semicolons,
    /// third person, hedged, and bulleted.
    private let formal = """
        The proposed release date of Friday appears premature; the migration has not \
        yet been executed against a production database. It is possible that the \
        following approach would be preferable.

        - Reduce the release to the changes which have already been verified.
        - Defer the remaining items by approximately one week.
        - Reassign the migration to an engineer with available capacity.

        The remaining items are, arguably, not urgent; the ticket may somewhat \
        overstate their importance. A decision would be appreciated by Monday.
        """

    // MARK: - Shape

    @Test func countsSentencesParagraphsAndWords() {
        let metrics = VoiceMetrics.measure([dashy])
        #expect(metrics.paragraphs == 3)
        #expect(metrics.sentences >= 8)
        #expect(metrics.words > 100)
        #expect(metrics.medianSentenceWords > 0)
        #expect(metrics.longestSentenceWords >= metrics.medianSentenceWords)
    }

    @Test func aParagraphWithNoTerminalPunctuationIsOneSentence() {
        // Headings and bullets never end in a full stop, and counting them as
        // zero sentences would drag every average toward the prose around them.
        #expect(VoiceMetrics.sentences(in: "## Register").count == 1)
        #expect(VoiceMetrics.sentences(in: "- one item").count == 1)
        #expect(VoiceMetrics.sentences(in: "Two. Sentences here.").count == 2)
    }

    @Test func emptyCorpusMeasuresNothingRatherThanDividingByZero() {
        let metrics = VoiceMetrics.measure([])
        #expect(metrics.words == 0)
        #expect(metrics.medianSentenceWords == 0)
        #expect(metrics.averageWordLength == 0)
        #expect(metrics.readings.isEmpty)
        #expect(metrics.rules().isEmpty)
    }

    // MARK: - The habits that separate two writers

    @Test func punctuationHabitsSeparateTheTwoRegisters() {
        let loose = VoiceMetrics.measure([dashy])
        let stiff = VoiceMetrics.measure([formal])
        #expect(loose.emDashRate > 0)
        #expect(loose.semicolonRate == 0)
        #expect(stiff.semicolonRate > 0)
        #expect(stiff.emDashRate == 0)
    }

    @Test func contractionAndPersonRatesSeparateTheTwoRegisters() {
        let loose = VoiceMetrics.measure([dashy])
        let stiff = VoiceMetrics.measure([formal])
        #expect(loose.contractionRate > stiff.contractionRate)
        #expect(loose.firstPersonRate > stiff.firstPersonRate)
        #expect(stiff.firstPersonRate == 0)
    }

    @Test func plainPastTenseIsNotFirstPerson() {
        // stripped("we're") is "were", and matching person on stripped forms
        // counted every past tense as the writer talking about themselves —
        // inflating the rate for exactly the detached writer the
        // "keeps themselves out of it" rule exists for.
        let detached = "The tests were red for a week. The fixes were ill advised, "
            + "and the id column stayed. Nothing about the rollout was theirs."
        #expect(VoiceMetrics.measure([detached]).firstPersonRate == 0)
        // The real contractions still count, curly apostrophe included.
        let owned = "We're behind, and I'll say so. I\u{2019}d rather we've all seen it."
        #expect(VoiceMetrics.measure([owned]).firstPersonRate > 0)
    }

    @Test func hedgesAndListsAreCounted() {
        let stiff = VoiceMetrics.measure([formal])
        #expect(stiff.hedgeRate > 0)          // "possibly", "arguably", "somewhat"
        #expect(stiff.listLinePercent > 10)
        let loose = VoiceMetrics.measure([dashy])
        #expect(loose.listLinePercent == 0)
    }

    @Test func ellipsesAreNotAlsoCountedAsFullStops() {
        // The order the punctuation pass runs in: "..." is one ellipsis, and
        // three sentence terminators would have split the line into four.
        let metrics = VoiceMetrics.measure(["Well... it depends on the day."])
        #expect(metrics.ellipsisRate > 0)
        #expect(metrics.sentences == 2)
    }

    @Test func rankingIsStableForTheSameCorpus() {
        // A profile that reshuffles between two rebuilds of the same corpus
        // reads as though the corpus changed.
        let first = VoiceMetrics.measure([dashy, formal])
        let second = VoiceMetrics.measure([dashy, formal])
        #expect(first.openers == second.openers)
        #expect(first.vocabulary == second.vocabulary)
        #expect(first == second)
    }

    // MARK: - Rules (voice.md §3.1, the floor)

    @Test func rulesAreEmptyBelowBothFloors() {
        let metrics = VoiceMetrics.measure([dashy])
        #expect(metrics.words < VoiceMetrics.meaningfulWords)
        #expect(metrics.sentences < VoiceMetrics.rhythmSentences)
        #expect(!metrics.isMeaningful)
        // Readings still render — the page shows what it measured. Only the
        // prompt lines are withheld, because those are stated as facts.
        #expect(!metrics.readings.isEmpty)
        #expect(metrics.rules().isEmpty)
    }

    /// `words` words, one sentence. Lets a fixture hit an exact length
    /// distribution instead of hoping prose lands on one.
    private func sentence(_ words: Int) -> String {
        Array(repeating: "word", count: words).joined(separator: " ") + "."
    }

    @Test func rhythmRulesRideALowerFloorThanAbsenceClaims() {
        // The two floors ask different questions. A spread is estimable from
        // twenty sentences; "they never use semicolons" needs a whole corpus.
        // Before the split, a 300-word corpus was told nothing at all.
        //
        // Which floor binds first depends on the writer: at nine words a
        // sentence, twenty sentences arrive well under 400 words. `dashy`'s
        // 24-word sentences reach the word floor first, which is why this
        // fixture is generated rather than borrowed.
        let brisk = (0..<24).map { _ in sentence(9) }.joined(separator: " ")
        let metrics = VoiceMetrics.measure([brisk])
        #expect(metrics.words < VoiceMetrics.meaningfulWords)
        #expect(!metrics.isMeaningful)
        #expect(metrics.sentences >= VoiceMetrics.rhythmSentences)
        let joined = metrics.rules().joined(separator: "\n")
        #expect(joined.contains("distribution"))
        // …and nothing that needs the whole corpus. The tells line rides the
        // word floor too: "appear nowhere in their writing" is an absence
        // claim, however short the sentences that failed to contain them.
        #expect(!joined.contains("semicolons"))
        #expect(!joined.contains("per 1,000 words"))
        #expect(!joined.contains("machine-written"))
    }

    @Test func rulesCarryNumbersOnceTheCorpusClearsTheFloor() {
        let metrics = VoiceMetrics.measure(Array(repeating: dashy, count: 4))
        #expect(metrics.isMeaningful)
        let rules = metrics.rules()
        #expect(rules.count > 4)
        let joined = rules.joined(separator: "\n")
        #expect(joined.contains("median \(metrics.medianSentenceWords)"))
        #expect(joined.contains("shortest \(metrics.shortestSentenceWords)"))
        #expect(joined.contains("longest \(metrics.longestSentenceWords) words"))
        // The absences are stated too — "never use semicolons" is the half of
        // a voice that a description always leaves out.
        #expect(joined.contains("semicolons"))
    }

    /// The regression guard for this design's worst defect. The first version
    /// stated one number and then asked for uniformity around it — "keep most
    /// sentences near the median" — which is the single thing that makes prose
    /// read as machine-written. It was found empirically: personalized drafts
    /// tripped an AI detector while the samples they were built from did not.
    @Test func rulesNeverAskForUniformity() {
        let rules = VoiceMetrics.measure(Array(repeating: dashy, count: 4))
            .rules().joined(separator: "\n").lowercased()
        #expect(!rules.contains("near the median"))
        #expect(!rules.contains("keep most sentences"))
        // And they say the opposite, in as many words.
        #expect(rules.contains("not a target"))
        #expect(rules.contains("do not settle into a steady cadence"))
    }

    // MARK: - Rhythm (the spread, not the centre)

    @Test func spreadAndBurstinessSeparateTwoWritersWithTheSameMedian() {
        // The case median-and-mean cannot see, and the reason these metrics
        // exist: the *same* median, a completely different reading experience.
        // Both corpora are built to median 12 exactly — thirty sentences of
        // twelve words against ten each of four, twenty-four and twelve.
        let even = (0..<30).map { _ in sentence(12) }.joined(separator: " ")
        let bursty = (0..<10)
            .flatMap { _ in [sentence(4), sentence(24), sentence(12)] }
            .joined(separator: " ")

        let flat = VoiceMetrics.measure([even])
        let varied = VoiceMetrics.measure([bursty])
        #expect(flat.medianSentenceWords == varied.medianSentenceWords)
        #expect(flat.sentences == varied.sentences)
        // Same centre, and everything about the shape different.
        #expect(varied.sentenceLengthVariation > flat.sentenceLengthVariation)
        #expect(varied.adjacentSentenceGap > flat.adjacentSentenceGap)
        #expect(flat.sentenceLengthVariation == 0)  // every sentence identical
        #expect(flat.adjacentSentenceGap == 0)
        #expect(varied.shortSentencePercent > flat.shortSentencePercent)
        // And the prompts they produce differ in the numbers, not just the prose.
        #expect(!varied.rules().joined().contains("shortest 12"))
        #expect(flat.rules().joined().contains("shortest 12"))
    }

    @Test func theAdjacentGapIsNeverMeasuredAcrossTwoSamples() {
        // A jump from the end of one piece of writing to the start of another
        // is not a transition the author wrote.
        let short = "Yes. No. Fine."
        let long = "The team shipped the migration to production on Monday after a "
            + "weekend of measuring the index rebuild twice on a spare box."
        let pooled = VoiceMetrics.measure([short, long])
        let joined = VoiceMetrics.measure([short + " " + long])
        #expect(pooled.sentences == joined.sentences)
        #expect(pooled.adjacentSentenceGap < joined.adjacentSentenceGap)
    }

    @Test func aShortSentenceHabitIsOnlyClaimedWhenItIsReal() {
        // Measured on the real dogfood corpus: the ≤6-word "sentences" were
        // list markers ("4."), stranded punctuation, a title block and a run of
        // CJK — 7% of the total. After filtering, 0.9%. Claiming that habit
        // would have invented it.
        let withFurniture = """
            1. The first point runs to a reasonable length and finishes properly here.
            2. The second point also runs to a reasonable length and finishes here.
            3. The third point does the same thing again, at the same sort of length.

            Title Block
            Jerry Fan
            April 2026
            """
        let metrics = VoiceMetrics.measure([withFurniture])
        #expect(metrics.shortestSentenceWords >= 8)
        #expect(metrics.shortSentencePercent == 0)
        #expect(!metrics.rules().joined().contains("words or fewer"))
    }

    @Test func aBareNumberIsNotASentence() {
        // "4." ended a sentence and started another, which is what made list
        // markers register as one-word sentences.
        #expect(VoiceMetrics.sentences(in: "4. Read the paper before Friday.").count == 1)
        #expect(VoiceMetrics.sentences(in: "It costs 3.14 dollars each.").count == 1)
        #expect(VoiceMetrics.sentences(in: "Stop. Read it.").count == 2)
    }

    @Test func strandedPunctuationAndTitleLinesAreNotProse() {
        #expect(VoiceMetrics.proseSentences(in: ".").isEmpty)
        #expect(VoiceMetrics.proseSentences(in: ".”").isEmpty)
        #expect(VoiceMetrics.proseSentences(in: "UTA Application").isEmpty)
        // Whitespace-splitting counts a CJK run as one word; it is not a
        // one-word sentence habit.
        #expect(VoiceMetrics.proseSentences(in: "学好数理化,走遍天下都不怕").isEmpty)
        // But a real short sentence survives, terminator and all.
        #expect(VoiceMetrics.proseSentences(in: "Not Friday.").count == 1)
        #expect(VoiceMetrics.proseSentences(in: "Why is this true?").count == 1)
    }

    // MARK: - Machine tells

    @Test func proscribesTellsTheCorpusDoesNotUse() {
        let metrics = VoiceMetrics.measure(Array(repeating: dashy, count: 4))
        #expect(metrics.absentTells.contains("delve"))
        #expect(metrics.absentTells.contains("it's important to note"))
        #expect(metrics.rules().joined(separator: "\n").contains("read as machine-written"))
    }

    @Test func keepsATellTheWriterActuallyUses() {
        // The corpus check is a safety valve: proscribing a word someone really
        // says would be the profile arguing with its own samples.
        let fond = Array(repeating: dashy, count: 4)
            + ["Moreover, the robust approach is to measure it. Moreover again."]
        let metrics = VoiceMetrics.measure(fond)
        #expect(!metrics.absentTells.contains("moreover"))
        #expect(!metrics.absentTells.contains("robust"))
        #expect(metrics.absentTells.contains("delve"))
    }

    @Test func aFormalCorpusIsToldNotToContract() {
        let metrics = VoiceMetrics.measure(Array(repeating: formal, count: 5))
        let joined = metrics.rules().joined(separator: "\n")
        #expect(joined.contains("do not\", \"it is"))
    }
}
