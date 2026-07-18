import Foundation
import GRDB
import CoreModels

// GRDB record types mirroring the §4.7 tables 1:1. They exist so column naming
// (snake_case) and storage encodings (UUID → text, JSON → text) stay identical
// between local SQLite and Supabase Postgres. Convert at the DAO boundary;
// the rest of the app speaks CoreModels value types.

private func encodeJSON(_ value: JSONValue) throws -> String {
    String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
}

private func decodeJSON(_ string: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(string.utf8))
}

// MARK: - content_item

public struct ContentItemRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "content_item"

    public var id: String
    public var language: String
    public var kind: String
    public var payload: String
    public var band: String?
    public var frequencyRank: Int?
    public var source: String?
    public var license: String?

    enum CodingKeys: String, CodingKey {
        case id, language, kind, payload, band
        case frequencyRank = "frequency_rank"
        case source, license
    }

    public init(_ item: ContentItem) throws {
        self.id = item.id.rawValue
        self.language = item.language.rawValue
        self.kind = item.kind.rawValue
        self.payload = try encodeJSON(item.payload)
        self.band = item.band
        self.frequencyRank = item.frequencyRank
        self.source = item.source
        self.license = item.license
    }

    public func asContentItem() throws -> ContentItem {
        guard let kind = ContentKind(rawValue: kind) else {
            throw PersistenceError.corruptRow(table: Self.databaseTableName, id: id)
        }
        return ContentItem(
            id: ItemID(rawValue: id), language: LanguageID(rawValue: language),
            kind: kind, payload: try decodeJSON(payload),
            band: band, frequencyRank: frequencyRank, source: source, license: license
        )
    }
}

// MARK: - item_link

public struct ItemLinkRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "item_link"

    public var fromID: String
    public var toID: String
    public var relation: String

    enum CodingKeys: String, CodingKey {
        case fromID = "from_id"
        case toID = "to_id"
        case relation
    }

    public init(_ link: ItemLink) {
        self.fromID = link.fromID.rawValue
        self.toID = link.toID.rawValue
        self.relation = link.relation.rawValue
    }
}

// MARK: - skill_state

public struct SkillStateRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "skill_state"

    public var itemID: String
    public var dimension: String
    public var stability: Double?
    public var difficulty: Double?
    public var due: Date?
    public var lastReview: Date?
    public var reps: Int
    public var lapses: Int
    public var suspended: Bool

    enum CodingKeys: String, CodingKey {
        case itemID = "item_id"
        case dimension, stability, difficulty, due
        case lastReview = "last_review"
        case reps, lapses, suspended
    }

    public init(_ state: SkillState) {
        self.itemID = state.itemID.rawValue
        self.dimension = state.dimension.rawValue
        self.stability = state.stability
        self.difficulty = state.difficulty
        self.due = state.due
        self.lastReview = state.lastReview
        self.reps = state.reps
        self.lapses = state.lapses
        self.suspended = state.suspended
    }

    public func asSkillState() throws -> SkillState {
        guard let dimension = SkillDimension(rawValue: dimension) else {
            throw PersistenceError.corruptRow(table: Self.databaseTableName, id: itemID)
        }
        return SkillState(
            itemID: ItemID(rawValue: itemID), dimension: dimension,
            stability: stability, difficulty: difficulty, due: due,
            lastReview: lastReview, reps: reps, lapses: lapses, suspended: suspended
        )
    }
}

// MARK: - review_event (append-only)

public struct ReviewEventRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "review_event"

    public var id: String
    public var itemID: String
    public var dimension: String
    public var grade: Int
    public var modeID: String?
    public var sessionID: String?
    public var latencyMS: Int?
    public var at: Date

    enum CodingKeys: String, CodingKey {
        case id
        case itemID = "item_id"
        case dimension, grade
        case modeID = "mode_id"
        case sessionID = "session_id"
        case latencyMS = "latency_ms"
        case at
    }

    public init(_ event: ReviewEvent) {
        self.id = event.id.uuidString
        self.itemID = event.itemID.rawValue
        self.dimension = event.dimension.rawValue
        self.grade = event.grade.rawValue
        self.modeID = event.modeID
        self.sessionID = event.sessionID?.uuidString
        self.latencyMS = event.latencyMS
        self.at = event.at
    }
}

// MARK: - error_event (append-only)

public struct ErrorEventRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "error_event"

    public var id: String
    public var sessionID: String?
    public var itemID: String?
    public var category: String
    public var surface: String?
    public var expected: String?
    public var severity: String?
    public var at: Date

    enum CodingKeys: String, CodingKey {
        case id
        case sessionID = "session_id"
        case itemID = "item_id"
        case category, surface, expected, severity, at
    }

    public init(_ event: ErrorEvent) {
        self.id = event.id.uuidString
        self.sessionID = event.sessionID?.uuidString
        self.itemID = event.itemID?.rawValue
        self.category = event.category.rawValue
        self.surface = event.surface
        self.expected = event.expected
        self.severity = event.severity
        self.at = event.at
    }
}

// MARK: - session

public struct SessionRow: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "session"

    public var id: String
    public var modeID: String
    public var scenarioID: String?
    public var startedAt: Date
    public var endedAt: Date?
    public var status: String?
    public var score: String?
    public var costUSD: Double?
    public var pipeline: String?

    enum CodingKeys: String, CodingKey {
        case id
        case modeID = "mode_id"
        case scenarioID = "scenario_id"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case status, score
        case costUSD = "cost_usd"
        case pipeline
    }

    public init(_ session: SessionRecord) throws {
        self.id = session.id.uuidString
        self.modeID = session.modeID
        self.scenarioID = session.scenarioID?.rawValue
        self.startedAt = session.startedAt
        self.endedAt = session.endedAt
        self.status = session.status?.rawValue
        self.score = try session.score.map(encodeJSON)
        self.costUSD = session.costUSD
        self.pipeline = session.pipeline?.rawValue
    }

    public func asSessionRecord() throws -> SessionRecord {
        guard let uuid = UUID(uuidString: id) else {
            throw PersistenceError.corruptRow(table: Self.databaseTableName, id: id)
        }
        return SessionRecord(
            id: uuid, modeID: modeID,
            scenarioID: scenarioID.map(ItemID.init(rawValue:)),
            startedAt: startedAt, endedAt: endedAt,
            status: status.flatMap(SessionStatus.init(rawValue:)),
            score: try score.map(decodeJSON),
            costUSD: costUSD,
            pipeline: pipeline.flatMap(SessionPipeline.init(rawValue:))
        )
    }
}

// MARK: - transcript_turn

public struct TranscriptTurnRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "transcript_turn"

    public var sessionID: String
    public var seq: Int
    public var role: String
    public var text: String?
    public var audioRef: String?
    public var directorJSON: String?
    public var at: Date

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case seq, role, text
        case audioRef = "audio_ref"
        case directorJSON = "director_json"
        case at
    }

    public init(_ turn: TranscriptTurn) throws {
        self.sessionID = turn.sessionID.uuidString
        self.seq = turn.seq
        self.role = turn.role.rawValue
        self.text = turn.text
        self.audioRef = turn.audioRef
        self.directorJSON = try turn.directorJSON.map(encodeJSON)
        self.at = turn.at
    }

    public func asTranscriptTurn() throws -> TranscriptTurn {
        guard let uuid = UUID(uuidString: sessionID), let role = TranscriptRole(rawValue: role) else {
            throw PersistenceError.corruptRow(table: Self.databaseTableName, id: sessionID)
        }
        return TranscriptTurn(
            sessionID: uuid, seq: seq, role: role, text: text,
            audioRef: audioRef, directorJSON: try directorJSON.map(decodeJSON), at: at
        )
    }
}

public enum PersistenceError: Error, Sendable {
    case corruptRow(table: String, id: String)
}
