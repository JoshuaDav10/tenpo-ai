import Testing
import Foundation
import GRDB
@testable import LearnerModel
import CoreModels
import Persistence

@Suite struct DueExplanationReasonTests {
    @Test func lapsedItemMentionsPriorSlips() {
        let r = DueExplanation.reason(retrievability: 0.5, stability: 3, lapses: 2)
        #expect(r.contains("50%"))
        #expect(r.contains("2×"))
        #expect(r.lowercased().contains("slip"))
    }

    @Test func matureItemReadsAsScheduledCheckin() {
        let r = DueExplanation.reason(retrievability: 0.88, stability: 40, lapses: 0)
        #expect(r.contains("88%"))
        #expect(r.lowercased().contains("mature"))
    }

    @Test func youngItemReadsAsReinforcement() {
        let r = DueExplanation.reason(retrievability: 0.7, stability: 5, lapses: 0)
        #expect(r.contains("70%"))
        #expect(r.lowercased().contains("reinforce"))
    }
}

@Suite struct DueExplanationsQueryTests {
    private func insert(_ db: DatabaseManager, _ state: SkillState) async throws {
        try await db.write { try SkillStateRecord(state).insert($0) }
    }

    @Test func returnsDueItemsMostForgottenFirstAndExcludesNotDue() async throws {
        let db = try DatabaseManager.inMemory()
        let now = Date()
        let dayAgo = now.addingTimeInterval(-86_400)

        // Very overdue relative to its small stability → low retrievability.
        let forgotten = SkillState(itemID: ItemID(rawValue: "forgotten"), dimension: .recognitionReading,
                                   stability: 2, difficulty: 6, due: dayAgo,
                                   lastReview: now.addingTimeInterval(-10 * 86_400), reps: 4, lapses: 1, suspended: false)
        // Barely elapsed relative to a large stability → high retrievability.
        let fresh = SkillState(itemID: ItemID(rawValue: "fresh"), dimension: .recognitionReading,
                               stability: 60, difficulty: 4, due: dayAgo,
                               lastReview: now.addingTimeInterval(-1 * 86_400), reps: 8, lapses: 0, suspended: false)
        // Not due yet (due in the future) → excluded.
        let notDue = SkillState(itemID: ItemID(rawValue: "not_due"), dimension: .recognitionReading,
                                stability: 30, difficulty: 5, due: now.addingTimeInterval(5 * 86_400),
                                lastReview: dayAgo, reps: 3, lapses: 0, suspended: false)
        // Suspended → excluded even though due.
        let suspended = SkillState(itemID: ItemID(rawValue: "suspended"), dimension: .recognitionReading,
                                   stability: 3, difficulty: 5, due: dayAgo, lastReview: dayAgo,
                                   reps: 1, lapses: 0, suspended: true)
        for s in [forgotten, fresh, notDue, suspended] { try await insert(db, s) }

        let service = LiveLearnerModelService(db: db)
        let out = try await service.dueExplanations(now: now, limit: 10)

        #expect(out.map(\.itemID.rawValue) == ["forgotten", "fresh"]) // most-forgotten first, others excluded
        #expect(out[0].retrievability < out[1].retrievability)
        #expect(out[0].lapses == 1)
        #expect(!out[0].headline.isEmpty)
    }

    @Test func respectsLimit() async throws {
        let db = try DatabaseManager.inMemory()
        let now = Date()
        let dayAgo = now.addingTimeInterval(-86_400)
        for i in 0..<5 {
            let s = SkillState(itemID: ItemID(rawValue: "i\(i)"), dimension: .recognitionReading,
                               stability: Double(i + 1), difficulty: 5, due: dayAgo,
                               lastReview: now.addingTimeInterval(-2 * 86_400), reps: 1, lapses: 0, suspended: false)
            try await insert(db, s)
        }
        let out = try await LiveLearnerModelService(db: db).dueExplanations(now: now, limit: 3)
        #expect(out.count == 3)
    }
}
