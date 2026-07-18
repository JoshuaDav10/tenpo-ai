import Foundation
import CoreModels

// FSRS-6 (Free Spaced Repetition Scheduler) — pure, Sendable port (§4.5).
//
// This is a faithful implementation of the FSRS-6 long-term memory model:
//   - initial stability / difficulty from the first grade,
//   - stability update on recall (Hard/Good/Easy) and on lapse (Again),
//   - difficulty update with linear damping + mean reversion,
//   - power-law retrievability R(t) and its inverse (interval for a target retention).
//
// Per the Phase-1 spec we use the FSRS "fixed decay" formulation:
//   DECAY = -0.5, FACTOR = 19/81 = 0.9^(1/DECAY) - 1.
// FSRS-6 also treats decay as a learnable parameter (w20). We keep w20 in the
// weight vector so a later optimization phase can switch to a per-user decay,
// but the scheduler currently uses the fixed DECAY/FACTOR above (spec decision).
//
// FSRS weight *optimization* on the user's own review log is a later phase; the
// defaults here are the published FSRS-6 defaults, kept in exactly one place
// (`FSRSParameters.default`) so they are trivial to swap out.

/// The 21-weight FSRS-6 parameter vector plus scheduling policy knobs.
///
/// All model math reads from `w[0]…w[20]`. `requestRetention` is the target
/// recall probability at the moment an item next becomes due (0.9 by default).
public struct FSRSParameters: Sendable, Equatable {
    /// FSRS-6 weight vector `w0…w20`.
    public var w: [Double]
    /// Target retention used to derive the next interval (default 0.9).
    public var requestRetention: Double
    /// Hard ceiling on any scheduled interval, in days.
    public var maximumInterval: Double

    public init(
        w: [Double],
        requestRetention: Double = 0.9,
        maximumInterval: Double = 36_500
    ) {
        precondition(w.count == 21, "FSRS-6 requires exactly 21 weights (w0…w20)")
        self.w = w
        self.requestRetention = requestRetention
        self.maximumInterval = maximumInterval
    }

    /// Published FSRS-6 default weights. Keep edits confined to this one spot.
    public static let `default` = FSRSParameters(w: [
        0.2172,  // w0  initial stability, Again
        1.1771,  // w1  initial stability, Hard
        3.2602,  // w2  initial stability, Good
        16.1507, // w3  initial stability, Easy
        7.0114,  // w4  initial difficulty base
        0.57,    // w5  initial difficulty curvature
        2.0966,  // w6  difficulty delta scale
        0.0069,  // w7  difficulty mean-reversion weight
        1.5261,  // w8  recall stability: base gain
        0.112,   // w9  recall stability: stability saturation
        1.0178,  // w10 recall stability: retrievability sensitivity
        1.849,   // w11 lapse stability: base
        0.1133,  // w12 lapse stability: difficulty sensitivity
        0.3127,  // w13 lapse stability: stability sensitivity
        2.2934,  // w14 lapse stability: retrievability sensitivity
        0.2191,  // w15 Hard penalty (multiplicative, < 1)
        3.0004,  // w16 Easy bonus (multiplicative, > 1)
        0.7536,  // w17 short-term stability (reserved — same-day steps, later phase)
        0.3332,  // w18 short-term stability (reserved)
        0.1437,  // w19 short-term stability (reserved)
        0.2,     // w20 learnable decay (reserved — scheduler uses fixed DECAY below)
    ])
}

/// Pure FSRS-6 scheduler. Stateless apart from its parameters; every method is a
/// function of its arguments, so it is trivially `Sendable` and testable.
public struct FSRS: Sendable {
    public let parameters: FSRSParameters

    /// Fixed power-law decay (spec: DECAY = -0.5).
    public static let decay: Double = -0.5
    /// FACTOR = 0.9^(1/DECAY) - 1 = 19/81, so interval == stability at r = 0.9.
    public static let factor: Double = 19.0 / 81.0
    /// Stability floor (days) to keep the model numerically well-behaved.
    public static let minimumStability: Double = 0.01

    public init(parameters: FSRSParameters = .default) {
        self.parameters = parameters
    }

    // MARK: - Retrievability & interval

    /// R(t) = (1 + FACTOR * t / S)^DECAY — probability of recall after `t` days.
    /// Returns 1.0 at t = 0 and decreases monotonically as `t` grows.
    public func retrievability(elapsedDays t: Double, stability: Double) -> Double {
        guard stability > 0 else { return 0 }
        let base = 1 + Self.factor * max(0, t) / stability
        return pow(base, Self.decay)
    }

    /// I(r) = (S / FACTOR) * (r^(1/DECAY) - 1) — days until R decays to `r`.
    /// At r = 0.9 this equals S. Clamped to `[1, maximumInterval]`.
    public func interval(stability: Double, requestRetention r: Double? = nil) -> Double {
        let target = r ?? parameters.requestRetention
        let raw = (stability / Self.factor) * (pow(target, 1 / Self.decay) - 1)
        return min(max(raw, 1), parameters.maximumInterval)
    }

    // MARK: - Initial state (first grade)

    /// Initial stability S₀(G) = w[G-1] (Again→w0, Hard→w1, Good→w2, Easy→w3).
    public func initialStability(_ grade: ReviewGrade) -> Double {
        max(Self.minimumStability, parameters.w[grade.rawValue - 1])
    }

    /// Initial difficulty D₀(G) = w4 - e^(w5·(G-1)) + 1, clamped to [1, 10].
    public func initialDifficulty(_ grade: ReviewGrade) -> Double {
        let g = Double(grade.rawValue)
        let d = parameters.w[4] - exp(parameters.w[5] * (g - 1)) + 1
        return clampDifficulty(d)
    }

    // MARK: - Difficulty update

    /// Next difficulty: linear-damped delta then mean-reversion toward D₀(Easy).
    public func nextDifficulty(current difficulty: Double, grade: ReviewGrade) -> Double {
        let g = Double(grade.rawValue)
        let deltaD = -parameters.w[6] * (g - 3)
        // Linear damping: changes shrink as difficulty approaches its ceiling.
        let damped = difficulty + deltaD * (10 - difficulty) / 9
        // Mean-reversion toward the difficulty an "Easy" first answer would imply.
        let reverted = parameters.w[7] * initialDifficulty(.easy) + (1 - parameters.w[7]) * damped
        return clampDifficulty(reverted)
    }

    // MARK: - Stability update

    /// Stability after a successful recall (Hard/Good/Easy).
    public func stabilityAfterRecall(
        difficulty: Double, stability: Double, retrievability r: Double, grade: ReviewGrade
    ) -> Double {
        let hardPenalty = grade == .hard ? parameters.w[15] : 1
        let easyBonus = grade == .easy ? parameters.w[16] : 1
        let increment = exp(parameters.w[8])
            * (11 - difficulty)
            * pow(stability, -parameters.w[9])
            * (exp(parameters.w[10] * (1 - r)) - 1)
            * hardPenalty
            * easyBonus
        return max(Self.minimumStability, stability * (1 + increment))
    }

    /// Stability after a lapse (Again). Clamped so a lapse never *raises* stability.
    public func stabilityAfterLapse(
        difficulty: Double, stability: Double, retrievability r: Double
    ) -> Double {
        let sForget = parameters.w[11]
            * pow(difficulty, -parameters.w[12])
            * (pow(stability + 1, parameters.w[13]) - 1)
            * exp(parameters.w[14] * (1 - r))
        return max(Self.minimumStability, min(sForget, stability))
    }

    // MARK: - Entry point

    /// Apply one graded review to a `SkillState`, returning the updated state
    /// (new stability, difficulty, due date, lastReview, reps, lapses).
    ///
    /// A brand-new item (nil stability/difficulty) is initialized from `grade`;
    /// otherwise the recall/lapse formulas run using the elapsed-day retrievability.
    public func schedule(state: SkillState, grade: ReviewGrade, now: Date) -> SkillState {
        var next = state
        let newStability: Double
        let newDifficulty: Double

        if let stability = state.stability, let difficulty = state.difficulty {
            let elapsedDays: Double
            if let last = state.lastReview {
                elapsedDays = max(0, now.timeIntervalSince(last) / 86_400)
            } else {
                elapsedDays = 0
            }
            let r = retrievability(elapsedDays: elapsedDays, stability: stability)
            if grade == .again {
                newStability = stabilityAfterLapse(difficulty: difficulty, stability: stability, retrievability: r)
                next.lapses += 1
            } else {
                newStability = stabilityAfterRecall(difficulty: difficulty, stability: stability, retrievability: r, grade: grade)
            }
            newDifficulty = nextDifficulty(current: difficulty, grade: grade)
        } else {
            // First review of this dimension.
            newStability = initialStability(grade)
            newDifficulty = initialDifficulty(grade)
            if grade == .again { next.lapses += 1 }
        }

        next.stability = newStability
        next.difficulty = newDifficulty
        next.reps += 1
        next.lastReview = now
        let ivl = interval(stability: newStability)
        next.due = now.addingTimeInterval(ivl * 86_400)
        return next
    }

    // MARK: - Helpers

    private func clampDifficulty(_ d: Double) -> Double {
        min(10, max(1, d))
    }
}
