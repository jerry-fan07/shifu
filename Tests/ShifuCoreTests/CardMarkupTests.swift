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
                CardMarkup.MathRun("x"), CardMarkup.MathRun("2", script: .raised)
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
            CardMarkup.MathRun("a"), CardMarkup.MathRun("1", script: .lowered)
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
            .text("Before.\n"),
            .codeBlock(code: "let x = 1\nprint(x)", language: "swift"),
            .text("After.")
        ])
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
    @Test func greekAndOperatorsBecomeUnicode() {
        #expect(CardMarkup.mathRuns("\\alpha \\times \\beta \\le \\infty")
            == [CardMarkup.MathRun("α × β ≤ ∞")])
    }

    @Test func superAndSubscriptsBecomeScriptRuns() {
        #expect(CardMarkup.mathRuns("x^2") == [
            CardMarkup.MathRun("x"), CardMarkup.MathRun("2", script: .raised)
        ])
        #expect(CardMarkup.mathRuns("a_{ij}") == [
            CardMarkup.MathRun("a"), CardMarkup.MathRun("ij", script: .lowered)
        ])
    }

    @Test func fractionRaisesNumeratorLowersDenominator() {
        #expect(CardMarkup.mathRuns("\\frac{a+b}{2}") == [
            CardMarkup.MathRun("a+b", script: .raised),
            CardMarkup.MathRun("⁄"),
            CardMarkup.MathRun("2", script: .lowered)
        ])
    }

    @Test func sqrtWrapsMultiCharRadicands() {
        #expect(CardMarkup.mathRuns("\\sqrt{2}") == [CardMarkup.MathRun("√2")])
        #expect(CardMarkup.mathRuns("\\sqrt{x+1}") == [CardMarkup.MathRun("√(x+1)")])
    }

    @Test func textCommandAndBracesPassThrough() {
        #expect(CardMarkup.mathRuns("\\text{iff } {x}")
            == [CardMarkup.MathRun("iff  x")])
    }

    @Test func unknownCommandDegradesToItsName() {
        #expect(CardMarkup.mathRuns("\\mystery") == [CardMarkup.MathRun("mystery")])
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
