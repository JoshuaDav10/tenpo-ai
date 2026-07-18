import Foundation
import CoreModels

public struct RealtimeConfig: Sendable {
    /// Server-side Actor prompt template id — the prompt itself never lives on device (§7).
    public var actorTemplateID: String
    public var variables: [String: JSONValue]
    public var voice: VoiceID
    public var locale: LanguageID

    public init(actorTemplateID: String, variables: [String: JSONValue] = [:], voice: VoiceID, locale: LanguageID) {
        self.actorTemplateID = actorTemplateID
        self.variables = variables
        self.voice = voice
        self.locale = locale
    }
}

public enum RealtimeEvent: Sendable {
    case partialTranscript(role: TranscriptRole, text: String)
    case assistantAudio(AudioBuffer)
    case assistantTranscript(String)
    case turnEnded(role: TranscriptRole)
    case error(String)
    /// The PROXY refused/closed the session for a policy reason — its frames carry a
    /// bare string `error` code (not OpenAI's `{message}` object). `code` is e.g.
    /// `cost_cheap_mode`, `cost_hard_cap`, `unauthorized`, `provider_not_configured`.
    /// `cheapModeFallback` is true when the caller should retry on the cheap cascade
    /// pipeline (§4.3.6 soft cap) rather than surface a hard error.
    case proxyRefused(code: String, cheapModeFallback: Bool)
}

// §4.3.2 — implement exactly these.

public protocol RealtimeVoiceProvider: Sendable {
    func openSession(_ config: RealtimeConfig) async throws -> any RealtimeSession
}

public protocol RealtimeSession: AnyObject, Sendable {
    var events: AsyncStream<RealtimeEvent> { get }
    func send(audio: AudioBuffer) async throws
    /// Director → Actor steering mid-scene (§4.4 actor_directive).
    func send(systemUpdate: String) async throws
    func interrupt() async throws
    func close() async
}

/// Facade for ModeContext (§4.6). nil when descriptor.needsRealtime == false.
public protocol RealtimeVoiceService: Sendable {
    func openSession(_ config: RealtimeConfig) async throws -> any RealtimeSession
}
