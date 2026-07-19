import Foundation
import CoreModels

public struct RealtimeConfig: Sendable {
    /// Server-side Actor prompt template id — the prompt itself never lives on device (§7).
    public var actorTemplateID: String
    public var variables: [String: JSONValue]
    public var voice: VoiceID
    public var locale: LanguageID
    /// Session shape selector for the bridge ("lesson" hands turn authority to the
    /// client conductor). nil = legacy roleplay behavior.
    public var mode: String?

    public init(actorTemplateID: String, variables: [String: JSONValue] = [:], voice: VoiceID, locale: LanguageID, mode: String? = nil) {
        self.actorTemplateID = actorTemplateID
        self.variables = variables
        self.voice = voice
        self.locale = locale
        self.mode = mode
    }
}

/// One conductor step: names a server-side lesson template (§7 — the prompt text
/// stays on the server) plus runtime DATA variables (targets, transcripts, flags).
public struct LessonStepDirective: Sendable {
    public var kind: String
    public var variables: [String: JSONValue]

    public init(kind: String, variables: [String: JSONValue] = [:]) {
        self.kind = kind
        self.variables = variables
    }
}

public enum RealtimeEvent: Sendable {
    case partialTranscript(role: TranscriptRole, text: String)
    case assistantAudio(AudioBuffer)
    case assistantTranscript(String)
    case turnEnded(role: TranscriptRole)
    /// Server VAD detected the learner's voice (OpenAI `input_audio_buffer.speech_started`).
    /// Arriving while assistant audio is playing, this is the barge-in trigger.
    case userSpeechStarted
    /// Server VAD detected end-of-utterance — the "auto endpoint" of the voice loop.
    case userSpeechStopped
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
    /// Conductor step: the bridge renders the named server-side template and fires
    /// a response.create with it. The primary way lessons make the AI speak.
    func send(step: LessonStepDirective) async throws
    /// Manual endpoint (input_audio_buffer.commit). Safety hatch — semantic VAD
    /// auto-commits; used only if live verification disproves that.
    func commitInput() async throws
    /// Bare response.create (recovery path; uses session-level instructions).
    func createResponse() async throws
    func interrupt() async throws
    func close() async
}

/// Facade for ModeContext (§4.6). nil when descriptor.needsRealtime == false.
public protocol RealtimeVoiceService: Sendable {
    func openSession(_ config: RealtimeConfig) async throws -> any RealtimeSession
}
