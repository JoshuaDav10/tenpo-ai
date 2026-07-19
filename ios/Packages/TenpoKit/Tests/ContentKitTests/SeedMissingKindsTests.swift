import Testing
import Foundation
@testable import ContentKit
import CoreModels
import Persistence

struct SeedSyncTests {

    /// A throwaway bundle directory containing only a lessons seed file.
    private func fixtureBundle(topicEN: String = "t") throws -> Bundle {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("seed-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = """
        { "items": [ { "id": "lesson:test_v1", "band": "N5.1", "topic_en": "\(topicEN)",
                       "steps": [ { "kind": "wrap" } ] } ] }
        """
        try Data(json.utf8).write(to: dir.appendingPathComponent("lessons_n5.json"))
        return try #require(Bundle(url: dir))
    }

    @Test func upsertsBundledSeedIntoPopulatedStores_andPropagatesUpdates() async throws {
        let db = try DatabaseManager.inMemory()
        let content = LiveContentService(db: db)

        // Simulate a device seeded before lessons existed: vocab present, no lessons.
        try await content.upsert([ContentItem(
            id: ItemID(rawValue: "vocab:x"), language: .japanese, kind: .vocab,
            payload: .object(["lemma": .string("x")]))])

        // seedIfEmpty must NOT fire (store non-empty) — the exact gap seedSync closes.
        #expect(try await content.seedIfEmpty(from: fixtureBundle(), subdirectory: nil) == 0)

        #expect(try await content.seedSync(from: fixtureBundle(), subdirectory: nil) == 1)
        #expect(try await content.items(kind: .lesson, band: nil, limit: 10).count == 1)
        // Non-seed rows untouched.
        #expect(try await content.items(kind: .vocab, band: nil, limit: 10).count == 1)

        // An authored update to an existing seed id reaches the store on next sync.
        _ = try await content.seedSync(from: fixtureBundle(topicEN: "updated topic"), subdirectory: nil)
        let lesson = try await content.item(id: ItemID(rawValue: "lesson:test_v1"))
        #expect(lesson?.payload["topic_en"]?.stringValue == "updated topic")
        // Still exactly one row — upsert, not duplicate.
        #expect(try await content.items(kind: .lesson, band: nil, limit: 10).count == 1)
    }
}
