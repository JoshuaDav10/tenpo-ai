import Foundation
import CoreModels

// The roleplay engine (§4.4): the subsystem that must not fail. It consumes
// Director verdicts and enforces, IN CODE (Decision D6), the guardrails the whole
// category gets wrong:
//   • Only the Director's end_scene can end a scene — and only when it is LEGAL
//     (all required goals met, learner quit, or the hard time cap). An Actor
//     "goodbye" never ends the scene (R3).
//   • A session with fewer than `minSubstantiveTurns` learner turns is scored
//     `incomplete` — no score, no praise (R1).
//   • Confusion escalates a fixed ladder in order; the scene always progresses,
//     never blocks on repeated misrecognition (R4).
//   • Praise is chosen by code from score bands; the model never decides praise (R15).

public enum HelpKind: Sendable, Equatable {
    case rephraseSimpler       // ladder step 1
    case showTextFurigana      // ladder step 2
    case l1Bridge              // ladder step 3
    case logWeaknessAdvance    // ladder step 4: mark weakness, move the scene on
}

public enum EndReason: String, Sendable, Equatable {
    case goalsComplete, learnerQuit, hardCap
}

/// What the client should do after a learner turn. `endScene` is the ONLY value
/// that ends the scene, and the engine only ever returns it when legal.
public enum SceneDirective: Sendable, Equatable {
    case `continue`(actorDirective: String?)
    case injectHelp(ladderStep: Int, kind: HelpKind)
    case endScene(reason: EndReason)
}

public struct RoleplayOutcome: Sendable {
    public var status: SessionStatus
    public var scoreValue: Double          // 0–100, from goal completion (R1)
    public var praiseAllowed: Bool         // code-gated (R15)
    public var reviews: [ReviewEvent]
    public var errors: [ErrorEvent]
    public var focusPoints: [String]       // 1–3 "next time" points (R8)
    public var missingRequiredGoals: [ScenarioGoal]
    public var substantiveTurns: Int
}

public actor RoleplayEngine {
    public let scenario: Scenario
    private let director: any DirectorService
    private let sessionID: UUID
    private let minSubstantiveTurns: Int
    private let hardCap: TimeInterval
    private let praiseThreshold: Double
    private let now: @Sendable () -> Date
    private let startedAt: Date

    private var transcript: [ChatMessage] = []
    private var goalStatus: [String: DirectorVerdict.GoalStatus] = [:]
    private var substantiveTurns = 0
    private var confusionStep = 0
    private var turnIndex = 0
    private var accumulatedErrors: [DirectorVerdict.DirectorError] = []
    private var registerNotes: [DirectorVerdict.RegisterNote] = []
    private var currentBand: DirectorVerdict.BandAssessment = .at

    public init(
        scenario: Scenario, director: any DirectorService, sessionID: UUID = UUID(),
        minSubstantiveTurns: Int = 3, hardCap: TimeInterval = 600, praiseThreshold: Double = 60,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.scenario = scenario
        self.director = director
        self.sessionID = sessionID
        self.minSubstantiveTurns = minSubstantiveTurns
        self.hardCap = hardCap
        self.praiseThreshold = praiseThreshold
        self.now = now
        self.startedAt = now()
        for goal in scenario.goals { goalStatus[goal.id] = .not_started }
    }

    public func seedActorTurn(_ text: String) {
        transcript.append(ChatMessage(role: .assistant, content: text))
    }

    /// Process one learner turn. `isSubstantive` = a real content-bearing turn in
    /// the target language (a filler like "はい" is not).
    public func processLearnerTurn(_ text: String, isSubstantive: Bool = true) async -> SceneDirective {
        transcript.append(ChatMessage(role: .user, content: text))
        turnIndex += 1
        if isSubstantive { substantiveTurns += 1 }

        // A thrown Director error must never crash the scene (§11): fall back to continue.
        let verdict = (try? await director.evaluateTurn(DirectorInput(
            scenario: scenario, transcript: transcript, turnIndex: turnIndex
        ))) ?? .safeContinue

        for update in verdict.goalUpdates { goalStatus[update.goalID] = update.status }
        accumulatedErrors.append(contentsOf: verdict.errors)
        registerNotes.append(contentsOf: verdict.registerNotes)
        if let band = verdict.learnerBand?.assessment { currentBand = band }
        if let directive = verdict.actorDirective {
            transcript.append(ChatMessage(role: .system, content: directive))
        }

        // Confusion ladder (R4): escalate in order; reset on a clean turn.
        if verdict.confusion?.detected == true {
            confusionStep += 1
            let kind: HelpKind
            switch confusionStep {
            case 1: kind = .rephraseSimpler
            case 2: kind = .showTextFurigana
            case 3: kind = .l1Bridge
            default:
                kind = .logWeaknessAdvance
                logConfusionWeakness()
                confusionStep = 0   // logged & advanced — reset the ladder
            }
            // The scene ALWAYS progresses through help; it never ends on confusion.
            return .injectHelp(ladderStep: min(confusionStep == 0 ? 4 : confusionStep, 4), kind: kind)
        } else {
            confusionStep = 0
        }

        // End-scene guardrail (R3, D6): the Director's end_scene is a REQUEST; the
        // engine only honors it when ending is legal.
        if verdict.sceneControl == .end_scene, canLegallyEnd() {
            return .endScene(reason: allRequiredGoalsComplete() ? .goalsComplete : .hardCap)
        }
        return .continue(actorDirective: verdict.actorDirective)
    }

    /// The learner explicitly ended the scene — always legal (R3 clause b).
    public func learnerQuit() -> SceneDirective { .endScene(reason: .learnerQuit) }

    public func currentBandAssessment() -> DirectorVerdict.BandAssessment { currentBand }

    /// Required-goal progress for the HUD (R1 — honest scoring visible).
    public func progress() -> (completed: Int, total: Int) {
        let required = scenario.goals.filter(\.required)
        let done = required.filter { goalStatus[$0.id] == .completed }.count
        return (done, required.count)
    }

    public func transcriptMessages() -> [ChatMessage] { transcript }

    // MARK: - Finalization

    /// Post-session evaluation → categorized errors, per-item review grades, focus
    /// points, and a code-selected praise gate (§4.4, R8, R15).
    public func finalize(learnerQuit: Bool = false) -> RoleplayOutcome {
        let missing = scenario.goals.filter { $0.required && goalStatus[$0.id] != .completed }
        let requiredCount = scenario.goals.filter(\.required).count
        let completedRequired = requiredCount - missing.count
        let score = requiredCount == 0 ? 0 : (Double(completedRequired) / Double(requiredCount)) * 100

        // R1 hard floor: too few substantive turns ⇒ incomplete, no score, no praise.
        let status: SessionStatus
        if substantiveTurns < minSubstantiveTurns {
            status = .incomplete
        } else if missing.isEmpty {
            status = .completed
        } else {
            status = learnerQuit ? .abandoned : .completed
        }

        let praiseAllowed = status == .completed && score >= praiseThreshold

        var reviews: [ReviewEvent] = []
        // Completed goals' target items → a spoken-production success.
        for goal in scenario.goals where goalStatus[goal.id] == .completed {
            for item in goal.targetItems {
                reviews.append(ReviewEvent(itemID: item, dimension: .productionSpoken, grade: .good,
                                           modeID: "roleplay", sessionID: sessionID))
            }
        }
        // Director errors → lapses on the referenced item (R8).
        var errorEvents: [ErrorEvent] = []
        for e in accumulatedErrors {
            let itemID = e.itemRef.map(ItemID.init(rawValue:))
            errorEvents.append(ErrorEvent(sessionID: sessionID, itemID: itemID, category: e.category,
                                          surface: e.surface, expected: e.expected, severity: e.severity))
            if let itemID {
                let grade: ReviewGrade = e.severity == "recurring" ? .again : .hard
                reviews.append(ReviewEvent(itemID: itemID, dimension: .productionSpoken, grade: grade,
                                           modeID: "roleplay", sessionID: sessionID))
            }
        }

        return RoleplayOutcome(
            status: status, scoreValue: status == .incomplete ? 0 : score,
            praiseAllowed: praiseAllowed, reviews: reviews, errors: errorEvents,
            focusPoints: focusPoints(missing: missing), missingRequiredGoals: missing,
            substantiveTurns: substantiveTurns
        )
    }

    // MARK: - Guardrail helpers

    private func allRequiredGoalsComplete() -> Bool {
        scenario.requiredGoalIDs.allSatisfy { goalStatus[$0] == .completed }
    }

    private func canLegallyEnd() -> Bool {
        allRequiredGoalsComplete() || now().timeIntervalSince(startedAt) >= hardCap
    }

    private func logConfusionWeakness() {
        accumulatedErrors.append(DirectorVerdict.DirectorError(
            category: .pronunciation, surface: "(repeated confusion)", expected: "",
            itemRef: nil, severity: "recurring"
        ))
    }

    private func focusPoints(missing: [ScenarioGoal]) -> [String] {
        var points: [String] = []
        // Name the missing required goals first (R1: feedback names missing goals).
        for goal in missing.prefix(2) { points.append("Next time: \(goal.descEN)") }
        // Then the most common error category.
        let categories = Dictionary(grouping: accumulatedErrors, by: \.category)
            .sorted { $0.value.count > $1.value.count }
        if let top = categories.first, points.count < 3 {
            points.append("Focus area: \(top.key.rawValue) (\(top.value.count) slip\(top.value.count == 1 ? "" : "s"))")
        }
        return points
    }
}
