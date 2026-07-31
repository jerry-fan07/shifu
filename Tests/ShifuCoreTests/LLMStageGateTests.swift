import Foundation
import Testing
@testable import ShifuCore

/// The interval gate that keeps some LLM stages from billing on every hourly
/// pass (`LLMStageGate`). Callers stamp only on success, so the "failed run
/// retries next pass" property is theirs; what's pinned here is the arithmetic.
@Suite struct LLMStageGateTests {
    @Test func dueImmediatelyThenNotUntilTheIntervalPasses() throws {
        let database = try ShifuDatabase.inMemory()
        let interval: Int64 = 4 * 3_600_000
        // Never stamped ⇒ due, whatever the clock says.
        #expect(LLMStageGate.due("stage.test", everyMs: interval, now: 1_000,
                                 database: database))
        LLMStageGate.stamp("stage.test", now: 1_000, database: database)
        #expect(!LLMStageGate.due("stage.test", everyMs: interval,
                                  now: 1_000 + interval - 1, database: database))
        #expect(LLMStageGate.due("stage.test", everyMs: interval,
                                 now: 1_000 + interval, database: database))
    }

    @Test func gatesAreIndependentPerKey() throws {
        let database = try ShifuDatabase.inMemory()
        LLMStageGate.stamp("stage.one", now: 5_000, database: database)
        #expect(!LLMStageGate.due("stage.one", everyMs: 10_000, now: 6_000,
                                  database: database))
        #expect(LLMStageGate.due("stage.two", everyMs: 10_000, now: 6_000,
                                 database: database))
    }
}
