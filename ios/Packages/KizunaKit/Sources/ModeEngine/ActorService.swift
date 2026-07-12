import Foundation
import CoreModels

// The Actor (§4.4): the in-character conversation partner. In realtime mode it is
// OpenAI Realtime (speech-to-speech); in cheap/cascade mode (§4.3.6) it is a text
// completion via ChatProvider. The Actor NEVER ends the scene, scores, or praises
// overall — those belong to the Director + code guardrails (D6). It only speaks
// in character and applies the Director's mid-scene directives.

public struct ActorContext: Sendable {
    public var scenario: Scenario
    public var transcript: [ChatMessage]
    /// The Director's steering for this turn (e.g. "rephrase using only N5 vocab").
    public var directive: String?
    public var persona: PersonaID

    public init(scenario: Scenario, transcript: [ChatMessage], directive: String? = nil, persona: PersonaID = .warmTutor) {
        self.scenario = scenario
        self.transcript = transcript
        self.directive = directive
        self.persona = persona
    }
}

public protocol ActorService: Sendable {
    /// The scene's opening line, in character.
    func openingLine(scenario: Scenario, persona: PersonaID) async -> String
    /// The next in-character line given the running transcript + Director directive.
    func nextLine(_ context: ActorContext) async -> String
}

/// Cheap-mode Actor: a text completion via `ChatProvider` against the server-side
/// `actor_turn` template. The persona, register, and directive travel as template
/// variables; the prompt text stays on the server (§7).
public struct LiveActorService: ActorService {
    let chat: any ChatProvider
    let templateID: String

    public init(chat: any ChatProvider, templateID: String = "actor_turn") {
        self.chat = chat
        self.templateID = templateID
    }

    public func openingLine(scenario: Scenario, persona: PersonaID) async -> String {
        await line(scenario: scenario, transcript: [], directive: "Open the scene in character.", persona: persona)
    }

    public func nextLine(_ context: ActorContext) async -> String {
        await line(scenario: context.scenario, transcript: context.transcript,
                   directive: context.directive, persona: context.persona)
    }

    private func line(scenario: Scenario, transcript: [ChatMessage], directive: String?, persona: PersonaID) async -> String {
        let req = ChatRequest(
            templateID: templateID,
            variables: [
                "scenario_id": .string(scenario.id),
                "register": .string(scenario.register),
                "band": .string(scenario.band),
                "setting": .string(scenario.setting),
                "persona_hint": .string(scenario.personaHint),
                "persona": .string(persona.rawValue),
                "directive": directive.map(JSONValue.string) ?? .null,
            ],
            messages: transcript
        )
        return (try? await chat.complete(req).text) ?? "…"
    }
}
