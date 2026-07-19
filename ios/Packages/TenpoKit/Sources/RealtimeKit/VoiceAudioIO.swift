import Foundation
import CoreModels

/// The seam between turn-based mode sessions and stream-based audio hardware.
/// The view owns the hardware (mic tap, speaker, orb) and the mode session owns
/// every decision; this pipe carries chunks one way and playback/state commands
/// the other, so lessons run through SessionRunner (persistence, SRS) and tests
/// drive both ends with no AVFoundation.
public final class VoiceAudioIO: @unchecked Sendable {
    public enum Output: Sendable {
        case play(AudioBuffer)
        case stop
        case state(VoiceLoopState)
    }

    public let output: AsyncStream<Output>
    public let micChunks: AsyncStream<AudioBuffer>
    private let outputContinuation: AsyncStream<Output>.Continuation
    private let micContinuation: AsyncStream<AudioBuffer>.Continuation

    public init() {
        var out: AsyncStream<Output>.Continuation!
        self.output = AsyncStream { out = $0 }
        self.outputContinuation = out
        var mic: AsyncStream<AudioBuffer>.Continuation!
        self.micChunks = AsyncStream { mic = $0 }
        self.micContinuation = mic
    }

    /// View side: push one mic chunk toward the mode.
    public func submitMic(_ chunk: AudioBuffer) {
        micContinuation.yield(chunk)
    }

    /// Mode side: command playback/state on the hardware.
    public func emit(_ output: Output) {
        outputContinuation.yield(output)
    }

    public func finish() {
        outputContinuation.finish()
        micContinuation.finish()
    }
}
