import Foundation
import CoreModels
import Persistence

/// Durable session persistence (§4.6, R12). Every turn is written as it happens,
/// so a force-kill mid-session leaves a resumable transcript on disk. Transcripts
/// never depend on network success.
public protocol SessionStore: Sendable {
    func begin(_ session: SessionRecord) async throws
    func record(_ turn: TranscriptTurn) async throws
    func complete(id: UUID, status: SessionStatus, score: JSONValue?, endedAt: Date) async throws
    /// Sessions left `incomplete`/`abandoned` — offered as "resume" on relaunch (R12).
    func resumableSessions() async throws -> [SessionRecord]
    func transcript(sessionID: UUID) async throws -> [TranscriptTurn]
}

public final class LiveSessionStore: SessionStore {
    private let db: DatabaseManager

    public init(db: DatabaseManager) {
        self.db = db
    }

    public func begin(_ session: SessionRecord) async throws {
        let row = try SessionRow(session)
        try await db.write { try row.insert($0) }
    }

    public func record(_ turn: TranscriptTurn) async throws {
        let row = try TranscriptTurnRecord(turn)
        // Upsert so a resumed session re-recording a seq is idempotent.
        try await db.write { try row.save($0) }
    }

    public func complete(id: UUID, status: SessionStatus, score: JSONValue?, endedAt: Date) async throws {
        let idString = id.uuidString
        let statusString = status.rawValue
        let scoreString = try score.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        try await db.write { database in
            try database.execute(
                sql: "UPDATE session SET status = ?, score = ?, ended_at = ? WHERE id = ?",
                arguments: [statusString, scoreString, endedAt, idString]
            )
        }
    }

    public func resumableSessions() async throws -> [SessionRecord] {
        try await db.read { database in
            try SessionRow
                .filter(sql: "status IS NULL OR status IN ('incomplete', 'abandoned')")
                .order(sql: "started_at DESC")
                .fetchAll(database)
        }
        .map { try $0.asSessionRecord() }
    }

    public func transcript(sessionID: UUID) async throws -> [TranscriptTurn] {
        let id = sessionID.uuidString
        return try await db.read { database in
            try TranscriptTurnRecord
                .filter(sql: "session_id = ?", arguments: [id])
                .order(sql: "seq ASC")
                .fetchAll(database)
        }
        .map { try $0.asTranscriptTurn() }
    }
}
