import Foundation
import Testing
import CoreModels
@testable import LearnerModel

@Suite("FSRS-6 scheduler")
struct FSRSTests {
    let fsrs = FSRS()

    private func newState(_ id: String = "vocab:x", _ dim: SkillDimension = .recognitionReading) -> SkillState {
        SkillState(itemID: ItemID(rawValue: id), dimension: dim)
    }

    // MARK: - Retrievability

    @Test("R(0) == 1 and R decreases monotonically with elapsed time")
    func retrievabilityMonotonic() {
        let stability = 10.0
        #expect(abs(fsrs.retrievability(elapsedDays: 0, stability: stability) - 1.0) < 1e-9)

        var previous = fsrs.retrievability(elapsedDays: 0, stability: stability)
        for days in stride(from: 1.0, through: 60.0, by: 1.0) {
            let r = fsrs.retrievability(elapsedDays: days, stability: stability)
            #expect(r < previous, "R should strictly decrease at t=\(days)")
            #expect(r > 0 && r <= 1)
            previous = r
        }
    }

    @Test("Interval equals stability at the default 0.9 request retention")
    func intervalEqualsStabilityAt90() {
        for stability in [1.0, 5.0, 20.0, 100.0] {
            let ivl = fsrs.interval(stability: stability)
            #expect(abs(ivl - stability) < 1e-6, "I(0.9) should equal S for S=\(stability)")
        }
        // Higher requested retention => shorter interval.
        #expect(fsrs.interval(stability: 20, requestRetention: 0.95) < fsrs.interval(stability: 20, requestRetention: 0.9))
    }

    // MARK: - Initial state

    @Test("A brand-new item initializes sanely for each grade")
    func initialStateForEachGrade() {
        let now = Date()
        for grade in ReviewGrade.allCases {
            let result = fsrs.schedule(state: newState(), grade: grade, now: now)
            #expect(result.stability == fsrs.initialStability(grade))
            #expect(result.stability! > 0)
            let difficulty = try! #require(result.difficulty)
            #expect(difficulty >= 1 && difficulty <= 10)
            #expect(result.reps == 1)
            #expect(result.lapses == (grade == .again ? 1 : 0))
            #expect(result.lastReview == now)
            let due = try! #require(result.due)
            #expect(due > now)
        }
        // Easy starts more stable than Good > Hard > Again.
        let s = { grade in fsrs.initialStability(grade) }
        #expect(s(.easy) > s(.good))
        #expect(s(.good) > s(.hard))
        #expect(s(.hard) > s(.again))
    }

    // MARK: - Stability growth on success

    @Test("Stability strictly grows on repeated, appropriately spaced Good reviews")
    func stabilityGrowsOnGood() {
        var state = newState()
        var now = Date()
        state = fsrs.schedule(state: state, grade: .good, now: now)
        var lastStability = try! #require(state.stability)

        for _ in 0..<6 {
            // Advance to (approximately) the due date so retrievability ~ 0.9.
            now = try! #require(state.due)
            state = fsrs.schedule(state: state, grade: .good, now: now)
            let stability = try! #require(state.stability)
            #expect(stability > lastStability, "stability should grow: \(lastStability) -> \(stability)")
            lastStability = stability
        }
        #expect(state.reps == 7)
        #expect(state.lapses == 0)
    }

    @Test("Easy grows stability more than Good; Hard grows least among successes")
    func gradeOrderingOnSuccess() {
        let base = fsrs.schedule(state: newState(), grade: .good, now: Date())
        // Same starting state, spaced review, different grades.
        let now = base.due!
        let hard = fsrs.schedule(state: base, grade: .hard, now: now).stability!
        let good = fsrs.schedule(state: base, grade: .good, now: now).stability!
        let easy = fsrs.schedule(state: base, grade: .easy, now: now).stability!
        #expect(easy > good)
        #expect(good > hard)
    }

    // MARK: - Lapse behavior

    @Test("Again increments lapses, raises difficulty, and drops a matured item's stability")
    func againLapses() {
        // Build a matured item via several spaced Good reviews.
        var state = newState()
        var now = Date()
        state = fsrs.schedule(state: state, grade: .good, now: now)
        for _ in 0..<5 {
            now = state.due!
            state = fsrs.schedule(state: state, grade: .good, now: now)
        }
        let matureStability = try! #require(state.stability)
        let priorDifficulty = try! #require(state.difficulty)
        let priorLapses = state.lapses

        now = state.due!
        let lapsed = fsrs.schedule(state: state, grade: .again, now: now)
        #expect(lapsed.lapses == priorLapses + 1)
        #expect(lapsed.difficulty! > priorDifficulty, "difficulty should rise on Again")
        #expect(lapsed.stability! < matureStability, "stability should drop on Again")
        #expect(lapsed.stability! >= FSRS.minimumStability)
    }

    // MARK: - Ordering by overdue-ness

    @Test("A more overdue item has lower retrievability and sorts before a fresher one")
    func overdueOrdering() {
        let stability = 10.0
        let now = Date()
        // Two items, same stability, different last-review recency.
        func retr(daysAgo: Double) -> Double {
            fsrs.retrievability(elapsedDays: daysAgo, stability: stability)
        }
        let stale = retr(daysAgo: 40)   // very overdue
        let fresh = retr(daysAgo: 5)    // recently seen
        #expect(stale < fresh)

        // Sorting by retrievability ascending puts the more overdue item first.
        let items = [("fresh", fresh), ("stale", stale)].sorted { $0.1 < $1.1 }
        #expect(items.first?.0 == "stale")
        _ = now
    }
}
