import Foundation
import CoreModels

/// PCM conversion helpers, kept pure so they're testable on macOS (no audio stack).
public enum PCM {
    /// Float32 samples (−1…1) → little-endian Int16 bytes (the realtime wire format).
    public static func int16Data(fromFloat32 samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            var value = Int16(clamped * Float(Int16.max)).littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// Little-endian Int16 bytes → Float32 samples for playback.
    public static func float32Samples(fromInt16 data: Data) -> [Float] {
        var samples = [Float](repeating: 0, count: data.count / 2)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let int16s = raw.bindMemory(to: Int16.self)
            for i in 0..<samples.count {
                samples[i] = Float(Int16(littleEndian: int16s[i])) / Float(Int16.max)
            }
        }
        return samples
    }
}

#if os(iOS)
import AVFAudio

/// The hardware half of the voice loop: continuously streams mic audio as 24kHz
/// mono PCM16 chunks, and plays the assistant's PCM16 deltas gaplessly. All
/// *decisions* (when to play, when to flush) belong to `VoiceLoop`; this class
/// only obeys.
public final class RealtimeAudioEngine: @unchecked Sendable {
    public static let wireSampleRate: Double = 24000

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let playbackFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: wireSampleRate, channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private let onMicChunk: @Sendable (CoreModels.AudioBuffer) -> Void

    public init(onMicChunk: @escaping @Sendable (CoreModels.AudioBuffer) -> Void) {
        self.onMicChunk = onMicChunk
    }

    public func start() throws {
        let audioSession = AVAudioSession.sharedInstance()
        // .voiceChat enables echo cancellation — without it the mic hears the AI's
        // own voice and the server VAD "barge-ins" on itself.
        try audioSession.setCategory(.playAndRecord, mode: .voiceChat,
                                     options: [.defaultToSpeaker, .allowBluetoothHFP])
        try audioSession.setActive(true)

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        let wireFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Self.wireSampleRate, channels: 1, interleaved: false)!
        converter = AVAudioConverter(from: inputFormat, to: wireFormat)

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)

        // ~100ms chunks: small enough for responsive VAD, big enough to keep the
        // WSS frame rate sane.
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(inputFormat.sampleRate / 10),
                         format: inputFormat) { [weak self] buffer, _ in
            self?.forward(buffer)
        }

        try engine.start()
        player.play()
    }

    public func stop() {
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Queue one assistant PCM16 delta for gapless playback.
    public func play(_ buffer: CoreModels.AudioBuffer) {
        let samples = PCM.float32Samples(fromInt16: buffer.data)
        guard !samples.isEmpty,
              let pcm = AVAudioPCMBuffer(pcmFormat: playbackFormat,
                                         frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        pcm.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            pcm.floatChannelData!.pointee.update(from: source.baseAddress!, count: samples.count)
        }
        player.scheduleBuffer(pcm)
        if !player.isPlaying { player.play() }
    }

    /// Drop everything queued and go silent immediately (barge-in).
    public func stopPlayback() {
        player.stop()
        player.play() // node stays live for the next reply
    }

    // MARK: - mic → wire

    private func forward(_ buffer: AVAudioPCMBuffer) {
        guard let converter,
              let out = AVAudioPCMBuffer(
                pcmFormat: converter.outputFormat,
                frameCapacity: AVAudioFrameCount(Self.wireSampleRate / 10) + 64) else { return }
        var fed = false
        converter.convert(to: out, error: nil) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard out.frameLength > 0, let channel = out.floatChannelData?.pointee else { return }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
        onMicChunk(CoreModels.AudioBuffer(data: PCM.int16Data(fromFloat32: samples),
                               encoding: .pcm16, sampleRate: Int(Self.wireSampleRate)))
    }
}
#endif
