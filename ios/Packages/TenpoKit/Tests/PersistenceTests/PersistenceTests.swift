import Testing
import Foundation
import GRDB
import CoreModels
@testable import Persistence

@Suite struct MigrationTests {
    @Test func v1CreatesAllTables() async throws {
        let db = try DatabaseManager.inMemory()
        let tables = try await db.read { database in
            try String.fetchAll(database, sql: "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
        }
        for expected in [
            "content_item", "item_link", "skill_state",
            "review_event", "error_event", "session", "transcript_turn",
        ] {
            #expect(tables.contains(expected), "missing table \(expected)")
        }
    }
}

@Suite struct RecordRoundTripTests {
    @Test func contentItemRoundTrips() async throws {
        let db = try DatabaseManager.inMemory()
        let item = ContentItem(
            id: "vocab:食べる", language: .japanese, kind: .vocab,
            payload: .object(["kana": .string("たべる"), "glosses": .array([.string("to eat")])]),
            band: "N5.1", frequencyRank: 42, source: "JMdict", license: "EDRDG CC BY-SA 4.0"
        )
        let record = try ContentItemRecord(item)
        try await db.write { try record.insert($0) }

        let fetched = try await db.read { try ContentItemRecord.fetchOne($0, key: "vocab:食べる") }
        let roundTripped = try #require(fetched).asContentItem()
        #expect(try roundTripped == item)
    }

    @Test func skillStateRoundTripsPerDimension() async throws {
        let db = try DatabaseManager.inMemory()
        // R9: same item, independent state per dimension.
        let recognition = SkillState(itemID: "vocab:食べる", dimension: .recognitionListening, stability: 12.5, reps: 4)
        let production = SkillState(itemID: "vocab:食べる", dimension: .productionSpoken, stability: 0.4, reps: 1, lapses: 2)
        try await db.write { database in
            try SkillStateRecord(recognition).insert(database)
            try SkillStateRecord(production).insert(database)
        }

        let count = try await db.read { try SkillStateRecord.fetchCount($0) }
        #expect(count == 2)

        let fetched = try await db.read { database in
            try SkillStateRecord
                .filter(sql: "item_id = ? AND dimension = ?", arguments: ["vocab:食べる", "productionSpoken"])
                .fetchOne(database)
        }
        let state = try #require(fetched).asSkillState()
        #expect(try state.lapses == 2)
        #expect(try state.stability == 0.4)
    }

    @Test func reviewAndErrorEventsAppend() async throws {
        let db = try DatabaseManager.inMemory()
        let sessionID = UUID()
        let review = ReviewEvent(itemID: "grammar:ni_direction", dimension: .productionSpoken,
                                 grade: .again, modeID: "roleplay.guided", sessionID: sessionID)
        let error = ErrorEvent(sessionID: sessionID, itemID: "grammar:ni_direction",
                               category: .particle, surface: "学校を行く", expected: "学校に行く",
                               severity: "recurring")
        try await db.write { database in
            try ReviewEventRecord(review).insert(database)
            try ErrorEventRecord(error).insert(database)
        }
        let grades = try await db.read { try Int.fetchAll($0, sql: "SELECT grade FROM review_event") }
        #expect(grades == [1])
        let categories = try await db.read { try String.fetchAll($0, sql: "SELECT category FROM error_event") }
        #expect(categories == ["particle"])
    }

    @Test func transcriptTurnsPersistWithDirectorJSON() async throws {
        let db = try DatabaseManager.inMemory()
        let sessionID = UUID()
        let session = SessionRecord(id: sessionID, modeID: "roleplay.guided",
                                    scenarioID: "scenario:pharmacy_headache_v1", pipeline: .realtime)
        let turn = TranscriptTurn(sessionID: sessionID, seq: 1, role: .learner,
                                  text: "頭が痛いです",
                                  directorJSON: .object(["scene_control": .string("continue")]))
        try await db.write { database in
            try SessionRow(session).insert(database)
            try TranscriptTurnRecord(turn).insert(database)
        }
        let seqs = try await db.read { try Int.fetchAll($0, sql: "SELECT seq FROM transcript_turn") }
        #expect(seqs == [1])
    }
}
