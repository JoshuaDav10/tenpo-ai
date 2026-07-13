import Testing
import Foundation
@testable import RealtimeKit
import CoreModels

/// The realtime bridge multiplexes two frame dialects on `type: "error"`: the proxy's
/// own control frames (bare string `error` code) and upstream OpenAI errors (object
/// with `message`). Regression coverage for a contract mismatch where the client
/// mis-parsed every proxy frame as a generic error.
@Suite struct RealtimeEventMappingTests {

    @Test func proxyCostCheapModeMapsToCheapFallback() {
        let event = ProxyRealtimeSession.mapEvent(["type": "error", "error": "cost_cheap_mode", "note": "…"])
        guard case let .proxyRefused(code, cheap) = event else { Issue.record("expected proxyRefused, got \(String(describing: event))"); return }
        #expect(code == "cost_cheap_mode")
        #expect(cheap == true)
    }

    @Test func proxyHardCapAndAuthMapWithoutCheapFallback() {
        for code in ["cost_hard_cap", "unauthorized", "provider_not_configured", "bad_init"] {
            let event = ProxyRealtimeSession.mapEvent(["type": "error", "error": code])
            guard case let .proxyRefused(got, cheap) = event else { Issue.record("expected proxyRefused for \(code)"); return }
            #expect(got == code)
            #expect(cheap == false)
        }
    }

    @Test func upstreamOpenAIErrorObjectMapsToError() {
        let event = ProxyRealtimeSession.mapEvent(["type": "error", "error": ["message": "rate limit", "type": "server_error"]])
        guard case let .error(message) = event else { Issue.record("expected error, got \(String(describing: event))"); return }
        #expect(message == "rate limit")
    }

    @Test func audioAndTranscriptDeltasMap() {
        let pcm = Data([0, 1, 2, 3])
        let audio = ProxyRealtimeSession.mapEvent(["type": "response.output_audio.delta", "delta": pcm.base64EncodedString()])
        guard case .assistantAudio = audio else { Issue.record("expected assistantAudio"); return }

        let transcript = ProxyRealtimeSession.mapEvent(["type": "response.output_audio_transcript.delta", "delta": "こん"])
        guard case let .assistantTranscript(t) = transcript else { Issue.record("expected assistantTranscript"); return }
        #expect(t == "こん")
    }

    @Test func unknownTypeIsIgnored() {
        #expect(ProxyRealtimeSession.mapEvent(["type": "session.created"]) == nil)
        #expect(ProxyRealtimeSession.mapEvent(["no_type": true]) == nil)
    }
}
