import Foundation
import GRDB
import CoreModels
import Persistence

/// Supabase connection for sync (§4.7). The access token is the user's Supabase
/// JWT (also used for RLS scoping server-side, so each row is owned by `userID`).
public struct SupabaseConfig: Sendable {
    public var restURL: URL           // https://<ref>.supabase.co/rest/v1
    public var anonKey: String
    public var userID: String
    public var accessToken: @Sendable () async -> String?

    public init(restURL: URL, anonKey: String, userID: String, accessToken: @escaping @Sendable () async -> String?) {
        self.restURL = restURL
        self.anonKey = anonKey
        self.userID = userID
        self.accessToken = accessToken
    }
}

/// iPhone↔iPad sync via Supabase PostgREST (§4.7): `skill_state` is last-write-wins
/// by `last_review`; `review_event`/`error_event`/`transcript_turn` are append-only
/// (merge by primary key, no conflicts by construction). Full-table upsert keeps it
/// simple and idempotent for one dogfood user.
///
/// LIVE-VERIFY: account-gated — needs a Supabase project (URL + anon key + a signed-in
/// user's JWT) and matching tables with a `user_id` column + RLS. Structurally complete.
public actor SupabaseSyncService: SyncService {
    private let db: DatabaseManager
    private let config: SupabaseConfig
    private let session: URLSession
    public private(set) var lastSyncedAt: Date?

    public init(db: DatabaseManager, config: SupabaseConfig, session: URLSession = .shared) {
        self.db = db
        self.config = config
        self.session = session
    }

    public func syncNow() async throws {
        try await push()
        try await pull()
        lastSyncedAt = Date()
    }

    // MARK: - push (local → remote upsert)

    private func push() async throws {
        try await upsert(table: "skill_state") { try SkillStateRecord.fetchAll($0) }
        try await upsert(table: "review_event") { try ReviewEventRecord.fetchAll($0) }
        try await upsert(table: "error_event") { try ErrorEventRecord.fetchAll($0) }
        try await upsert(table: "session") { try SessionRow.fetchAll($0) }
        try await upsert(table: "transcript_turn") { try TranscriptTurnRecord.fetchAll($0) }
    }

    private func upsert<R: Encodable & Sendable>(table: String, fetch: @escaping @Sendable (Database) throws -> [R]) async throws {
        let rows = try await db.read(fetch)
        guard !rows.isEmpty else { return }
        // Inject user_id into each row's JSON so RLS-scoped upserts land in the user's rows.
        let encoder = JSONEncoder()
        var objects: [[String: Any]] = []
        for row in rows {
            let data = try encoder.encode(row)
            var dict = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            dict["user_id"] = config.userID
            objects.append(dict)
        }
        let body = try JSONSerialization.data(withJSONObject: objects)
        var request = try await makeRequest(path: table, method: "POST")
        request.setValue("resolution=merge-duplicates", forHTTPHeaderField: "Prefer")
        request.httpBody = body
        _ = try await sendExpectingSuccess(request)
    }

    // MARK: - pull (remote → local merge)

    private func pull() async throws {
        try await pullSkillStateLWW()
        try await pullAppendOnly(table: "review_event", as: ReviewEventRecord.self)
        try await pullAppendOnly(table: "error_event", as: ErrorEventRecord.self)
        try await pullAppendOnly(table: "transcript_turn", as: TranscriptTurnRecord.self)
        try await pullSessionsUpsert()
    }

    private func pullSkillStateLWW() async throws {
        let remote: [SkillStateRecord] = try await fetchAll(table: "skill_state")
        try await db.write { db in
            for r in remote {
                let existing = try SkillStateRecord.fetchOne(
                    db, sql: "SELECT * FROM skill_state WHERE item_id = ? AND dimension = ?",
                    arguments: [r.itemID, r.dimension])
                // Last-write-wins by last_review (§4.7).
                let remoteNewer = (existing?.lastReview ?? .distantPast) <= (r.lastReview ?? .distantPast)
                if existing == nil || remoteNewer { try r.save(db) }
            }
        }
    }

    private func pullAppendOnly<R: FetchableRecord & PersistableRecord & Decodable & Sendable>(
        table: String, as type: R.Type
    ) async throws {
        let remote: [R] = try await fetchAll(table: table)
        try await db.write { db in
            for r in remote {
                // Append-only: insert, ignoring rows we already have (merge by PK).
                try r.insert(db, onConflict: .ignore)
            }
        }
    }

    private func pullSessionsUpsert() async throws {
        let remote: [SessionRow] = try await fetchAll(table: "session")
        try await db.write { db in
            for r in remote { try r.save(db) }
        }
    }

    private func fetchAll<R: Decodable>(table: String) async throws -> [R] {
        let request = try await makeRequest(path: "\(table)?select=*", method: "GET")
        let data = try await sendExpectingSuccess(request)
        return try JSONDecoder().decode([R].self, from: data)
    }

    // MARK: - transport

    private func makeRequest(path: String, method: String) async throws -> URLRequest {
        var request = URLRequest(url: config.restURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        if let token = await config.accessToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func sendExpectingSuccess(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw SyncError.http(status: status, body: String(decoding: data, as: UTF8.self))
        }
        return data
    }
}

public enum SyncError: Error, Sendable {
    case http(status: Int, body: String)
}
