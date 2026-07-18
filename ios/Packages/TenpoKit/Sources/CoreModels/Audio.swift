import Foundation

public enum AudioEncoding: String, Codable, Sendable {
    case pcm16, wav, m4a, mp3, opus
}

/// A complete recorded or synthesized audio clip.
public struct AudioClip: Codable, Sendable, Hashable {
    public var data: Data
    public var encoding: AudioEncoding
    public var sampleRate: Int
    public var duration: TimeInterval?

    public init(data: Data, encoding: AudioEncoding, sampleRate: Int, duration: TimeInterval? = nil) {
        self.data = data
        self.encoding = encoding
        self.sampleRate = sampleRate
        self.duration = duration
    }
}

/// A streaming chunk of audio for realtime sessions.
public struct AudioBuffer: Sendable {
    public var data: Data
    public var encoding: AudioEncoding
    public var sampleRate: Int

    public init(data: Data, encoding: AudioEncoding, sampleRate: Int) {
        self.data = data
        self.encoding = encoding
        self.sampleRate = sampleRate
    }
}

/// STT result. Grading code MUST consult `confidence` (R5, R6).
public struct Transcription: Codable, Sendable, Hashable {
    public var text: String
    public var confidence: Double
    public var alternatives: [String]
    public var provider: ProviderID

    public init(text: String, confidence: Double, alternatives: [String] = [], provider: ProviderID) {
        self.text = text
        self.confidence = confidence
        self.alternatives = alternatives
        self.provider = provider
    }
}

/// Phoneme-level pronunciation assessment result (Azure — §4.3.2).
public struct PronunciationReport: Codable, Sendable, Hashable {
    public struct PhonemeScore: Codable, Sendable, Hashable {
        public var phoneme: String
        public var score: Double

        public init(phoneme: String, score: Double) {
            self.phoneme = phoneme
            self.score = score
        }
    }

    /// 0–100 overall accuracy.
    public var overall: Double
    public var fluency: Double?
    public var prosody: Double?
    public var phonemes: [PhonemeScore]
    public var provider: ProviderID

    public init(
        overall: Double, fluency: Double? = nil, prosody: Double? = nil,
        phonemes: [PhonemeScore] = [], provider: ProviderID
    ) {
        self.overall = overall
        self.fluency = fluency
        self.prosody = prosody
        self.phonemes = phonemes
        self.provider = provider
    }

    /// Lowest-scoring phonemes, for SOFT_FAIL feedback naming the problem (R5).
    public func worstPhonemes(_ count: Int = 3) -> [PhonemeScore] {
        Array(phonemes.sorted { $0.score < $1.score }.prefix(count))
    }
}
