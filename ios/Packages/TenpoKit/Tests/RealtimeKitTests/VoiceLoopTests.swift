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

    @Test func userTalkingBeforeGreeting_takesTheFloor() {
        var loop = VoiceLoop()
        // Eager learner speaks during the opening wait → treat like barge-in.
        #expect(loop.handle(.userSpeechStarted) == [.stopPlayback, .state(.listening)])
        #expect(loop.handle(.userSpeechStopped) == [.state(.thinking)])
    }

    @Test func bargeIn_whileSpeaking_stopsPlaybackImmediately() {
        var loop = VoiceLoop()
        _ = loop.handle(.assistantAudio(pcm(1)))
        #expect(loop.state == .speaking)

        // Learner interrupts mid-reply: playback must flush, floor flips instantly.
        #expect(loop.handle(.userSpeechStarted) == [.stopPlayback, .state(.listening)])

        // Straggler audio deltas from the cancelled reply restart playback (still a
        // reply in flight server-side until response.cancel lands) — but the state
        // machine had returned the floor, so it re-enters speaking legally.
        #expect(loop.handle(.assistantAudio(pcm(3))) == [.state(.speaking), .play(pcm(3))])
    }

    @Test func bargeIn_whileThinking_alsoCancels() {
        var loop = VoiceLoop()
        #expect(loop.state == .thinking)
        // Learner resumes before the reply starts (changed their mind, kept talking).
        #expect(loop.handle(.userSpeechStarted) == [.stopPlayback, .state(.listening)])
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

    @Test func micForwardingStaysOnWhileLive() {
        var loop = VoiceLoop()
        #expect(loop.shouldForwardMicAudio)
        _ = loop.handle(.userSpeechStopped)
        _ = loop.handle(.assistantAudio(pcm(1)))
        // Even while the AI speaks, the mic streams — server VAD needs it for barge-in.
        #expect(loop.shouldForwardMicAudio)
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

    @Test func speechStartStopEventsMapFromWireFrames() {
        #expect(ProxyRealtimeSession.mapEvent(["type": "input_audio_buffer.speech_started"]) != nil)
        #expect(ProxyRealtimeSession.mapEvent(["type": "input_audio_buffer.speech_stopped"]) != nil)
        if case .userSpeechStarted = ProxyRealtimeSession.mapEvent(["type": "input_audio_buffer.speech_started"])! {
        } else {
            Issue.record("speech_started should map to .userSpeechStarted")
        }
    }
}
