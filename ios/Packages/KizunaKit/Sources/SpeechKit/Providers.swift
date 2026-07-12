import Foundation
import CoreModels

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

/// Facade the modes use (§4.6 ModeContext.speech). The honest grading algorithm
/// (§4.3.4) lands here in Phase 2 — dual-threshold, two ASR opinions before a fail.
public protocol SpeechService: Sendable {
    var stt: any STTProvider { get }
    var tts: any TTSProvider { get }
    var pronunciation: any PronunciationAssessor { get }
}

public struct LiveSpeechService: SpeechService {
    public let stt: any STTProvider
    public let tts: any TTSProvider
    public let pronunciation: any PronunciationAssessor

    public init(stt: any STTProvider, tts: any TTSProvider, pronunciation: any PronunciationAssessor) {
        self.stt = stt
        self.tts = tts
        self.pronunciation = pronunciation
    }
}
