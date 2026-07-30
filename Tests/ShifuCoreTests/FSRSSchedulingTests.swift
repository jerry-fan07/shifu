import Foundation
import Testing
@testable import ShifuCore

/// FSRS-4.5 (design.md §5.2), vendored rather than depended on — so the
/// arithmetic is ours to get wrong. `VaultTests.FSRSTests` covers the four
/// happy paths; these cover the bounds, which is where a vendored scheduler
/// actually breaks: a difficulty that escapes its clamp, an interval that runs
/// past a year, or a stability that grows on a lapse.
@Suite struct FSRSSchedulingTests {
    static let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    private func mature(reps: Int, grade: FSRS.Grade = .good) -> FSRS.State {
        var state = FSRS.State()
        var now = Self.epoch
        for _ in 0..<reps {
            state = FSRS.review(state, grade: grade, now: now)
            now = state.due
        }
        return state
    }

    @Test func aFirstReviewSeedsFromTheInitialStabilityWeights() {
        for grade in FSRS.Grade.allCases {
            let state = FSRS.review(FSRS.State(), grade: grade, now: Self.epoch)
            #expect(state.reps == 1)
            #expect(state.lastReview == Self.epoch)
            #expect(state.stability == FSRS.weights[grade.rawValue - 1])
            #expect(state.difficulty >= 1 && state.difficulty <= 10)
        }
    }

    /// A card whose state was lost or corrupted (stability 0 with reps > 0)
    /// must re-seed rather than divide by it.
    @Test func aZeroStabilityStateReSeedsInsteadOfProducingNonsense() {
        let broken = FSRS.State(stability: 0, difficulty: 5, intervalDays: 3,
                                due: Self.epoch, reps: 9, lastReview: Self.epoch)
        let state = FSRS.review(broken, grade: .good, now: Self.epoch.addingTimeInterval(86_400))
        #expect(state.stability == FSRS.weights[2])
        #expect(state.intervalDays >= 1)
        #expect(state.due > state.lastReview!)
    }

    @Test func difficultyStaysInsideItsClampUnderEveryGradeSequence() {
        var state = FSRS.State()
        var now = Self.epoch
        // Twenty "again"s then twenty "easy"s — the two extremes of the walk.
        for grade in Array(repeating: FSRS.Grade.again, count: 20)
            + Array(repeating: .easy, count: 20) {
            state = FSRS.review(state, grade: grade, now: now)
            #expect(state.difficulty >= 1 && state.difficulty <= 10,
                    "difficulty escaped its clamp: \(state.difficulty)")
            now = state.due.addingTimeInterval(86_400)
        }
    }

    @Test func intervalsNeverExceedTheYearCap() {
        var state = FSRS.State()
        var now = Self.epoch
        for _ in 0..<40 {
            state = FSRS.review(state, grade: .easy, now: now)
            #expect(state.intervalDays <= FSRS.maxIntervalDays)
            now = state.due
        }
        #expect(state.intervalDays == FSRS.maxIntervalDays)   // it does saturate
    }

    @Test func aSuccessfulReviewNeverSchedulesSoonerThanTomorrow() {
        var state = FSRS.State()
        var now = Self.epoch
        for grade in [FSRS.Grade.hard, .good, .easy, .hard, .hard, .hard] {
            state = FSRS.review(state, grade: grade, now: now)
            #expect(state.intervalDays >= 1)
            now = state.due
        }
    }

    /// The whole point of a lapse: the card comes back today and is *weaker*,
    /// never stronger, than it was.
    @Test func aLapseNeverIncreasesStability() {
        for reps in 1...6 {
            let before = mature(reps: reps)
            let after = FSRS.review(before, grade: .again, now: before.due)
            #expect(after.stability <= before.stability)
            #expect(after.intervalDays == 0)
            #expect(after.due == before.due)   // relearn today
        }
    }

    @Test func gradesOrderTheNextIntervalTheWayTheUserWouldExpect() {
        let base = mature(reps: 3)
        let intervals = FSRS.Grade.allCases.map {
            FSRS.review(base, grade: $0, now: base.due).intervalDays
        }
        #expect(intervals == intervals.sorted())
        #expect(intervals[0] == 0)                 // again
        #expect(intervals[3] > intervals[1])       // easy beats hard
    }

    /// Stability is defined as "the interval at which recall probability falls
    /// to `requestRetention`" — so at R = 0.9 the interval *is* the stability.
    /// That identity is what `factor` exists to make true.
    @Test func atTheRequestedRetentionTheIntervalIsTheStability() {
        let state = mature(reps: 4)
        #expect(abs(state.intervalDays - state.stability.rounded()) <= 1)
        #expect(FSRS.requestRetention == 0.9)
    }

    /// Reviewing late means more forgetting has happened, so the review is
    /// worth more: lower retrievability, larger stability gain.
    @Test func reviewingLateEarnsMoreStabilityThanReviewingEarly() {
        let base = mature(reps: 3)
        let early = FSRS.review(base, grade: .good, now: base.lastReview!.addingTimeInterval(86_400))
        let late = FSRS.review(base, grade: .good,
                               now: base.lastReview!.addingTimeInterval(40 * 86_400))
        #expect(late.stability > early.stability)
    }

    @Test func repsAndLastReviewAlwaysAdvance() {
        var state = FSRS.State()
        var now = Self.epoch
        for expected in 1...10 {
            state = FSRS.review(state, grade: .good, now: now)
            #expect(state.reps == expected)
            #expect(state.lastReview == now)
            now = state.due
        }
    }

    /// The raw values are the FSRS convention and are stored directly in
    /// `srs_reviews.grade`; renumbering them would silently rewrite history.
    @Test func gradeRawValuesAreTheStoredOnesAndMustNotMove() {
        #expect(FSRS.Grade.again.rawValue == 1)
        #expect(FSRS.Grade.hard.rawValue == 2)
        #expect(FSRS.Grade.good.rawValue == 3)
        #expect(FSRS.Grade.easy.rawValue == 4)
    }

    @Test func aStateThatWasNeverReviewedIsDueImmediately() {
        let fresh = FSRS.State()
        #expect(fresh.reps == 0)
        #expect(fresh.lastReview == nil)
        #expect(fresh.due <= Date())
    }
}
