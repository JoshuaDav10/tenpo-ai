import Foundation
import CoreModels

#if os(iOS)
import AVFoundation

/// Records a learner's spoken answer to a 16 kHz mono PCM WAV clip for the grading
/// cascade (§4.3.1 Pipeline B). Kept deliberately simple — record to a temp file,
/// read it back as an `AudioClip` — so the on-device recognizer and the server
/// pass both receive a format they accept.
public final class AudioRecorder: NSObject, @unchecked Sendable {
    private let lock = NSLock()
    private var recorder: AVAudioRecorder?
    private var url: URL?

    public override init() { super.init() }

    /// Ask for microphone permission (iOS 17 `AVAudioApplication`). Returns whether granted.
    public func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    /// Begin recording. Throws if the audio session or recorder can't start.
    public func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
        try session.setActive(true)

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let recorder = try AVAudioRecorder(url: fileURL, settings: settings)
        recorder.record()

        lock.lock(); defer { lock.unlock() }
        self.recorder = recorder
        self.url = fileURL
    }

    /// Stop recording and return the captured clip (nil if nothing was recorded).
    public func stop() -> AudioClip? {
        lock.lock()
        let recorder = self.recorder
        let url = self.url
        self.recorder = nil
        self.url = nil
        lock.unlock()

        recorder?.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        try? FileManager.default.removeItem(at: url)
        return AudioClip(data: data, encoding: .wav, sampleRate: 16_000, duration: recorder?.currentTime)
    }

    public var isRecording: Bool {
        lock.lock(); defer { lock.unlock() }
        return recorder?.isRecording ?? false
    }
}
#endif
