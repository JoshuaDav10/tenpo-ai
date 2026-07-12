import Foundation

/// The third-party AI processors the app sends voice/text to (§8.1 Guideline
/// 5.1.2(i)). Shown on the blocking consent screen; the consent record is keyed to
/// this list so adding a provider re-prompts.
enum AIProviders {
    struct Processor: Identifiable {
        var id: String { name }
        let name: String
        let purpose: String
    }

    static let all: [Processor] = [
        .init(name: "Anthropic (Claude)", purpose: "conversation evaluation & content"),
        .init(name: "OpenAI", purpose: "voice conversation & speech synthesis"),
        .init(name: "Deepgram", purpose: "speech recognition"),
        .init(name: "Microsoft Azure", purpose: "pronunciation assessment"),
        .init(name: "ElevenLabs", purpose: "voice synthesis"),
    ]

    /// A version token derived from the provider set; consent re-prompts if it changes.
    static var version: String {
        all.map(\.name).joined(separator: "|")
    }
}

/// Persists the user's third-party-AI consent (§8.1). Blocking, explicit opt-in,
/// re-shown if the provider set changes.
@MainActor
final class ComplianceStore: ObservableObject {
    private let defaults: UserDefaults
    private let consentKey = "ai_consent_provider_version"
    private let consentDateKey = "ai_consent_date"

    @Published var hasConsented: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.hasConsented = defaults.string(forKey: "ai_consent_provider_version") == AIProviders.version
    }

    func grantConsent() {
        defaults.set(AIProviders.version, forKey: consentKey)
        defaults.set(Date(), forKey: consentDateKey)
        hasConsented = true
    }

    var consentDate: Date? {
        defaults.object(forKey: consentDateKey) as? Date
    }

    /// For account deletion / testing — clears the stored consent.
    func revokeConsent() {
        defaults.removeObject(forKey: consentKey)
        defaults.removeObject(forKey: consentDateKey)
        hasConsented = false
    }
}
