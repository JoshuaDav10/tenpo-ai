import Testing
import Foundation
@testable import RealtimeKit
import CoreModels

private func pcm(_ byte: UInt8) -> AudioBuffer {
    AudioBuffer(data: Data([byte, 0]), encoding: .pcm16, sampleRate: 24000)
}

struct VoiceLoopTests {

    @Test func fullTurnCycle_greeting_listen_think_speak_listen() {
        var loop = VoiceLoop()
        // The Actor opens the scene, so the loop starts waiting for the greeting.
        #expect(loop.state == .thinking)

        // Greeting audio arrives → speaking; done → learner's turn.
        #expect(loop.handle(.assistantAudio(pcm(9))) == [.state(.speaking), .play(pcm(9))])
        _ = loop.handle(.assistantTranscript("こんにちは"))
        #expect(loop.handle(.turnEnded(role: .actor)) == [.assistantSaid("こんにちは"), .state(.listening)])

        // Learner talks, server VAD endpoints → thinking.
        _ = loop.handle(.userSpeechStarted)
        #expect(loop.handle(.userSpeechStopped) == [.state(.thinking)])

        // First audio delta → speaking + play; later deltas just play.
        #expect(loop.handle(.assistantAudio(pcm(1))) == [.state(.speaking), .play(pcm(1))])
        #expect(loop.handle(.assistantAudio(pcm(2))) == [.play(pcm(2))])
        #expect(loop.handle(.turnEnded(role: .actor)) == [.state(.listening)])
    }

    @Test func voiceNeverInterrupts_onlyTapDoes() {
        var loop = VoiceLoop()
        _ = loop.handle(.assistantAudio(pcm(1)))
        #expect(loop.state == .speaking)
        // Speech events during the AI's turn change nothing (turn-based design).
        #expect(loop.handle(.userSpeechStarted).isEmpty)
        #expect(loop.state == .speaking)
        // The tap is the interrupt.
        #expect(loop.tapInterrupt() == [.stopPlayback, .state(.listening)])
        #expect(loop.state == .listening)
        // Tapping during your own turn does nothing.
        #expect(loop.tapInterrupt().isEmpty)
    }

    @Test func micStreamsOnlyOnLearnersTurn() {
        var loop = VoiceLoop()
        #expect(loop.shouldForwardMicAudio == false) // waiting for greeting
        _ = loop.handle(.assistantAudio(pcm(1)))
        #expect(loop.shouldForwardMicAudio == false) // AI speaking
        _ = loop.handle(.turnEnded(role: .actor))
        #expect(loop.shouldForwardMicAudio == true)  // learner's turn
        _ = loop.handle(.userSpeechStopped)
        #expect(loop.shouldForwardMicAudio == false) // endpointed, reply pending
    }

    @Test func tapInterrupt_whileThinking_alsoTakesTheFloor() {
        var loop = VoiceLoop()
        #expect(loop.state == .thinking)
        #expect(loop.tapInterrupt() == [.stopPlayback, .state(.listening)])
        // Straggler audio deltas from the cancelled reply re-enter speaking legally
        // (a reply can still be in flight server-side until the cancel lands).
        #expect(loop.handle(.assistantAudio(pcm(3))) == [.state(.speaking), .play(pcm(3))])
    }

    @Test func benignCancelRaceError_isIgnoredNotFatal() {
        // Field bug: our barge-in cancel raced OpenAI's auto-cancel; the resulting
        // "Cancellation failed: no active response found" killed the session.
        let frame: [String: Any] = [
            "type": "error",
            "error": ["message": "Cancellation failed: no active response found"],
        ]
        #expect(ProxyRealtimeSession.mapEvent(frame) == nil)
        // Real errors still map.
        let fatal: [String: Any] = ["type": "error", "error": ["message": "session expired"]]
        if case .error = ProxyRealtimeSession.mapEvent(fatal)! {} else {
            Issue.record("real errors must still surface")
        }
    }

    @Test func softCapRefusal_fallsBackToCascade() {
        var loop = VoiceLoop()
        let actions = loop.handle(.proxyRefused(code: "cost_cheap_mode", cheapModeFallback: true))
        #expect(actions == [.stopPlayback, .fallbackToCascade, .state(.ended)])
        #expect(loop.state == .ended)
        // Ended loop ignores everything after.
        #expect(loop.handle(.assistantAudio(pcm(9))).isEmpty)
        #expect(loop.shouldForwardMicAudio == false)
    }

    @Test func hardRefusalAndErrors_failWithoutFallback() {
        var loop = VoiceLoop()
        #expect(loop.handle(.proxyRefused(code: "cost_hard_cap", cheapModeFallback: false))
                == [.stopPlayback, .failed("cost_hard_cap"), .state(.ended)])

        var loop2 = VoiceLoop()
        #expect(loop2.handle(.error("socket died"))
                == [.stopPlayback, .failed("socket died"), .state(.ended)])
    }

    @Test func latencyMeter_measuresEndpointToFirstAudio() {
        var meter = VoiceLatencyMeter()
        let t0 = Date(timeIntervalSince1970: 1000)
        meter.note(.userSpeechStopped, now: t0)
        meter.note(.assistantAudio(pcm(1)), now: t0.addingTimeInterval(0.8))
        // Subsequent deltas of the same reply don't re-measure.
        meter.note(.assistantAudio(pcm(2)), now: t0.addingTimeInterval(2.0))
        #expect(meter.lastVoiceToVoiceMS == 800)
        #expect(meter.samples == [800])
        #expect(meter.p50MS == 800)
    }

    @Test func pcmRoundTrip_preservesSamples() {
        let samples: [Float] = [0, 0.5, -0.5, 1.0, -1.0, 0.25]
        let data = PCM.int16Data(fromFloat32: samples)
        #expect(data.count == samples.count * 2)
        let back = PCM.float32Samples(fromInt16: data)
        #expect(back.count == samples.count)
        for (a, b) in zip(samples, back) {
            #expect(abs(a - b) < 0.001)
        }
    }

    @Test func conductedPolicy_floorReturnsToConductorNotMic() {
        var loop = VoiceLoop(policy: .conducted)
        _ = loop.handle(.assistantAudio(pcm(1)))
        // AI finishes → back to thinking (conductor's floor), NOT listening.
        #expect(loop.handle(.turnEnded(role: .actor)) == [.state(.thinking)])
        #expect(loop.shouldForwardMicAudio == false)
        // Conductor explicitly opens the mic when a learner turn is expected.
        #expect(loop.openMic() == [.state(.listening)])
        #expect(loop.shouldForwardMicAudio == true)
        // Redundant openMic is a no-op.
        #expect(loop.openMic().isEmpty)
    }

    @Test func conductedPolicy_tapInterruptStillWorks() {
        var loop = VoiceLoop(policy: .conducted)
        _ = loop.handle(.assistantAudio(pcm(1)))
        #expect(loop.tapInterrupt() == [.stopPlayback, .state(.listening)])
    }

    @Test func lessonStepFrameBuilderProducesWireShape() throws {
        let frame = ProxyRealtimeSession.frame(
            for: LessonStepDirective(kind: "lesson.model_repeat",
                                     variables: ["target": .string("はじめまして")]))
        let data = try JSONEncoder().encode(frame)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["type"] as? String == "lesson.step")
        let step = obj?["step"] as? [String: Any]
        #expect(step?["kind"] as? String == "lesson.model_repeat")
        let vars = step?["variables"] as? [String: Any]
        #expect(vars?["target"] as? String == "はじめまして")
        // Stays under the bridge's 2KB parse gate.
        #expect(data.count < 2048)
    }

    @Test func speechStartStopEventsMapFromWireFrames() {
        #expect(ProxyRealtimeSession.mapEvent(["type": "input_audio_buffer.speech_started"]) != nil)
        #expect(ProxyRealtimeSession.mapEvent(["type": "input_audio_buffer.speech_stopped"]) != nil)
        if case .userSpeechStarted = ProxyRealtimeSession.mapEvent(["type": "input_audio_buffer.speech_started"])! {
        } else {
            Issue.record("speech_started should map to .userSpeechStarted")
        }
    }
}
