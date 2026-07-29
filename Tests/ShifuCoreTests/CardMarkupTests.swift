import Foundation
import Testing
@testable import ShifuCore

@Suite struct CardMarkupSegmentTests {
    @Test func plainTextIsOneSegment() {
        #expect(CardMarkup.segments("just words") == [.text("just words")])
    }

    @Test func inlineMathSplitsOut() {
        let segments = CardMarkup.segments("Euler: $e^{i\\pi} = -1$ holds.")
        #expect(segments.count == 3)
        #expect(segments[0] == .text("Euler: "))
        guard case .inlineMath = segments[1] else {
            Issue.record("expected inline math, got \(segments[1])")
            return
        }
        #expect(segments[2] == .text(" holds."))
    }

    @Test func pricesAreNotMath() {
        // "$5 and $10" — closer trailed by a digit / opener touching space.
        #expect(CardMarkup.segments("costs $5 and $10 today")
            == [.text("costs $5 and $10 today")])
    }

    @Test func escapedDollarStaysLiteral() {
        #expect(CardMarkup.segments("pay \\$20") == [.text("pay $20")])
    }

    @Test func unterminatedDollarStaysLiteral() {
        #expect(CardMarkup.segments("worth $100") == [.text("worth $100")])
    }

    @Test func displayMathViaDoubleDollarsAndBrackets() {
        for text in ["$$x^2$$", "\\[x^2\\]"] {
            let segments = CardMarkup.segments(text)
            guard case .displayMath(let runs) = segments.first else {
                Issue.record("expected display math for \(text)")
                return
            }
            #expect(runs == [
                CardMarkup.MathRun("x"),
                CardMarkup.MathRun("2", script: .raised, style: .upright)
            ])
        }
    }

    @Test func parenDelimitersAreInlineMath() {
        let segments = CardMarkup.segments("so \\(a_1\\) wins")
        guard case .inlineMath(let runs) = segments[1] else {
            Issue.record("expected inline math")
            return
        }
        #expect(runs == [
            CardMarkup.MathRun("a"),
            CardMarkup.MathRun("1", script: .lowered, style: .upright)
        ])
    }

    @Test func inlineCodeSplitsOut() {
        let segments = CardMarkup.segments("call `fetchAll(db)` here")
        #expect(segments == [
            .text("call "), .inlineCode("fetchAll(db)"), .text(" here")
        ])
    }

    @Test func fencedCodeBlockKeepsLanguageAndBody() {
        let text = "Before.\n```swift\nlet x = 1\nprint(x)\n```\nAfter."
        let segments = CardMarkup.segments(text)
        #expect(segments == [
            .text("Before."),
            .codeBlock(code: "let x = 1\nprint(x)", language: "swift"),
            .text("After.")
        ])
    }

    /// A block owns its line, so the newlines that put it there aren't text —
    /// left in they render as an empty paragraph above and a blank line below.
    @Test func blockAbsorbsTheNewlinesAroundIt() {
        #expect(CardMarkup.segments("Given:\n$$x^2$$\nsolve.") == [
            .text("Given:"),
            .displayMath([CardMarkup.MathRun("x"),
                          CardMarkup.MathRun("2", script: .raised, style: .upright)]),
            .text("solve.")
        ])
    }

    @Test func displayMathTrimsItsOwnPadding() {
        #expect(CardMarkup.segments("$$\n  E = m\n$$")
            == [.displayMath(CardMarkup.mathRuns("E = m"))])
    }

    @Test func dollarInsideFenceIsNotMath() {
        let text = "```sh\necho $HOME and $PATH\n```"
        #expect(CardMarkup.segments(text)
            == [.codeBlock(code: "echo $HOME and $PATH", language: "sh")])
    }

    @Test func unterminatedFenceRunsToEnd() {
        // CommonMark: an unclosed fence is code to the end of the text, so
        // the editor preview shows a block as soon as the fence opens.
        #expect(CardMarkup.segments("```swift\nno close")
            == [.codeBlock(code: "no close", language: "swift")])
    }
}

@Suite struct CardMarkupMathTests {
    /// Convenience for the shape assertions: what the runs spell out, ignoring
    /// where the style boundaries fall.
    private func text(_ latex: String) -> String {
        CardMarkup.mathRuns(latex).map(\.text).joined()
    }

    @Test func greekAndOperatorsBecomeUnicode() {
        #expect(text("\\alpha \\times \\beta \\le \\infty") == "α × β ≤ ∞")
        #expect(text("\\top \\bot \\preceq \\bigcup \\varepsilon") == "⊤ ⊥ ⪯ ⋃ ε")
    }

    @Test func superAndSubscriptsBecomeScriptRuns() {
        #expect(CardMarkup.mathRuns("x^2") == [
            CardMarkup.MathRun("x"),
            CardMarkup.MathRun("2", script: .raised, style: .upright)
        ])
        #expect(CardMarkup.mathRuns("a_{ij}") == [
            CardMarkup.MathRun("a"),
            CardMarkup.MathRun("ij", script: .lowered)
        ])
    }

    /// TeX's default math italic: letters lean, everything else stands up.
    @Test func variablesLeanWhileTheRestStandsUpright() {
        #expect(CardMarkup.mathRuns("2x + 1") == [
            CardMarkup.MathRun("2", style: .upright),
            CardMarkup.MathRun("x"),
            CardMarkup.MathRun(" + 1", style: .upright)
        ])
        // Function names and \text are words, not products of variables.
        #expect(CardMarkup.mathRuns("\\cos\\theta") == [
            CardMarkup.MathRun("cos", style: .upright),
            CardMarkup.MathRun("θ")
        ])
        #expect(CardMarkup.mathRuns("\\Sigma") == [CardMarkup.MathRun("Σ", style: .upright)])
    }

    @Test func fractionRaisesNumeratorLowersDenominator() {
        #expect(CardMarkup.mathRuns("\\frac{a+b}{2}") == [
            CardMarkup.MathRun("a", script: .raised),
            // Hair-thin, not thin: the numerator is set at script size.
            CardMarkup.MathRun("\u{200A}+\u{200A}", script: .raised, style: .upright),
            CardMarkup.MathRun("b", script: .raised),
            CardMarkup.MathRun("⁄", style: .upright),
            CardMarkup.MathRun("2", script: .lowered, style: .upright)
        ])
        #expect(text("\\dfrac{1}{2}") == "1⁄2")   // \dfrac and \tfrac are \frac
    }

    /// There's no room to build a fraction up inside an exponent, so it
    /// collapses inline rather than dropping the denominator below the script.
    @Test func fractionInsideAScriptStaysOnOneLevel() {
        let runs = CardMarkup.mathRuns("x^{\\frac{1}{2}}")
        #expect(runs.map(\.text).joined() == "x1⁄2")
        #expect(runs.dropFirst().allSatisfy { $0.script == .raised })
    }

    @Test func sqrtWrapsMultiGlyphRadicands() {
        #expect(text("\\sqrt{2}") == "√2")
        #expect(text("\\sqrt{x+1}") == "√(x\u{2009}+\u{2009}1)")
        #expect(text("\\sqrt{\\alpha}") == "√α")   // one glyph after conversion
        #expect(text("\\sqrt[3]{x}") == "√x")      // the index is dropped, not shown
    }

    @Test func textCommandAndBracesPassThrough() {
        #expect(CardMarkup.mathRuns("\\text{iff } {x}") == [
            CardMarkup.MathRun("iff  ", style: .upright),
            CardMarkup.MathRun("x")
        ])
    }

    /// The alphabets carry meaning — ℝ is not the variable R — so they map to
    /// their Unicode letters instead of leaking the command name.
    @Test func mathAlphabetsBecomeTheirUnicodeLetters() {
        #expect(text("\\mathbb{R}^n") == "ℝn")
        #expect(text("\\mathbb{A}") == "𝔸")        // no BMP form; block arithmetic
        #expect(text("\\mathbf{1}") == "𝟏")
        #expect(text("\\mathcal{L}") == "ℒ")
        #expect(text("\\mathrm{d}x") == "dx")
    }

    @Test func accentsComposeOntoTheirBase() {
        #expect(text("\\vec{v}") == "v\u{20D7}")
        #expect(text("\\hat{\\beta}") == "β\u{0302}")
        #expect(text("\\overline{AB}") == "A\u{0304}B\u{0304}")
    }

    @Test func environmentsBecomeDelimitersNotCommandNames() {
        #expect(text("\\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix}")
            == "( a   b \n c   d )")
        #expect(text("\\begin{aligned} x &= 1 \\end{aligned}") == "x  = 1")
        #expect(text("\\begin{bmatrix} 1 \\end{bmatrix}") == "[ 1 ]")
    }

    @Test func sizingAndSpacingHintsLeaveNoResidue() {
        #expect(text("\\left( x \\right)") == "( x )")
        #expect(text("\\Bigl( x \\Bigr)") == "( x )")
        #expect(text("\\phantom{xyz}a") == "a")
    }

    @Test func unknownCommandDegradesToItsName() {
        #expect(CardMarkup.mathRuns("\\mystery") == [CardMarkup.MathRun("mystery")])
    }
}

/// TeX spaces a formula by what its symbols *are*, not by what the author
/// typed — the reason typeset math reads better than the same characters
/// dropped into a sentence. Models type math with wildly uneven spacing, so
/// the renderer can't inherit theirs.
@Suite struct CardMarkupSpacingTests {
    private let relation = "\u{2005}"
    private let binary = "\u{2009}"
    private let italic = "\u{200A}"

    private func text(_ latex: String) -> String {
        CardMarkup.mathRuns(latex).map(\.text).joined()
    }

    @Test func relationsGetAWiderGapThanBinaryOperators() {
        #expect(text("a=b") == "a\(relation)=\(relation)b")
        #expect(text("a+b") == "a\(binary)+\(binary)b")
        #expect(text("x\\ge0") == "x\(relation)≥\(relation)0")
    }

    /// Without this the bars weld onto the x — the defect that started this.
    @Test func italicGlyphGetsACorrectionBeforeAnUprightOne() {
        #expect(text("c\\|x\\|") == "c\(italic)‖x\(italic)‖")
        #expect(text("f(x)") == "f\(italic)(x\(italic))")
    }

    /// A superscript sits above its base, so there's nothing to collide with.
    @Test func scriptsNeedNoItalicCorrection() {
        #expect(text("x^2") == "x2")
        #expect(text("a_i") == "ai")
    }

    /// Punctuation hugs what it follows; TeX adds nothing before a comma.
    @Test func punctuationHugsTheVariableBeforeIt() {
        #expect(text("f(x, y)") == "f\(italic)(x, y\(italic))")
    }

    @Test func authorsOwnSpacingIsNeverDoubled() {
        #expect(text("a = b") == "a = b")
        #expect(text("\\alpha \\times \\beta") == "α × β")
    }

    /// "−1" opens a formula with a sign, "a − 1" joins two operands.
    @Test func signIsNotSpacedLikeABinaryOperator() {
        #expect(text("-1") == "−1")
        #expect(text("R-1") == "R\(binary)−\(binary)1")
        #expect(text("x^{-1}") == "x−1")   // dropping into a script starts over
        #expect(text("a^2+b^2") == "a2\(binary)+\(binary)b2")   // climbing out doesn't
    }

    /// TeX measures its gaps in units that shrink with the math size, so a
    /// subscript set at 72% doesn't get full-size spacing around it.
    @Test func scriptSpacingIsTighterThanTheBaseline() {
        #expect(text("x_{i=1}") == "xi\(binary)=\(binary)1")
        #expect(text("a+b") == "a\(binary)+\(binary)b")
    }

    /// `\text` is prose: its hyphens aren't minus signs and its spaces are
    /// the author's own.
    @Test func literalTextIsLeftExactlyAsWritten() {
        #expect(text("\\text{well-known if }x") == "well-known if x")
    }

    /// A model that forgets the backslash still means the function.
    @Test func bareFunctionNamesAreSetUpright() {
        #expect(CardMarkup.mathRuns("cos\\theta") == [
            CardMarkup.MathRun("cos", style: .upright),
            CardMarkup.MathRun("θ")
        ])
        // The upright "(" coalesces onto the upright name, hence the prefix.
        let arccos = CardMarkup.mathRuns("arccos(c)")
        #expect(arccos.first?.style == .upright)
        #expect(arccos.first?.text.hasPrefix("arccos") == true)
        // Single letters are variables, not one-letter function names.
        #expect(CardMarkup.mathRuns("c").first == CardMarkup.MathRun("c"))
    }

    /// The gaps mean something only to a renderer that can draw them.
    @Test func plainTextUndoesTypographicSpacing() {
        #expect(CardMarkup.plainText("$c\\|x\\|$") == "c‖x‖")
        #expect(CardMarkup.plainText("$a+b$") == "a + b")
        #expect(CardMarkup.plainText("$\\sum_{i=1}^{n}$") == "∑ᵢ₌₁ⁿ")
    }
}

@Suite struct CardMarkupPlainTextTests {
    @Test func mathFlattensToUnicodeScripts() {
        #expect(CardMarkup.plainText("Given \\(a^T x \\ge c\\|x\\|\\) holds")
            == "Given aᵀ x ≥ c‖x‖ holds")
        #expect(CardMarkup.plainText("$x_i^2$") == "xᵢ²")
    }

    /// A script only becomes Unicode when every character has a form; "x → 0"
    /// doesn't, and it has to be marked as one piece, not per style run.
    @Test func unmappableScriptsFallBackToAMarker() {
        #expect(CardMarkup.plainText("$\\lim_{x \\to 0} f(x)$") == "lim_(x → 0) f(x)")
    }

    @Test func fractionHalvesStayFlat() {
        #expect(CardMarkup.plainText("$\\frac{a}{b}$") == "a⁄b")
    }

    @Test func blocksKeepTheirWordSeparation() {
        #expect(CardMarkup.plainText("Solve\n$$x^2$$\nnow") == "Solve x² now")
    }

    @Test func codeAndProseSurviveUntouched() {
        #expect(CardMarkup.plainText("call `fetchAll(db)` now") == "call fetchAll(db) now")
        #expect(CardMarkup.plainText("costs $5 and $10") == "costs $5 and $10")
    }
}

@Suite struct NoteCardPartsTests {
    @Test func singleLineQABackCompat() {
        let note = Note(topic: "t", body: "Fact.\n\nQ: What?\nA: That.")
        let parts = note.cardParts
        #expect(parts?.reference == "Fact.")
        #expect(parts?.question == "What?")
        #expect(parts?.answer == "That.")
    }

    @Test func multiLineAnswerSurvives() {
        let body = "Ref.\n\nQ: How to fetch?\nA: Use:\n```swift\ntry Row.fetchAll(db)\n```"
        let note = Note(topic: "t", body: body)
        #expect(note.questionAnswer?.answer
            == "Use:\n```swift\ntry Row.fetchAll(db)\n```")
    }

    @Test func multiLineQuestionStopsAtAnswer() {
        let note = Note(topic: "t", body: "Q: Given\n$$x^2$$\nwhat is x?\nA: ±√x")
        #expect(note.questionAnswer?.question == "Given\n$$x^2$$\nwhat is x?")
        #expect(note.questionAnswer?.answer == "±√x")
    }

    @Test func bodyWithoutQAIsNotACard() {
        #expect(Note(topic: "t", body: "reference only").cardParts == nil)
        #expect(Note(topic: "t", body: "Q: question, never answered").cardParts == nil)
    }

    @Test func composeRoundTripsThroughParse() {
        let body = Note.composeBody(
            reference: "Ref line.",
            question: "What is $\\frac{1}{2}$?",
            answer: "Half:\n```py\n0.5\n```")
        let parts = Note(topic: "t", body: body).cardParts
        #expect(parts?.reference == "Ref line.")
        #expect(parts?.question == "What is $\\frac{1}{2}$?")
        #expect(parts?.answer == "Half:\n```py\n0.5\n```")
    }

    @Test func composeWithoutReferenceOmitsIt() {
        #expect(Note.composeBody(reference: "  ", question: "q", answer: "a")
            == "Q: q\nA: a")
    }
}
