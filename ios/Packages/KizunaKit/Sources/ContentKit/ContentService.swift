import Foundation
import CoreModels
import Persistence

/// Curriculum store: items, sentences, scenarios, audio cache (§4.2).
/// Phase 1 adds the import pipeline (JMdict, KANJIDIC2, Kanjium, Tatoeba)
/// and scenario templates; Phase 0 provides CRUD over content_item.
public protocol ContentService: Sendable {
    func item(id: ItemID) async throws -> ContentItem?
    func items(kind: ContentKind, band: String?, limit: Int) async throws -> [ContentItem]
    func upsert(_ items: [ContentItem]) async throws
    func itemCount() async throws -> Int
}

public final class LiveContentService: ContentService {
    private let db: DatabaseManager

    public init(db: DatabaseManager) {
        self.db = db
    }

    public func item(id: ItemID) async throws -> ContentItem? {
        let key = id.rawValue
        return try await db.read { database in
            try ContentItemRecord.fetchOne(database, key: key)
        }
        .map { try $0.asContentItem() }
    }

    public func items(kind: ContentKind, band: String?, limit: Int) async throws -> [ContentItem] {
        let kindValue = kind.rawValue
        return try await db.read { database in
            var request = ContentItemRecord
                .filter(sql: "kind = ?", arguments: [kindValue])
            if let band {
                request = request.filter(sql: "band = ?", arguments: [band])
            }
            return try request
                .order(sql: "frequency_rank IS NULL, frequency_rank")
                .limit(limit)
                .fetchAll(database)
        }
        .map { try $0.asContentItem() }
    }

    public func upsert(_ items: [ContentItem]) async throws {
        let records = try items.map(ContentItemRecord.init)
        try await db.write { database in
            for record in records {
                try record.save(database)
            }
        }
    }

    public func itemCount() async throws -> Int {
        try await db.read { database in
            try ContentItemRecord.fetchCount(database)
        }
    }
}
