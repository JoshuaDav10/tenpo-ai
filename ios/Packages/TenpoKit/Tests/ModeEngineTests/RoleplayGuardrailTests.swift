import Testing
import Foundation
import CoreModels
@testable import ModeEngine

// The adversarial suite (§9 Phase 3 step 8): replay the category's documented
// failures and prove our guardrails defeat them. Guardrails are code, not prompt.

/// A Director that returns a scripted queue of verdicts (repeats the last).
final class ScriptedDirector: DirectorService, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [DirectorVerdict]
    init(_ verdicts: [DirectorVerdict]) { self.queue = verdicts }
    func evaluateTurn(_ input: DirectorInput) async throws -> DirectorVerdict {
        synced {
            guard !queue.isEmpty else { return .safeContinue }
            return queue.count == 1 ? queue[0] : queue.removeFirst()
        }
    }
    private func synced<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }
}

private func pharmacy() -> Scenario {
    Scenario(
        id: "pharmacy_headache_v1", title: "薬局で", register: "polite", band: "N5.3",
        setting: "Small pharmacy in Kyoto, evening.", personaHint: "kind pharmacist",
        goals: [
            ScenarioGoal(id: "g1", required: true, descEN: "Explain you have a headache", targetItems: ["vocab:頭が痛い"]),
            ScenarioGoal(id: "g2", required: true, descEN: "Ask for a recommendation", targetItems: ["grammar:何かありますか"]),
            ScenarioGoal(id: "g3", required: false, descEN: "Ask about dosage"),
        ]
    )
}

private func completes(_ ids: [String], end: Bool = false) -> DirectorVerdict {
    DirectorVerdict(
        goalUpdates: ids.map { .init(goalID: $0, status: .completed) },
        sceneControl: end ? .end_scene : .continue
    )
}
private let noProgress = DirectorVerdict(sceneControl: .continue)
private let endBait = DirectorVerdict(sceneControl: .end_scene)  // Director *requests* end
private let confused = DirectorVerdict(confusion: .init(detected: true, signal: .repeated_misparse), sceneControl: .continue)

@Suite struct R1_OneWordSession {
    // Pingo scored 78/100 for a 25-sec one-word conversation. Our engine must not.
    @Test func oneWordSessionIsIncompleteWithNoPraiseAndNamesMissingGoals() async throws {
        let engine = RoleplayEngine(scenario: pharmacy(), director: ScriptedDirector([noProgress]))
        _ = await engine.processLearnerTurn("はい", isSubstantive: true)   // the lone word
        let outcome = await engine.finalize()

        #expect(outcome.status == .incomplete)         // no completed status
        #expect(outcome.scoreValue == 0)               // no score
        #expect(outcome.praiseAllowed == false)        // no praise (R15 in code)
        #expect(outcome.missingRequiredGoals.count == 2)
        // Feedback names the missing goals.
        #expect(outcome.focusPoints.contains { $0.contains("headache") })
    }
}

@Suite struct R3_PrematureEndBait {
    // Actor/Director "well done!" mid-scene must NOT end the scene early.
    @Test func endSceneIsIgnoredUntilRequiredGoalsComplete() async throws {
        let engine = RoleplayEngine(scenario: pharmacy(),
                                    director: ScriptedDirector([endBait, completes(["g1", "g2"], end: true)]))

        // Turn 1: Director requests end_scene but goals are incomplete → overridden.
        let d1 = await engine.processLearnerTurn("こんばんは")
        #expect(d1 == .continue(actorDirective: nil))

        // Turn 2: goals complete + end_scene → now ending is legal.
        let d2 = await engine.processLearnerTurn("頭が痛いです。何かありますか。")
        #expect(d2 == .endScene(reason: .goalsComplete))
    }
}

@Suite struct R4_StuckDetectionLadder {
    // Six retries on one word killed a Duolingo call. Our ladder escalates in order
    // and the scene always progresses — it never ends or blocks on misrecognition.
    @Test func confusionEscalatesLadderInOrderAndNeverEnds() async throws {
        let engine = RoleplayEngine(scenario: pharmacy(),
                                    director: ScriptedDirector([confused, confused, confused, confused]))
        let d1 = await engine.processLearnerTurn("…")
        let d2 = await engine.processLearnerTurn("…")
        let d3 = await engine.processLearnerTurn("…")
        let d4 = await engine.processLearnerTurn("…")

        #expect(d1 == .injectHelp(ladderStep: 1, kind: .rephraseSimpler))
        #expect(d2 == .injectHelp(ladderStep: 2, kind: .showTextFurigana))
        #expect(d3 == .injectHelp(ladderStep: 3, kind: .l1Bridge))
        #expect(d4 == .injectHelp(ladderStep: 4, kind: .logWeaknessAdvance))
        // None of these is an endScene — the scene always moves forward.
        for d in [d1, d2, d3, d4] {
            if case .endScene = d { #expect(Bool(false), "confusion must never end the scene") }
        }
    }

    @Test func ladderResetsAfterACleanTurn() async throws {
        let engine = RoleplayEngine(scenario: pharmacy(),
                                    director: ScriptedDirector([confused, noProgress, confused]))
        _ = await engine.processLearnerTurn("…")             // step 1
        _ = await engine.processLearnerTurn("頭が痛いです")   // clean → reset
        let again = await engine.processLearnerTurn("…")
        #expect(again == .injectHelp(ladderStep: 1, kind: .rephraseSimpler))  // back to step 1
    }
}

@Suite struct RoleplayCompletionTests {
    @Test func completedGoalsScoreAndAllowPraiseAndEnrollReviews() async throws {
        let engine = RoleplayEngine(scenario: pharmacy(),
                                    director: ScriptedDirector([completes(["g1"]), noProgress, completes(["g1", "g2"], end: true)]))
        _ = await engine.processLearnerTurn("こんばんは")
        _ = await engine.processLearnerTurn("頭が痛いです")
        let end = await engine.processLearnerTurn("何かありますか")
        #expect(end == .endScene(reason: .goalsComplete))

        let outcome = await engine.finalize()
        #expect(outcome.status == .completed)
        #expect(outcome.scoreValue == 100)
        #expect(outcome.praiseAllowed == true)              // earned praise is allowed
        #expect(outcome.substantiveTurns == 3)
        // Target items of completed goals enrolled as spoken-production reviews.
        let ids = Set(outcome.reviews.map(\.itemID.rawValue))
        #expect(ids.contains("vocab:頭が痛い"))
        #expect(ids.contains("grammar:何かありますか"))
    }
}

@Suite struct DirectorSafeFallbackTests {
    // §11 mitigation: invalid structured output must never crash a scene.
    @Test func liveDirectorFallsBackToContinueOnBadJSON() async throws {
        let chat = MockChatProvider()   // no canned JSON → completeStructured throws
        let director = LiveDirectorService(chat: chat)
        let verdict = try await director.evaluateTurn(DirectorInput(
            scenario: pharmacy(), transcript: [ChatMessage(role: .user, content: "はい")], turnIndex: 1
        ))
        #expect(verdict.sceneControl == .continue)
    }
}
