import Testing
import Foundation
import GRDB
@testable import LearnerModel
import CoreModels
import Persistence

private func makeService() throws -> (LiveLearnerModelService, DatabaseManager) {
    let db = try DatabaseManager.inMemory()
    return (LiveLearnerModelService(db: db), db)
}

private func seedVocab(_ db: DatabaseManager, id: String, lemma: String, band: String) async throws {
    let item = ContentItem(id: ItemID(rawValue: id), language: .japanese, kind: .vocab,
                           payload: .object(["lemma": .string(lemma)]), band: band)
    try await db.write { try ContentItemRecord(item).insert($0) }
}

private func completeSession(_ db: DatabaseManager, daysAgo: Int) async throws {
    let started = Date().addingTimeInterval(-Double(daysAgo) * 86_400)
    try await db.write { database in
        try database.execute(sql: """
            INSERT INTO session (id, mode_id, started_at, ended_at, status)
            VALUES (?, 'lesson.guided', ?, ?, 'completed')
            """, arguments: [UUID().uuidString, started, started.addingTimeInterval(600)])
    }
}

private func logError(_ db: DatabaseManager, category: String,
                     surface: String? = nil, expected: String? = nil) async throws {
    try await db.write { database in
        try database.execute(sql: """
            INSERT INTO error_event (id, category, surface, expected, at)
            VALUES (?, ?, ?, ?, ?)
            """, arguments: [UUID().uuidString, category, surface, expected, Date()])
    }
}

struct LearnerProfileTests {

    @Test func newLearnerProfileSaysSoAndInventsNoHistory() async throws {
        let (service, _) = try makeService()
        let profile = try await service.profile()
        #expect(profile.isNewLearner)
        #expect(profile.sessionsCompleted == 0)

        let summary = profile.promptSummary(name: "Joshua")
        #expect(summary == "This is Joshua's first lesson.")
        // Crucially: no fabricated weak spots or streaks for someone with no history.
        #expect(!summary.contains("streak"))
        #expect(!summary.contains("shaky"))
    }

    @Test func profileAssemblesHistoryFromWhatWeAlreadyRecord() async throws {
        let (service, db) = try makeService()
        try await seedVocab(db, id: "vocab:水", lemma: "水", band: "N5.2")
        try await seedVocab(db, id: "vocab:私", lemma: "私", band: "N5.2")
        try await completeSession(db, daysAgo: 0)
        try await completeSession(db, daysAgo: 1)
        // A recurring particle problem plus one concrete correction.
        try await logError(db, category: "particle")
        try await logError(db, category: "particle", surface: "水は飲む", expected: "水を飲む")
        try await logError(db, category: "vocab")

        // Make both items overdue so they surface as weak.
        let past = Date().addingTimeInterval(-86_400)
        for id in ["vocab:水", "vocab:私"] {
            try await service.report(ReviewEvent(
                itemID: ItemID(rawValue: id), dimension: .productionSpoken,
                grade: .again, modeID: "test", sessionID: nil, at: past))
        }

        let profile = try await service.profile()
        #expect(!profile.isNewLearner)
        #expect(profile.sessionsCompleted == 2)
        #expect(profile.streakDays == 2)          // today + yesterday
        #expect(profile.band == "N5.2")           // inferred from tracked items
        #expect(profile.trackedItems == 2)
        #expect(profile.recurringErrors.first?.category == "particle")
        #expect(profile.recurringErrors.first?.count == 2)
        #expect(profile.recentCorrections.contains { $0.expected == "水を飲む" })

        let summary = profile.promptSummary(name: "Joshua")
        #expect(summary.contains("Joshua"))
        #expect(summary.contains("N5.2"))
        #expect(summary.contains("2-day streak"))
        #expect(summary.contains("particles"))    // human-readable, not "particle"
        #expect(summary.contains("水を飲む"))
    }

    @Test func returningAfterABreakIsFlaggedGently() async throws {
        let (service, db) = try makeService()
        try await completeSession(db, daysAgo: 9)
        let profile = try await service.profile()
        #expect(profile.daysSinceLastSession == 9)
        #expect(profile.streakDays == 0)          // streak broken

        let summary = profile.promptSummary()
        #expect(summary.contains("9 days"))
        #expect(summary.contains("no guilt"))     // tone matters: never scold
    }

    @Test func oneOffMistakesDoNotBecomeRecurringWeakSpots() async throws {
        let (service, db) = try makeService()
        try await completeSession(db, daysAgo: 0)
        try await logError(db, category: "pronunciation")   // single occurrence
        let profile = try await service.profile()
        // Recorded, but not surfaced as a "recurring weak spot" (needs >= 2).
        #expect(profile.recurringErrors.first?.count == 1)
        #expect(!profile.promptSummary().contains("Recurring weak spot"))
    }
}
