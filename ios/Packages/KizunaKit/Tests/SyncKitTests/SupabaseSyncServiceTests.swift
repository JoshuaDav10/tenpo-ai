import Testing
import Foundation
import GRDB
@testable import SyncKit
import CoreModels
import Persistence

// MARK: - URLProtocol stub

/// Captures outgoing requests and serves canned responses so the sync service can be
/// exercised with no network. Routes by (method, path); records POST bodies for
/// push assertions. URLSession moves `httpBody` into `httpBodyStream`, so we read the
/// stream to recover the body.
final class SyncStub: URLProtocol, @unchecked Sendable {
    struct Captured: Sendable { let method: String; let path: String; let body: Data? }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _captured: [Captured] = []
    nonisolated(unsafe) private static var _responder: (@Sendable (String, String) -> (Int, Data))?

    static func reset(responder: @escaping @Sendable (String, String) -> (Int, Data)) {
        lock.lock(); defer { lock.unlock() }
        _captured = []; _responder = responder
    }
    static var captured: [Captured] {
        lock.lock(); defer { lock.unlock() }; return _captured
    }
    private static func record(_ c: Captured) {
        lock.lock(); defer { lock.unlock() }; _captured.append(c)
    }
    private static func respond(_ method: String, _ path: String) -> (Int, Data) {
        lock.lock(); let r = _responder; lock.unlock()
        return r?(method, path) ?? (500, Data())
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? ""
        Self.record(.init(method: method, path: path, body: Self.body(of: request)))
        let (status, data) = Self.respond(method, path)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func body(of request: URLRequest) -> Data? {
        if let b = request.httpBody { return b }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open(); defer { stream.close() }
        var data = Data()
        let size = 4096
        var buf = [UInt8](repeating: 0, count: size)
        while stream.hasBytesAvailable {
            let read = stream.read(&buf, maxLength: size)
            if read <= 0 { break }
            data.append(buf, count: read)
        }
        return data
    }
}

// MARK: - helpers

private func makeService(_ db: DatabaseManager) -> (SupabaseSyncService, URLSession) {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [SyncStub.self]
    let session = URLSession(configuration: config)
    let cfg = SupabaseConfig(
        restURL: URL(string: "https://example.supabase.co/rest/v1")!,
        anonKey: "anon", userID: "user-42", accessToken: { "jwt-token" }
    )
    return (SupabaseSyncService(db: db, config: cfg, session: session), session)
}

/// Encode a record the same way the service will read it, so canned "remote" rows
/// round-trip through the exact date/coding strategy in use (ISO-8601, not the
/// Foundation default reference-date double that Postgres would reject).
private func remoteJSON<R: Encodable>(_ rows: [R]) -> Data {
    try! PostgRESTCoding.encoder().encode(rows)
}

// Serialized: the URLProtocol stub holds process-global state (URLSession owns the
// protocol instances, so per-test isolation isn't possible), and these tests each
// reset + assert on it.
@Suite(.serialized) struct SupabaseSyncServiceTests {

    @Test func pushInjectsUserIDAndTargetsRightTable() async throws {
        let db = try DatabaseManager.inMemory()
        // One local skill_state row to push.
        let state = SkillState(itemID: ItemID(rawValue: "vocab_1"), dimension: .recognitionReading,
                               stability: 3.0, difficulty: 5.0, due: Date(), lastReview: Date(),
                               reps: 2, lapses: 0, suspended: false)
        try await db.write { try SkillStateRecord(state).insert($0) }

        SyncStub.reset { method, _ in method == "GET" ? (200, remoteJSON([SkillStateRecord]())) : (201, Data()) }
        let (service, _) = makeService(db)
        try await service.syncNow()

        let posts = SyncStub.captured.filter { $0.method == "POST" && $0.path.hasSuffix("/skill_state") }
        #expect(posts.count == 1)
        let objects = try JSONSerialization.jsonObject(with: posts[0].body ?? Data()) as? [[String: Any]]
        #expect(objects?.count == 1)
        // RLS scoping: every pushed row carries the owner's user_id.
        #expect(objects?.first?["user_id"] as? String == "user-42")
        #expect(objects?.first?["item_id"] as? String == "vocab_1")
    }

    @Test func pullAppliesLastWriteWinsBySkillStateLastReview() async throws {
        let db = try DatabaseManager.inMemory()
        let t1 = Date(timeIntervalSince1970: 1_000_000)
        let t2 = t1.addingTimeInterval(3600) // newer

        // Local "x" is OLDER than remote → remote should win. Local "y" is NEWER → local kept.
        let localX = SkillState(itemID: ItemID(rawValue: "x"), dimension: .recognitionReading,
                                stability: 1.0, difficulty: 5, due: t1, lastReview: t1, reps: 1, lapses: 0, suspended: false)
        let localY = SkillState(itemID: ItemID(rawValue: "y"), dimension: .recognitionReading,
                                stability: 9.0, difficulty: 5, due: t2, lastReview: t2, reps: 5, lapses: 0, suspended: false)
        try await db.write { d in try SkillStateRecord(localX).insert(d); try SkillStateRecord(localY).insert(d) }

        // Remote: "x" newer (stability 7 wins), "y" older (stability 2 loses).
        let remoteX = SkillState(itemID: ItemID(rawValue: "x"), dimension: .recognitionReading,
                                 stability: 7.0, difficulty: 5, due: t2, lastReview: t2, reps: 3, lapses: 0, suspended: false)
        let remoteY = SkillState(itemID: ItemID(rawValue: "y"), dimension: .recognitionReading,
                                 stability: 2.0, difficulty: 5, due: t1, lastReview: t1, reps: 1, lapses: 0, suspended: false)
        let remoteRows = remoteJSON([SkillStateRecord(remoteX), SkillStateRecord(remoteY)])

        SyncStub.reset { method, path in
            guard method == "GET" else { return (201, Data()) }
            return path.contains("skill_state") ? (200, remoteRows) : (200, remoteJSON([SkillStateRecord]()))
        }
        let (service, _) = makeService(db)
        try await service.syncNow()

        let (sx, sy): (Double?, Double?) = try await db.read { d in
            let x = try SkillStateRecord.fetchOne(d, sql: "SELECT * FROM skill_state WHERE item_id = 'x'")
            let y = try SkillStateRecord.fetchOne(d, sql: "SELECT * FROM skill_state WHERE item_id = 'y'")
            return (x?.stability, y?.stability)
        }
        #expect(sx == 7.0) // remote newer won
        #expect(sy == 9.0) // local newer kept

        // Regression: the pull GET must target the table as a clean path with the
        // `select` as a real query — not a percent-encoded `skill_state?select=*` path.
        let get = SyncStub.captured.first { $0.method == "GET" && $0.path.hasSuffix("/skill_state") }
        #expect(get != nil)
    }

    @Test func pullAppendOnlyIgnoresDuplicatePrimaryKeys() async throws {
        let db = try DatabaseManager.inMemory()
        let existingID = UUID()
        let existing = ReviewEvent(id: existingID, itemID: ItemID(rawValue: "a"), dimension: .recognitionReading,
                                   grade: .good, modeID: "m", sessionID: nil, latencyMS: 100, at: Date())
        try await db.write { try ReviewEventRecord(existing).insert($0) }

        // Remote returns the same id (dup) plus a brand-new one.
        let dup = ReviewEventRecord(existing)
        let fresh = ReviewEventRecord(ReviewEvent(id: UUID(), itemID: ItemID(rawValue: "b"), dimension: .recognitionReading,
                                                  grade: .again, modeID: "m", sessionID: nil, latencyMS: 200, at: Date()))
        let remoteRows = remoteJSON([dup, fresh])

        SyncStub.reset { method, path in
            guard method == "GET" else { return (201, Data()) }
            return path.contains("review_event") ? (200, remoteRows) : (200, remoteJSON([ReviewEventRecord]()))
        }
        let (service, _) = makeService(db)
        try await service.syncNow()

        let count = try await db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM review_event") ?? 0 }
        #expect(count == 2) // dup ignored, fresh inserted — no crash, no duplicate
    }

    @Test func pushEncodesTimestampsAsISO8601ForTimestamptz() async throws {
        let db = try DatabaseManager.inMemory()
        let when = Date(timeIntervalSince1970: 1_752_400_000) // fixed instant
        let state = SkillState(itemID: ItemID(rawValue: "vocab_2"), dimension: .recognitionReading,
                               stability: 1.0, difficulty: 5.0, due: when, lastReview: when,
                               reps: 1, lapses: 0, suspended: false)
        try await db.write { try SkillStateRecord(state).insert($0) }

        SyncStub.reset { method, _ in method == "GET" ? (200, remoteJSON([SkillStateRecord]())) : (201, Data()) }
        let (service, _) = makeService(db)
        try await service.syncNow()

        let post = SyncStub.captured.first { $0.method == "POST" && $0.path.hasSuffix("/skill_state") }
        let objects = try JSONSerialization.jsonObject(with: post?.body ?? Data()) as? [[String: Any]]
        let lastReview = objects?.first?["last_review"] as? String
        // Postgres timestamptz needs an ISO string, not Foundation's reference-date double.
        #expect(lastReview?.hasPrefix("2025-07-13T") == true)
        #expect(lastReview?.hasSuffix("Z") == true)
    }

    @Test func pullDecodesPostgRESTFractionalAndPlainTimestamps() throws {
        // PostgREST emits fractional seconds with a +00:00 offset; plain Z must also parse.
        let json = Data("""
        [{"item_id":"x","dimension":"recognition_reading","stability":1.0,"difficulty":5.0,
          "due":"2026-07-14T05:12:01.123456+00:00","last_review":"2026-07-14T05:12:01Z",
          "reps":1,"lapses":0,"suspended":false,"user_id":"ignored"}]
        """.utf8)
        let rows = try PostgRESTCoding.decoder().decode([SkillStateRecord].self, from: json)
        #expect(rows.count == 1)
        #expect(rows[0].due != nil)
        #expect(rows[0].lastReview != nil)
    }
}
