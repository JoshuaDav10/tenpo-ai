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

@Suite struct WeakAreaGridTests {
    private func putContent(_ db: DatabaseManager, id: String, band: String) async throws {
        let item = ContentItem(id: ItemID(rawValue: id), language: .japanese, kind: .vocab,
                               payload: .object([:]), band: band)
        try await db.write { try ContentItemRecord(item).insert($0) }
    }
    private func putState(_ db: DatabaseManager, id: String, dim: SkillDimension, stability: Double) async throws {
        let s = SkillState(itemID: ItemID(rawValue: id), dimension: dim, stability: stability,
                           difficulty: 5, due: Date(), lastReview: Date(), reps: 1, lapses: 0, suspended: false)
        try await db.write { try SkillStateRecord(s).insert($0) }
    }

    @Test func aggregatesByBandAndDimensionIntoMasteryBuckets() async throws {
        let db = try DatabaseManager.inMemory()
        // N5.1 reading: one learning (stability 1) + one mature (stability 30).
        try await putContent(db, id: "a", band: "N5.1"); try await putState(db, id: "a", dim: .recognitionReading, stability: 1)
        try await putContent(db, id: "b", band: "N5.1"); try await putState(db, id: "b", dim: .recognitionReading, stability: 30)
        // N5.2 spoken: one young (stability 10).
        try await putContent(db, id: "c", band: "N5.2"); try await putState(db, id: "c", dim: .productionSpoken, stability: 10)

        let grid = try await LiveLearnerModelService(db: db).weakAreaGrid()
        #expect(grid.bands == ["N5.1", "N5.2"])
        let n51reading = grid.cell(band: "N5.1", dimension: .recognitionReading)
        #expect(n51reading?.counts.learning == 1)
        #expect(n51reading?.counts.mature == 1)
        #expect(grid.cell(band: "N5.2", dimension: .productionSpoken)?.counts.young == 1)
        // No spoken state in N5.1 → empty cell.
        #expect(grid.cell(band: "N5.1", dimension: .productionSpoken) == nil)
    }
}

@Suite struct DueForecastTests {
    private func putState(_ db: DatabaseManager, id: String, due: Date) async throws {
        let s = SkillState(itemID: ItemID(rawValue: id), dimension: .recognitionReading, stability: 5,
                           difficulty: 5, due: due, lastReview: Date(), reps: 1, lapses: 0, suspended: false)
        try await db.write { try SkillStateRecord(s).insert($0) }
    }

    @Test func bucketsByDayAndFoldsOverdueIntoToday() async throws {
        let db = try DatabaseManager.inMemory()
        let cal = Calendar.current
        let now = Date()
        let noon = cal.date(bySettingHour: 12, minute: 0, second: 0, of: now)!
        // Two overdue (5 and 1 days ago) → both today; one tomorrow; one in 3 days;
        // one far out (10 days) beyond the 7-day window → excluded.
        try await putState(db, id: "a", due: cal.date(byAdding: .day, value: -5, to: noon)!)
        try await putState(db, id: "b", due: cal.date(byAdding: .day, value: -1, to: noon)!)
        try await putState(db, id: "c", due: cal.date(byAdding: .day, value: 1, to: noon)!)
        try await putState(db, id: "d", due: cal.date(byAdding: .day, value: 3, to: noon)!)
        try await putState(db, id: "e", due: cal.date(byAdding: .day, value: 10, to: noon)!)

        let forecast = try await LiveLearnerModelService(db: db).dueForecast(now: now, days: 7)
        #expect(forecast.days.count == 7)
        #expect(forecast.days[0].count == 2) // both overdue folded into today
        #expect(forecast.days[1].count == 1) // tomorrow
        #expect(forecast.days[3].count == 1) // in 3 days
        #expect(forecast.total == 4)          // the 10-day-out item is outside the window
        #expect(forecast.peak == 2)
    }
}
