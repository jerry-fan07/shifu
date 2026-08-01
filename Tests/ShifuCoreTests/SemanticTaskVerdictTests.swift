import Foundation
import Testing
@testable import ShifuCore

/// Reading the model's answer (design.md §5.3). Split from
/// SemanticTaskGrouperTests.swift for length only.
///
/// The shapes here are the ones a real backend produces and a strict decoder
/// does not: fenced JSON, an object followed by commentary, every value
/// quoted, and — the one that matters — an answer cut off mid-object. A batch
/// can now carry a whole window, so its answer is thousands of tokens and
/// truncation is a live failure rather than a theoretical one. Telling "no
/// answer" apart from "no assignments" is what decides whether the blocks
/// retry or burn an attempt they never got a verdict for.
@Suite struct SemanticTaskVerdictTests {
    @Test func parseSeparatesNoAnswerFromAnEmptyOne() {
        // Nothing decodable: the caller must retry, not charge an attempt.
        #expect(SemanticTaskGrouper.parse("no json here") == nil)
        #expect(SemanticTaskGrouper.parse("") == nil)
        // Truncated mid-object — the brace never balances, so it is a
        // non-answer too. This is the shape a batch too big for its response
        // reserve produces, and the case that used to read as "declined".
        #expect(SemanticTaskGrouper.parse(#"{"assignments": [{"id": 4, "task": "t1","#) == nil)
        // A considered "none of these" is an empty verdict, and does charge.
        #expect(SemanticTaskGrouper.parse("{}") == .init(assignments: [], newTasks: []))
        // Prose after the object cannot extend the slice past it.
        let trailing = SemanticTaskGrouper.parse(
            #"{"assignments": [{"id": 4, "task": "t1", "confidence": 0.8}]} — note: {unclosed"#)
        #expect(trailing?.assignments == [.init(id: 4, task: "t1", confidence: 0.8)])
        // A model that quotes every value gave the same answer.
        let quoted = SemanticTaskGrouper.parse(
            #"{"assignments": [{"id": "4", "task": "t1", "confidence": "0.8"}]}"#)
        #expect(quoted?.assignments == [.init(id: 4, task: "t1", confidence: 0.8)])
    }

}
