import Foundation
import Testing
@testable import ShifuCore

/// Turning a laid-out document's text layer back into prose (voice.md §2.2).
///
/// Every assertion here is ultimately about a *metric*: the reason page numbers
/// are dropped is that twenty of them are twenty one-word sentences, and the
/// median sentence length is the number the drafting prompt tells the model to
/// aim at. So the suite checks the cleanup and then checks that `VoiceMetrics`
/// reads the result as prose.
@Suite struct VoiceImportTextTests {
    /// One page of a hard-wrapped document, running head and page number
    /// included, with a word hyphenated across a line end.
    /// Bodies vary per page, as a real document's do. That matters: the
    /// running-head detector works by finding what repeats *while the body
    /// changes*, and a fixture of identical pages would test a situation that
    /// cannot occur.
    private func page(_ number: Int, head: String = "The Quarterly Report") -> String {
        """
        \(head)

        Section \(number) ran clean on the copy, which does not tell us much because
        the copy has forty thousand rows and production has eleven million rows
        in the same table. What I want to know before Friday is how long the migra-
        tion takes on the real thing.

        Nobody has measured it.

        \(number)
        """
    }

    // MARK: - Wrapped lines

    @Test func rejoinsWrappedLinesIntoParagraphs() {
        let prose = VoiceImportText.prose(pages: [page(1)])
        // Four visual lines became one sentence-bearing paragraph.
        #expect(prose.contains("does not tell us much because the copy has"))
        #expect(!prose.contains("because\nthe copy"))
    }

    @Test func closesTheHyphenTheTypesetterOpened() {
        let prose = VoiceImportText.prose(pages: [page(1)])
        #expect(prose.contains("migration takes on the real thing"))
        #expect(!prose.contains("migra-"))
        #expect(!prose.contains("migra tion"))
    }

    @Test func keepsAHyphenThatBelongsToTheWriter() {
        // "spare-box" is the author's compound, not a line break — the next
        // line starting uppercase is what tells them apart.
        let lines = ["I would rather use the spare-", "Box tonight."]
        #expect(VoiceImportText.reflow(lines).contains("spare-"))
    }

    @Test func aBlankLineIsAParagraphBreak() {
        let prose = VoiceImportText.prose(pages: [page(1)])
        #expect(prose.contains("\n\nNobody has measured it."))
    }

    @Test func aShortLineEndingASentenceClosesTheParagraph() {
        let lines = [
            "The migration ran clean on the copy, which does not tell us much at all",
            "because the copy has forty thousand rows and production has eleven",
            "million rows.",
            "Nobody has measured the rebuild on production, and nobody has asked to."
        ]
        let paragraphs = VoiceImportText.reflow(lines).components(separatedBy: "\n\n")
        #expect(paragraphs.count == 2)
        #expect(paragraphs[0].hasSuffix("million rows."))
    }

    @Test func doesNotBreakOnASentenceThatEndsAtTheMargin() {
        // A full-width line that happens to end in a full stop is a wrap, not
        // a paragraph — breaking there would halve every long paragraph.
        let lines = [
            "The migration ran clean on the copy, which does not tell us much.",
            "Production has eleven million rows and nobody has measured it yet.",
            "That is the number that decides whether Friday happens or not now."
        ]
        #expect(!VoiceImportText.reflow(lines).contains("\n\n"))
    }

    @Test func aBulletStartsItsOwnBlock() {
        let lines = ["Here is what I would do instead, in order of preference:",
                     "- Drop to the standard plan in September.",
                     "- Keep retention where it is for the API services."]
        let paragraphs = VoiceImportText.reflow(lines).components(separatedBy: "\n\n")
        #expect(paragraphs.count == 3)
    }

    // MARK: - Furniture

    @Test func dropsPageNumbersHoweverTheyAreDecorated() {
        for artifact in ["3", "12", "— 3 —", "[7]", "· 4 ·", "Page 3", "Page 3 of 12",
                         "3 of 12", "iv", "xvii", "***"] {
            #expect(VoiceImportText.isPageArtifact(artifact), "should drop \(artifact)")
        }
    }

    @Test func keepsLinesThatOnlyLookLikeFurniture() {
        // Roman numerals are spelled from ordinary letters, which is why they
        // are an explicit list rather than a charset test.
        for real in ["mix", "did", "civic", "I", "2026 was the year", "No.",
                     "Nobody has measured it."] {
            #expect(!VoiceImportText.isPageArtifact(real), "should keep \(real)")
        }
    }

    @Test func dropsARunningHeadOnceItRepeats() {
        let prose = VoiceImportText.prose(pages: (1...4).map { page($0) })
        #expect(!prose.contains("The Quarterly Report"))
        #expect(prose.contains("Nobody has measured it."))
    }

    @Test func keepsAHeadingThatAppearsOnOnlyOnePage() {
        // Two pages is not a pattern; dropping real prose is the worse error.
        let prose = VoiceImportText.prose(pages: [page(1), page(2, head: "Something Else")])
        #expect(prose.contains("The Quarterly Report"))
        #expect(prose.contains("Something Else"))
    }

    @Test func aSentenceSplitAcrossAPageBreakRejoins() {
        // The running head that sat between its halves is gone by then, so the
        // two halves are adjacent lines and reflow closes them.
        let pages = (1...3).map { number in
            """
            Running Head

            \(number == 1 ? "The migration ran clean on the copy, which does not tell us"
                           : "much at all, because the copy has forty thousand rows here.")

            \(number)
            """
        }
        let prose = VoiceImportText.prose(pages: pages)
        #expect(prose.contains("does not tell us much at all"))
    }

    // MARK: - Ligatures

    @Test func normalizesLigaturesSoWordsMatchThemselves() {
        let prose = VoiceImportText.prose(pages: ["I \u{FB01}nished the \u{FB02}ight report."])
        #expect(prose.contains("finished"))
        #expect(prose.contains("flight"))
        #expect(!prose.contains("\u{FB01}"))
    }

    @Test func leavesTheTwoHabitsThatMatterAlone() {
        // NFKC has no decomposition for the em dash or the curly apostrophe,
        // and both are load-bearing metrics — this pins that.
        let prose = VoiceImportText.prose(pages: ["Not Friday \u{2014} it\u{2019}s not ready."])
        #expect(prose.contains("\u{2014}"))
        #expect(prose.contains("\u{2019}"))
    }

    // MARK: - What the metrics then see

    @Test func theCleanedTextMeasuresAsProseNotAsALayout() {
        let pages = (1...6).map { page($0) }
        let dirty = VoiceMetrics.measure([pages.joined(separator: "\n")])
        let clean = VoiceMetrics.measure([VoiceImportText.prose(pages: pages)])

        // Measured, and narrower than this test first claimed. Two things turn
        // out *not* to need the reflow:
        //
        //  - hard wrapping never confused the sentence split, because a single
        //    "\n" is ordinary whitespace inside a paragraph and the split is on
        //    punctuation;
        //  - page numbers and running heads are kept out of the length
        //    statistics by `VoiceMetrics.proseSentences` regardless.
        //
        // So the sentence-length numbers come out the same either way — belt
        // and braces, and worth knowing rather than asserting a difference that
        // isn't there. What the reflow alone still buys is paragraph structure,
        // closed hyphens, and furniture never entering the corpus as *words*
        // (where it would skew vocabulary, word length and every per-1k rate).
        #expect(clean.paragraphs < dirty.paragraphs)
        #expect(clean.words < dirty.words)
        // Nothing the typesetter added reaches the vocabulary: not the running
        // head, and not either half of a hyphenated word.
        #expect(!clean.vocabulary.contains("quarterly"))
        #expect(!clean.vocabulary.contains("report"))
        // (That the whole word survives is asserted on the prose itself in
        // `closesTheHyphenTheTypesetterOpened` — the top-8 vocabulary list is
        // crowded by this fixture's repetition and is the wrong place to ask.)
        #expect(!clean.vocabulary.contains("migra"))
    }

    @Test func emptyInputYieldsEmptyOutput() {
        #expect(VoiceImportText.prose(pages: []).isEmpty)
        #expect(VoiceImportText.prose(pages: ["", "  ", "\n\n"]).isEmpty)
        // A text layer of nothing but furniture leaves nothing — which is what
        // `VoicePDF` reports as "no text layer".
        #expect(VoiceImportText.prose(pages: ["1", "2", "3"]).isEmpty)
    }
}
