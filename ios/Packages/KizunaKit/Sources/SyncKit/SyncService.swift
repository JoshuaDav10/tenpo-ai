import Foundation
import CoreModels

/// iPhone↔iPad sync via Supabase (§4.7 sync rules): skill_state last-write-wins
/// by last_review; review/error/transcript tables append-only merge.
/// Live implementation lands in Phase 4; the protocol exists so the container
/// graph is stable from day one.
public protocol SyncService: Sendable {
    func syncNow() async throws
    var lastSyncedAt: Date? { get async }
}

/// No-op sync for Phase 0–3 and tests.
public actor NoopSyncService: SyncService {
    public private(set) var lastSyncedAt: Date?

    public init() {}

    public func syncNow() async throws {
        lastSyncedAt = Date()
    }
}
