import Foundation
import CoreModels

/// Returns a scripted transcription queue, then repeats the last one.
public final class MockSTTProvider: STTProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [Transcription]

    public init(results: [Transcription] = []) {
        self.queue = results
    }

    public func enqueue(_ t: Transcription) {
        synced { queue.append(t) }
    }

    public func transcribe(_ audio: AudioClip, locale: LanguageID, hints: [String]) async throws -> Transcription {
        synced {
            guard !queue.isEmpty else {
                return Transcription(text: hints.first ?? "", confidence: 1.0, provider: "mock:stt")
            }
            return queue.count == 1 ? queue[0] : queue.removeFirst()
        }
    }

    private func synced<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// Returns a silent clip of a deterministic size; records synth requests.
public final class MockTTSProvider: TTSProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [(text: String, voice: VoiceID)] = []

    public var requests: [(text: String, voice: VoiceID)] {
        synced { _requests }
    }

    public init() {}

    public func synthesize(_ text: String, voice: VoiceID, locale: LanguageID) async throws -> AudioClip {
        synced { _requests.append((text, voice)) }
        return AudioClip(data: Data(count: 16), encoding: .pcm16, sampleRate: 24000, duration: 0.5)
    }

    private func synced<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

public final class MockPronunciationAssessor: PronunciationAssessor, @unchecked Sendable {
    private let lock = NSLock()
    private var canned: PronunciationReport

    public init(canned: PronunciationReport = PronunciationReport(overall: 92, provider: "mock:pron")) {
        self.canned = canned
    }

    public func setCanned(_ report: PronunciationReport) {
        synced { canned = report }
    }

    public func assess(_ audio: AudioClip, referenceText: String, locale: LanguageID) async throws -> PronunciationReport {
        synced { canned }
    }

    private func synced<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
