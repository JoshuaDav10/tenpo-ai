import Testing
import Foundation
@testable import ContentKit
import CoreModels
import Persistence

struct SeedMissingKindsTests {

    /// A throwaway bundle directory containing only a lessons seed file.
    private func fixtureBundle() throws -> Bundle {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("seed-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = """
        { "items": [ { "id": "lesson:test_v1", "band": "N5.1", "topic_en": "t",
                       "steps": [ { "kind": "wrap" } ] } ] }
        """
        try Data(json.utf8).write(to: dir.appendingPathComponent("lessons_n5.json"))
        return try #require(Bundle(url: dir))
    }

    @Test func topsUpOnlyKindsWithZeroRows_andIsIdempotent() async throws {
        let db = try DatabaseManager.inMemory()
        let content = LiveContentService(db: db)

        // Simulate a device seeded before lessons existed: vocab present, no lessons.
        try await content.upsert([ContentItem(
            id: ItemID(rawValue: "vocab:x"), language: .japanese, kind: .vocab,
            payload: .object(["lemma": .string("x")]))])

        // seedIfEmpty must NOT fire (store non-empty) — the exact gap this closes.
        #expect(try await content.seedIfEmpty(from: fixtureBundle(), subdirectory: nil) == 0)

        let inserted = try await content.seedMissingKinds(from: fixtureBundle(), subdirectory: nil)
        #expect(inserted == 1)
        #expect(try await content.items(kind: .lesson, band: nil, limit: 10).count == 1)
        // Existing vocab untouched.
        #expect(try await content.items(kind: .vocab, band: nil, limit: 10).count == 1)

        // Second run: lesson kind now populated → nothing inserted.
        #expect(try await content.seedMissingKinds(from: fixtureBundle(), subdirectory: nil) == 0)
    }
}
