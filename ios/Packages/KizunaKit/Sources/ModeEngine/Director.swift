import Foundation
import CoreModels

// The Director (§4.4): a structured-output evaluation layer, invoked after every
// learner turn on the running transcript. It never speaks to the learner — it
// tracks goals, detects confusion, calibrates difficulty, and decides (subject to
// code-enforced guardrails) when the scene may end. Decision D6: guardrails live
// in CODE, not the prompt.

// MARK: - Scenario definition (§4.4 content format)

public struct ScenarioGoal: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var required: Bool
    public var descEN: String
    public var targetItems: [ItemID]

    public init(id: String, required: Bool, descEN: String, targetItems: [ItemID] = []) {
        self.id = id
        self.required = required
        self.descEN = descEN
        self.targetItems = targetItems
    }

    enum CodingKeys: String, CodingKey {
        case id, required
        case descEN = "desc_en"
        case targetItems = "target_items"
    }
}

public struct Scenario: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var register: String
    public var band: String
    public var setting: String
    public var personaHint: String
    public var goals: [ScenarioGoal]
    public var complicationPool: [String]
    public var seedWeakItems: Bool

    public init(
        id: String, title: String, register: String, band: String, setting: String,
        personaHint: String, goals: [ScenarioGoal], complicationPool: [String] = [],
        seedWeakItems: Bool = false
    ) {
        self.id = id
        self.title = title
        self.register = register
        self.band = band
        self.setting = setting
        self.personaHint = personaHint
        self.goals = goals
        self.complicationPool = complicationPool
        self.seedWeakItems = seedWeakItems
    }

    enum CodingKeys: String, CodingKey {
        case id, title, register, band, setting
        case personaHint = "persona_hint"
        case goals
        case complicationPool = "complication_pool"
        case seedWeakItems = "seed_weak_items"
    }

    public var requiredGoalIDs: Set<String> {
        Set(goals.filter(\.required).map(\.id))
    }
}

// MARK: - Director verdict (§4.4, strict schema)

public struct DirectorVerdict: Codable, Sendable, Hashable {
    public enum GoalStatus: String, Codable, Sendable { case completed, in_progress, not_started }
    public enum BandAssessment: String, Codable, Sendable { case below, at, above }
    public enum DifficultyCommand: String, Codable, Sendable { case step_down, hold, step_up }
    public enum SceneControl: String, Codable, Sendable { case `continue`, inject_help, end_scene }
    public enum ConfusionSignal: String, Codable, Sendable {
        case repeated_misparse, silence, L1_switch, explicit, none
    }

    public struct GoalUpdate: Codable, Sendable, Hashable {
        public var goalID: String
        public var status: GoalStatus
        public var evidenceTurn: Int?
        enum CodingKeys: String, CodingKey {
            case goalID = "goal_id"
            case status
            case evidenceTurn = "evidence_turn"
        }
        public init(goalID: String, status: GoalStatus, evidenceTurn: Int? = nil) {
            self.goalID = goalID; self.status = status; self.evidenceTurn = evidenceTurn
        }
    }

    public struct LearnerBand: Codable, Sendable, Hashable {
        public var assessment: BandAssessment
        public var confidence: Double
        public init(assessment: BandAssessment, confidence: Double) {
            self.assessment = assessment; self.confidence = confidence
        }
    }

    public struct Confusion: Codable, Sendable, Hashable {
        public var detected: Bool
        public var signal: ConfusionSignal?
        public var ladderStep: Int?
        enum CodingKeys: String, CodingKey {
            case detected, signal
            case ladderStep = "ladder_step"
        }
        public init(detected: Bool, signal: ConfusionSignal? = nil, ladderStep: Int? = nil) {
            self.detected = detected; self.signal = signal; self.ladderStep = ladderStep
        }
    }

    public struct DirectorError: Codable, Sendable, Hashable {
        public var category: ErrorCategory
        public var surface: String
        public var expected: String
        public var itemRef: String?
        public var severity: String
        enum CodingKeys: String, CodingKey {
            case category, surface, expected
            case itemRef = "item_ref"
            case severity
        }
        public init(category: ErrorCategory, surface: String, expected: String, itemRef: String? = nil, severity: String) {
            self.category = category; self.surface = surface; self.expected = expected
            self.itemRef = itemRef; self.severity = severity
        }
    }

    public struct RegisterNote: Codable, Sendable, Hashable {
        public var expected: String
        public var observed: String
        public var turn: Int?
        public init(expected: String, observed: String, turn: Int? = nil) {
            self.expected = expected; self.observed = observed; self.turn = turn
        }
    }

    public var goalUpdates: [GoalUpdate]
    public var learnerBand: LearnerBand?
    public var difficultyCmd: DifficultyCommand?
    public var confusion: Confusion?
    public var errors: [DirectorError]
    public var registerNotes: [RegisterNote]
    public var actorDirective: String?
    public var sceneControl: SceneControl
    public var endReason: String?

    enum CodingKeys: String, CodingKey {
        case goalUpdates = "goal_updates"
        case learnerBand = "learner_band"
        case difficultyCmd = "difficulty_cmd"
        case confusion
        case errors
        case registerNotes = "register_notes"
        case actorDirective = "actor_directive"
        case sceneControl = "scene_control"
        case endReason = "end_reason"
    }

    public init(
        goalUpdates: [GoalUpdate] = [], learnerBand: LearnerBand? = nil,
        difficultyCmd: DifficultyCommand? = nil, confusion: Confusion? = nil,
        errors: [DirectorError] = [], registerNotes: [RegisterNote] = [],
        actorDirective: String? = nil, sceneControl: SceneControl = .continue, endReason: String? = nil
    ) {
        self.goalUpdates = goalUpdates
        self.learnerBand = learnerBand
        self.difficultyCmd = difficultyCmd
        self.confusion = confusion
        self.errors = errors
        self.registerNotes = registerNotes
        self.actorDirective = actorDirective
        self.sceneControl = sceneControl
        self.endReason = endReason
    }

    /// The safe default when structured output can't be parsed (§11 mitigation:
    /// never crash a scene on parse failure — keep going).
    public static let safeContinue = DirectorVerdict(sceneControl: .continue)

    // Tolerant decoding: unknown/missing fields degrade to safe defaults rather
    // than throwing, so a slightly-off model response never kills a scene.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        goalUpdates = (try? c.decode([GoalUpdate].self, forKey: .goalUpdates)) ?? []
        learnerBand = try? c.decodeIfPresent(LearnerBand.self, forKey: .learnerBand)
        difficultyCmd = try? c.decodeIfPresent(DifficultyCommand.self, forKey: .difficultyCmd)
        confusion = try? c.decodeIfPresent(Confusion.self, forKey: .confusion)
        errors = (try? c.decode([DirectorError].self, forKey: .errors)) ?? []
        registerNotes = (try? c.decode([RegisterNote].self, forKey: .registerNotes)) ?? []
        actorDirective = try? c.decodeIfPresent(String.self, forKey: .actorDirective)
        sceneControl = (try? c.decode(SceneControl.self, forKey: .sceneControl)) ?? .continue
        endReason = try? c.decodeIfPresent(String.self, forKey: .endReason)
    }
}

// MARK: - DirectorService

public struct DirectorInput: Sendable {
    public var scenario: Scenario
    /// The running transcript as (role, text) turns.
    public var transcript: [ChatMessage]
    public var turnIndex: Int
    /// Weak/due items to weave in (§4.4 seed_weak_items) — item ids.
    public var seedItems: [ItemID]

    public init(scenario: Scenario, transcript: [ChatMessage], turnIndex: Int, seedItems: [ItemID] = []) {
        self.scenario = scenario
        self.transcript = transcript
        self.turnIndex = turnIndex
        self.seedItems = seedItems
    }
}

/// Runs the structured-output Director call after each learner turn (§4.4).
public protocol DirectorService: Sendable {
    func evaluateTurn(_ input: DirectorInput) async throws -> DirectorVerdict
}

/// Live Director: a structured-output `ChatProvider` call against the server-side
/// `director_turn` template. Invalid JSON is retried once, then falls back to
/// `.safeContinue` — a scene is never crashed by a bad verdict (§11).
public struct LiveDirectorService: DirectorService {
    let chat: any ChatProvider
    let templateID: String
    let schema: JSONSchema

    public init(chat: any ChatProvider, templateID: String = "director_turn", schema: JSONSchema = JSONSchema(.object([:]))) {
        self.chat = chat
        self.templateID = templateID
        self.schema = schema
    }

    public func evaluateTurn(_ input: DirectorInput) async throws -> DirectorVerdict {
        let req = ChatRequest(
            templateID: templateID,
            variables: [
                "scenario_id": .string(input.scenario.id),
                "register": .string(input.scenario.register),
                "band": .string(input.scenario.band),
                "turn_index": .number(Double(input.turnIndex)),
            ],
            messages: input.transcript
        )
        for attempt in 0..<2 {
            do {
                return try await chat.completeStructured(req, schema: schema, as: DirectorVerdict.self)
            } catch {
                if attempt == 1 { return .safeContinue }
            }
        }
        return .safeContinue
    }
}
