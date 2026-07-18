import Foundation
import CoreModels

#if canImport(Speech)
import Speech

/// On-device first-pass STT via `SFSpeechRecognizer` (§4.3.1 Pipeline B, ja-JP).
/// Free and instant for easy drills; the grading cascade escalates to the server
/// pass when confidence is low (§4.3.4). Requires on-device recognition so audio
/// for easy drills never leaves the device (D10 / privacy).
public final class AppleSpeechRecognizer: STTProvider, @unchecked Sendable {
    private let requiresOnDevice: Bool

    public init(requiresOnDevice: Bool = true) {
        self.requiresOnDevice = requiresOnDevice
    }

    public func transcribe(_ audio: AudioClip, locale: LanguageID, hints: [String]) async throws -> Transcription {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier(locale))) else {
            throw SpeechError.recognizerUnavailable(locale: locale.rawValue)
        }
        guard recognizer.isAvailable else {
            throw SpeechError.recognizerUnavailable(locale: locale.rawValue)
        }

        // SFSpeechURLRecognitionRequest needs a file; write the clip to a temp file
        // with an extension matching its container.
        let url = try writeTemp(audio)
        defer { try? FileManager.default.removeItem(at: url) }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = requiresOnDevice
        request.addsPunctuation = false
        // Bias recognition toward the expected answers (R6).
        if !hints.isEmpty {
            request.contextualStrings = hints
        }

        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            recognizer.recognitionTask(with: request) { result, error in
                if let error, !resumed {
                    resumed = true
                    continuation.resume(throwing: SpeechError.recognitionFailed(error.localizedDescription))
                    return
                }
                guard let result, result.isFinal, !resumed else { return }
                resumed = true
                let best = result.bestTranscription
                // SFSpeech has no single 0–1 confidence; average the per-segment
                // confidences as a usable proxy for the grading thresholds.
                let segs = best.segments
                let confidence = segs.isEmpty ? 0 : Double(segs.map(\.confidence).reduce(0, +)) / Double(segs.count)
                let alternatives = result.transcriptions.dropFirst().prefix(3).map(\.formattedString)
                continuation.resume(returning: Transcription(
                    text: best.formattedString,
                    confidence: confidence,
                    alternatives: Array(alternatives),
                    provider: "apple:sfspeech"
                ))
            }
        }
    }

    private func localeIdentifier(_ locale: LanguageID) -> String {
        locale == .japanese ? "ja-JP" : locale.rawValue
    }

    private func writeTemp(_ audio: AudioClip) throws -> URL {
        let ext: String
        switch audio.encoding {
        case .wav, .pcm16: ext = "wav"
        case .m4a: ext = "m4a"
        case .mp3: ext = "mp3"
        case .opus: ext = "opus"
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)
        try audio.data.write(to: url)
        return url
    }
}
#endif

public enum SpeechError: Error, Sendable {
    case recognizerUnavailable(locale: String)
    case recognitionFailed(String)
    case proxyError(status: Int, body: String)
    case encodingUnsupported
}
