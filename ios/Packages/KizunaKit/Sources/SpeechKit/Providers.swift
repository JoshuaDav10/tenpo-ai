import Foundation
import CoreModels
import LanguagePackCore

// §4.3.2 — implement exactly these. Client names capabilities, never providers.

public protocol STTProvider: Sendable {
    /// `hints` = expected answer(s), used to bias recognition (R6).
    func transcribe(_ audio: AudioClip, locale: LanguageID, hints: [String]) async throws -> Transcription
}

public protocol TTSProvider: Sendable {
    func synthesize(_ text: String, voice: VoiceID, locale: LanguageID) async throws -> AudioClip
}

public protocol PronunciationAssessor: Sendable {
    /// Phoneme + prosody scores against a reference text.
    func assess(_ audio: AudioClip, referenceText: String, locale: LanguageID) async throws -> PronunciationReport
}

/// Facade the modes use (§4.6 ModeContext.speech): `grade()`, `tts()`, and
/// `assessPronunciation()`. Grading is the honest dual-threshold algorithm
/// (§4.3.4) — it consults the on-device pass first, then the server pass, and
/// never records a fail on a single ASR opinion (R6).
public protocol SpeechService: Sendable {
    var onDeviceSTT: any STTProvider { get }
    var serverSTT: any STTProvider { get }
    var tts: any TTSProvider { get }
    var pronunciation: any PronunciationAssessor { get }

    func grade(audio: AudioClip, item: GradableItem, attempt: Int, locale: LanguageID) async throws -> GradeOutcome
    func synthesize(_ text: String, voice: VoiceID, locale: LanguageID) async throws -> AudioClip
    func assessPronunciation(_ audio: AudioClip, referenceText: String, locale: LanguageID) async throws -> PronunciationReport
}

public struct LiveSpeechService: SpeechService {
    public let onDeviceSTT: any STTProvider
    public let serverSTT: any STTProvider
    public let tts: any TTSProvider
    public let pronunciation: any PronunciationAssessor
    private let grader: HonestGrader

    public init(
        onDeviceSTT: any STTProvider, serverSTT: any STTProvider,
        tts: any TTSProvider, pronunciation: any PronunciationAssessor, pack: any LanguagePack
    ) {
        self.onDeviceSTT = onDeviceSTT
        self.serverSTT = serverSTT
        self.tts = tts
        self.pronunciation = pronunciation
        self.grader = HonestGrader(
            onDeviceSTT: onDeviceSTT, serverSTT: serverSTT,
            pronunciation: pronunciation, pack: pack
        )
    }

    public func grade(audio: AudioClip, item: GradableItem, attempt: Int, locale: LanguageID) async throws -> GradeOutcome {
        try await grader.grade(audio: audio, item: item, attempt: attempt, locale: locale)
    }

    public func synthesize(_ text: String, voice: VoiceID, locale: LanguageID) async throws -> AudioClip {
        try await tts.synthesize(text, voice: voice, locale: locale)
    }

    public func assessPronunciation(_ audio: AudioClip, referenceText: String, locale: LanguageID) async throws -> PronunciationReport {
        try await pronunciation.assess(audio, referenceText: referenceText, locale: locale)
    }
}
