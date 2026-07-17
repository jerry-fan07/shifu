import Foundation

/// Small FSRS-4.5 implementation (design.md §5.2) — vendored rather than a
/// dependency (implementation.md §0). State lives in note frontmatter so the
/// vault folder stays self-contained.
public enum FSRS {
    public enum Grade: Int, Sendable, CaseIterable {
        case again = 1, hard = 2, good = 3, easy = 4
    }

    public struct State: Equatable, Sendable {
        public var stability: Double
        public var difficulty: Double
        public var intervalDays: Double
        public var due: Date
        public var reps: Int
        public var lastReview: Date?

        public init(stability: Double = 0, difficulty: Double = 0, intervalDays: Double = 0,
                    due: Date = Date(), reps: Int = 0, lastReview: Date? = nil) {
            self.stability = stability
            self.difficulty = difficulty
            self.intervalDays = intervalDays
            self.due = due
            self.reps = reps
            self.lastReview = lastReview
        }
    }

    // FSRS-4.5 default weights.
    static let weights: [Double] = [
        0.4872, 1.4003, 3.7145, 13.8206, 5.1618, 1.2298, 0.8975, 0.031,
        1.6474, 0.1367, 1.0461, 2.1072, 0.0793, 0.3246, 1.587, 0.2272, 2.8755
    ]
    static let decay = -0.5
    static let factor = pow(0.9, 1 / decay) - 1   // ≈ 0.2346 so interval(R=0.9) = stability
    public static let requestRetention = 0.9
    public static let maxIntervalDays = 365.0

    /// Applies a review grade and returns the next state.
    public static func review(_ state: State, grade: Grade, now: Date = Date()) -> State {
        var next = state
        next.reps = state.reps + 1
        next.lastReview = now

        if state.reps == 0 || state.stability <= 0 {
            // First review: seed from initial-stability/difficulty weights.
            next.stability = weights[grade.rawValue - 1]
            next.difficulty = clampDifficulty(weights[4] - Double(grade.rawValue - 3) * weights[5])
        } else {
            let elapsed = max(0, now.timeIntervalSince(state.lastReview ?? now) / 86_400)
            let retrievability = pow(1 + factor * elapsed / state.stability, decay)
            next.difficulty = nextDifficulty(state.difficulty, grade: grade)
            if grade == .again {
                next.stability = forgetStability(
                    difficulty: next.difficulty, stability: state.stability,
                    retrievability: retrievability)
            } else {
                next.stability = recallStability(
                    difficulty: next.difficulty, stability: state.stability,
                    retrievability: retrievability, grade: grade)
            }
        }

        let interval: Double
        switch grade {
        case .again: interval = 0            // relearn today
        default: interval = max(1, min(maxIntervalDays,
            (next.stability / factor * (pow(requestRetention, 1 / decay) - 1)).rounded()))
        }
        next.intervalDays = interval
        next.due = now.addingTimeInterval(interval * 86_400)
        return next
    }

    static func nextDifficulty(_ difficulty: Double, grade: Grade) -> Double {
        let d0easy = clampDifficulty(weights[4] - 1 * weights[5])   // D0(4), mean-reversion target
        let updated = difficulty - weights[6] * Double(grade.rawValue - 3)
        return clampDifficulty(weights[7] * d0easy + (1 - weights[7]) * updated)
    }

    static func recallStability(
        difficulty: Double, stability: Double, retrievability: Double, grade: Grade
    ) -> Double {
        let hardPenalty = grade == .hard ? weights[15] : 1
        let easyBonus = grade == .easy ? weights[16] : 1
        let growth = exp(weights[8]) * (11 - difficulty) * pow(stability, -weights[9])
            * (exp(weights[10] * (1 - retrievability)) - 1) * hardPenalty * easyBonus
        return stability * (1 + growth)
    }

    static func forgetStability(
        difficulty: Double, stability: Double, retrievability: Double
    ) -> Double {
        let forgottenStability = weights[11] * pow(difficulty, -weights[12]) * (pow(stability + 1, weights[13]) - 1)
            * exp(weights[14] * (1 - retrievability))
        return min(forgottenStability, stability)
    }

    static func clampDifficulty(_ val: Double) -> Double { min(10, max(1, val)) }
}
