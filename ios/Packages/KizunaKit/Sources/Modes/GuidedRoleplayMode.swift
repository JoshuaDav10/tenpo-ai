import Foundation
import CoreModels
import ContentKit
import SpeechKit
import ModeEngine

/// Mode 8 (§4.6): Director/Actor roleplay with a goal HUD. This is the cheap-mode
/// (cascade, §4.3.6) path — the Actor is a text completion and learner speech is
/// transcribed on-device — so it runs and is testable without the Realtime API.
/// The realtime speech-to-speech Actor swaps in behind the same RoleplayEngine.
///
/// All the load-bearing guarantees (end-scene legality, min-turns floor, confusion
/// ladder, code-gated praise) live in RoleplayEngine (§4.4, D6) — this mode is just
/// the orchestration + event plumbing over it.
public struct GuidedRoleplayMode: LearningMode {
    public static let descriptor = ModeDescriptor(
        id: "roleplay.guided",
        name: "Roleplay",
        dimensions: [.productionSpoken],
        needsRealtime: false,      // cheap-mode; realtime variant is a separate descriptor
        needsNetwork: true
    )

    let context: ModeContext
    public init(context: ModeContext) { self.context = context }

    public func makeSession(plan: SessionPlan) -> any ModeSession {
        GuidedRoleplaySession(plan: plan, context: context)
    }
}

actor GuidedRoleplaySession: ModeSession {
    nonisolated let events: AsyncStream<ModeEvent>
    private nonisolated let continuation: AsyncStream<ModeEvent>.Continuation

    private let plan: SessionPlan
    private let context: ModeContext
    private let scenario: Scenario
    private let persona: PersonaID
    private var engine: RoleplayEngine

    private var finalOutcome: RoleplayOutcome?
    private var ended = false

    init(plan: SessionPlan, context: ModeContext, persona: PersonaID = .warmTutor) {
        self.plan = plan
        self.context = context
        self.persona = persona
        // Prefer a scenario carried on the plan's items; else a minimal fallback so
        // the mode never crashes on a missing scenario.
        let scenario = plan.items.compactMap(Scenario.init).first ?? Self.fallbackScenario
        self.scenario = scenario
        let director = context.director ?? StubDirector()
        // Seed items are resolved in start() (async); engine is rebuilt there if needed.
        self.engine = RoleplayEngine(scenario: scenario, director: director, sessionID: plan.sessionID)

        var cont: AsyncStream<ModeEvent>.Continuation!
        self.events = AsyncStream { cont = $0 }
        self.continuation = cont
    }

    func start() async {
        // Moat loop (§3.2): if the scenario opts in, pull the learner's weak/due items
        // in this band and hand them to the Director to elicit naturally.
        if scenario.seedWeakItems {
            let prefix = String(scenario.band.prefix(2))   // e.g. "N5"
            let weak = (try? await context.learner.weakItems(bandPrefix: prefix, count: 3)) ?? []
            if !weak.isEmpty {
                let director = context.director ?? StubDirector()
                engine = RoleplayEngine(scenario: scenario, director: director,
                                        sessionID: plan.sessionID, seedItems: weak.map(\.id))
                continuation.yield(.info("Weaving in \(weak.count) word\(weak.count == 1 ? "" : "s") you're due to review."))
            }
        }

        continuation.yield(.info("『\(scenario.title)』 — \(scenario.setting)"))
        let (_, total) = await engine.progress()
        continuation.yield(.goalProgress(completed: 0, total: total))
        let opening = await actor.openingLine(scenario: scenario, persona: persona)
        await engine.seedActorTurn(opening)
        continuation.yield(.prompt(text: opening, audio: nil))
    }

    func handle(_ input: LearnerInput) async {
        guard !ended else { return }
        switch input {
        case .quit:
            _ = await engine.learnerQuit()
            await finishScene(learnerQuit: true)

        case .requestHint:
            continuation.yield(.info("Try saying it a simpler way, or ask the other person to repeat."))

        case .tap:
            continuation.yield(.info("Type or speak your line."))

        case .text(let line):
            await takeTurn(line)

        case .speech(let clip):
            // Cheap-mode: transcribe on-device, then feed the text to the engine.
            let heard = try? await context.speech.onDeviceSTT.transcribe(clip, locale: context.pack.id, hints: [])
            let line = heard?.text ?? ""
            if let heard { continuation.yield(.heard(heard)) }
            await takeTurn(line)
        }
    }

    func finish() async -> ModeResult {
        if finalOutcome == nil { await finishScene(learnerQuit: false) }
        return Self.result(from: finalOutcome, duration: 0)
    }

    // MARK: - turn handling

    private func takeTurn(_ line: String) async {
        let substantive = !line.trimmingCharacters(in: .whitespaces).isEmpty
        if substantive {
            continuation.yield(.heard(Transcription(text: line, confidence: 1, provider: "learner")))
        }
        let directive = await engine.processLearnerTurn(line, isSubstantive: substantive)

        let (done, total) = await engine.progress()
        continuation.yield(.goalProgress(completed: done, total: total))

        switch directive {
        case .continue(let actorDirective):
            await speakActor(directive: actorDirective)
        case .injectHelp(let step, let kind):
            continuation.yield(.info(Self.helpCopy(step: step, kind: kind)))
            await speakActor(directive: Self.helpDirective(kind))
        case .endScene:
            await finishScene(learnerQuit: false)
        }
    }

    private func speakActor(directive: String?) async {
        let transcript = await engine.transcriptMessages()
        let line = await actor.nextLine(ActorContext(
            scenario: scenario, transcript: transcript, directive: directive, persona: persona
        ))
        await engine.seedActorTurn(line)
        continuation.yield(.prompt(text: line, audio: nil))
    }

    private func finishScene(learnerQuit: Bool) async {
        guard !ended else { return }
        ended = true
        let outcome = await engine.finalize(learnerQuit: learnerQuit)
        finalOutcome = outcome
        let (done, total) = await engine.progress()
        continuation.yield(.goalProgress(completed: done, total: total))
        for point in outcome.focusPoints { continuation.yield(.info(point)) }
        continuation.yield(.finished)
        continuation.finish()
    }

    private var actor: any ActorService {
        context.actor ?? EchoActor()
    }

    // MARK: - helpers

    private static func result(from outcome: RoleplayOutcome?, duration: TimeInterval) -> ModeResult {
        guard let outcome else { return ModeResult(status: .abandoned) }
        let score: JSONValue = .object([
            "value": .number(outcome.scoreValue),
            "praise_allowed": .bool(outcome.praiseAllowed),
        ])
        return ModeResult(reviews: outcome.reviews, errors: outcome.errors,
                          status: outcome.status, score: score, duration: duration)
    }

    private static func helpCopy(step: Int, kind: HelpKind) -> String {
        switch kind {
        case .rephraseSimpler: return "Let's slow down — they'll say it a simpler way."
        case .showTextFurigana: return "Here's the text to read along."
        case .l1Bridge: return "Say it in English and we'll rebuild it in Japanese."
        case .logWeaknessAdvance: return "We'll come back to this one later — moving on."
        }
    }

    private static func helpDirective(_ kind: HelpKind) -> String {
        switch kind {
        case .rephraseSimpler: return "Rephrase your last line using only N5 vocabulary, slower."
        case .showTextFurigana: return "Repeat your last line clearly and simply."
        case .l1Bridge: return "Offer the English, then invite them to try it in Japanese."
        case .logWeaknessAdvance: return "Move the scene forward gently."
        }
    }

    private static let fallbackScenario = Scenario(
        id: "scenario:free_chat", title: "自由会話", register: "polite", band: "N5.1",
        setting: "A friendly chat.", personaHint: "warm, patient partner",
        goals: [ScenarioGoal(id: "g1", required: true, descEN: "Exchange greetings")]
    )
}

/// Fallback Actor when none is injected (previews/tests): echoes a gentle prompt.
struct EchoActor: ActorService {
    func openingLine(scenario: Scenario, persona: PersonaID) async -> String {
        "こんにちは。\(scenario.title)を はじめましょう。"
    }
    func nextLine(_ context: ActorContext) async -> String { "はい、どうぞ。" }
}

/// Fallback Director when none is injected: makes no goal progress, never ends.
struct StubDirector: DirectorService {
    func evaluateTurn(_ input: DirectorInput) async throws -> DirectorVerdict { .safeContinue }
}
