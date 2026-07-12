import Foundation

/// Per-item, per-dimension FSRS state (§4.7 `skill_state`).
public struct SkillState: Codable, Sendable, Hashable {
    public var itemID: ItemID
    public var dimension: SkillDimension
    public var stability: Double?
    public var difficulty: Double?
    public var due: Date?
    public var lastReview: Date?
    public var reps: Int
    public var lapses: Int
    public var suspended: Bool

    public init(
        itemID: ItemID, dimension: SkillDimension,
        stability: Double? = nil, difficulty: Double? = nil,
        due: Date? = nil, lastReview: Date? = nil,
        reps: Int = 0, lapses: Int = 0, suspended: Bool = false
    ) {
        self.itemID = itemID
        self.dimension = dimension
        self.stability = stability
        self.difficulty = difficulty
        self.due = due
        self.lastReview = lastReview
        self.reps = reps
        self.lapses = lapses
        self.suspended = suspended
    }
}

/// Append-only review record (§4.7 `review_event`); feeds FSRS optimization later.
public struct ReviewEvent: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var itemID: ItemID
    public var dimension: SkillDimension
    public var grade: ReviewGrade
    public var modeID: String?
    public var sessionID: UUID?
    public var latencyMS: Int?
    public var at: Date

    public init(
        id: UUID = UUID(), itemID: ItemID, dimension: SkillDimension, grade: ReviewGrade,
        modeID: String? = nil, sessionID: UUID? = nil, latencyMS: Int? = nil, at: Date = Date()
    ) {
        self.id = id
        self.itemID = itemID
        self.dimension = dimension
        self.grade = grade
        self.modeID = modeID
        self.sessionID = sessionID
        self.latencyMS = latencyMS
        self.at = at
    }
}

public enum ErrorCategory: String, Codable, Sendable, CaseIterable {
    case vocab, grammar, particle, pronunciation, register
    case wordOrder = "word_order"
}

/// Categorized error from the Director or a drill (§4.7 `error_event`, R8).
public struct ErrorEvent: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var sessionID: UUID?
    public var itemID: ItemID?
    public var category: ErrorCategory
    public var surface: String?
    public var expected: String?
    public var severity: String?
    public var at: Date

    public init(
        id: UUID = UUID(), sessionID: UUID? = nil, itemID: ItemID? = nil,
        category: ErrorCategory, surface: String? = nil, expected: String? = nil,
        severity: String? = nil, at: Date = Date()
    ) {
        self.id = id
        self.sessionID = sessionID
        self.itemID = itemID
        self.category = category
        self.surface = surface
        self.expected = expected
        self.severity = severity
        self.at = at
    }
}
