import Foundation
import CoreModels

/// Local user preferences (persona/voice — R16). Persona maps to both a distinct
/// Actor system-prompt personality (server `actor_turn` template) and a TTS voice
/// (`LanguagePack.ttsVoiceMap`).
enum Preferences {
    private static let personaKey = "actor_persona"

    static var persona: PersonaID {
        get { PersonaID(rawValue: UserDefaults.standard.string(forKey: personaKey) ?? PersonaID.warmTutor.rawValue) }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: personaKey) }
    }

    struct PersonaChoice: Identifiable {
        var id: String { persona.rawValue }
        let persona: PersonaID
        let name: String
        let blurb: String
    }

    static let personaChoices: [PersonaChoice] = [
        .init(persona: .warmTutor,    name: "Warm tutor",   blurb: "Patient and encouraging"),
        .init(persona: .casualFriend, name: "Casual friend", blurb: "Relaxed, everyday speech"),
        .init(persona: .formalSenpai, name: "Formal senpai", blurb: "Polite and precise"),
    ]
}
