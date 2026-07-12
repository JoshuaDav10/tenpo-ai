import Foundation
import CoreModels
import Persistence

/// The app's spine (§4.5). Every mode reports evidence here; the daily queue
/// comes from here. FSRS-6 scheduling lands in Phase 1 — Phase 0 provides the
/// protocol, persistence-backed skeleton, and mock.
public protocol LearnerModelService: Sendable {
    /// Items for a session plan: due reviews first, then new items (§4.5 queue builder).
    func requestItems(count: Int, dimension: SkillDimension?) async throws -> [ContentItem]
    /// Ingest review evidence from any mode; updates FSRS state (Phase 1).
    func report(_ event: ReviewEvent) async throws
    /// Ingest a categorized error (Director or drill) — R8 pipeline.
    func report(_ event: ErrorEvent) async throws
    /// Dashboard: item counts per dimension (learning / young / mature bands in Phase 1).
    func trackedItemCount() async throws -> Int
}

/// Persistence-backed implementation. Review/error events are durably recorded
/// now; FSRS state updates and queue building are Phase 1.
public final class LiveLearnerModelService: LearnerModelService {
    private let db: DatabaseManager

    public init(db: DatabaseManager) {
        self.db = db
    }

    public func requestItems(count: Int, dimension: SkillDimension?) async throws -> [ContentItem] {
        try await db.read { database in
            try ContentItemRecord
                .order(sql: "frequency_rank IS NULL, frequency_rank")
                .limit(count)
                .fetchAll(database)
        }
        .map { try $0.asContentItem() }
    }

    public func report(_ event: ReviewEvent) async throws {
        let record = ReviewEventRecord(event)
        try await db.write { database in
            try record.insert(database)
        }
    }

    public func report(_ event: ErrorEvent) async throws {
        let record = ErrorEventRecord(event)
        try await db.write { database in
            try record.insert(database)
        }
    }

    public func trackedItemCount() async throws -> Int {
        try await db.read { database in
            try SkillStateRecord.fetchCount(database)
        }
    }
}

/// In-memory mock for tests and previews.
public final class MockLearnerModelService: LearnerModelService, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ContentItem]
    private var _reviewEvents: [ReviewEvent] = []
    private var _errorEvents: [ErrorEvent] = []

    public var reviewEvents: [ReviewEvent] { synced { _reviewEvents } }
    public var errorEvents: [ErrorEvent] { synced { _errorEvents } }

    public init(items: [ContentItem] = []) {
        self.items = items
    }

    public func requestItems(count: Int, dimension: SkillDimension?) async throws -> [ContentItem] {
        synced { Array(items.prefix(count)) }
    }

    public func report(_ event: ReviewEvent) async throws {
        synced { _reviewEvents.append(event) }
    }

    public func report(_ event: ErrorEvent) async throws {
        synced { _errorEvents.append(event) }
    }

    public func trackedItemCount() async throws -> Int {
        synced { items.count }
    }

    private func synced<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
