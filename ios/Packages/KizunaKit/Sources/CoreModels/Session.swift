import Foundation

/// Session completion status (§4.7). `incomplete` is the R1 honest-scoring outcome:
/// too few substantive learner turns ⇒ no score, no praise.
public enum SessionStatus: String, Codable, Sendable {
    case completed, incomplete, abandoned
}

/// Which pipeline ran the session (§4.3.1).
public enum SessionPipeline: String, Codable, Sendable {
    case realtime, cascade
}

/// A learning session of any mode (§4.7 `session`).
public struct SessionRecord: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var modeID: String
    public var scenarioID: ItemID?
    public var startedAt: Date
    public var endedAt: Date?
    public var status: SessionStatus?
    public var score: JSONValue?
    public var costUSD: Double?
    public var pipeline: SessionPipeline?

    public init(
        id: UUID = UUID(), modeID: String, scenarioID: ItemID? = nil,
        startedAt: Date = Date(), endedAt: Date? = nil, status: SessionStatus? = nil,
        score: JSONValue? = nil, costUSD: Double? = nil, pipeline: SessionPipeline? = nil
    ) {
        self.id = id
        self.modeID = modeID
        self.scenarioID = scenarioID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.status = status
        self.score = score
        self.costUSD = costUSD
        self.pipeline = pipeline
    }
}

public enum TranscriptRole: String, Codable, Sendable {
    case learner, actor, system
}

/// One turn of a session transcript, persisted as it happens (R12 crash safety).
public struct TranscriptTurn: Codable, Sendable, Hashable {
    public var sessionID: UUID
    public var seq: Int
    public var role: TranscriptRole
    public var text: String?
    public var audioRef: String?
    public var directorJSON: JSONValue?
    public var at: Date

    public init(
        sessionID: UUID, seq: Int, role: TranscriptRole, text: String? = nil,
        audioRef: String? = nil, directorJSON: JSONValue? = nil, at: Date = Date()
    ) {
        self.sessionID = sessionID
        self.seq = seq
        self.role = role
        self.text = text
        self.audioRef = audioRef
        self.directorJSON = directorJSON
        self.at = at
    }
}
