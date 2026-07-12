import Foundation
import CoreModels

/// Connection config for the realtime bridge (§4.3.1 Pipeline A). The auth token
/// (Supabase JWT) is passed as a query param because browsers/WS can't set headers.
public struct ProxyRealtimeConfig: Sendable {
    public var baseURL: URL          // wss://<proxy-host>/realtime
    public var authToken: @Sendable () async -> String?

    public init(baseURL: URL, authToken: @escaping @Sendable () async -> String?) {
        self.baseURL = baseURL
        self.authToken = authToken
    }
}

/// Live realtime voice via the proxy `/realtime` WSS bridge.
///
/// LIVE-VERIFY: requires the deployed proxy + OpenAI Realtime key. The event-name
/// mapping below follows the OpenAI Realtime protocol; re-verify names at
/// integration time (provider catalogs change — §4.3.3 note).
public final class ProxyRealtimeVoiceProvider: RealtimeVoiceProvider, RealtimeVoiceService, @unchecked Sendable {
    private let config: ProxyRealtimeConfig
    private let session: URLSession

    public init(config: ProxyRealtimeConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    public func openSession(_ config: RealtimeConfig) async throws -> any RealtimeSession {
        var components = URLComponents(url: self.config.baseURL, resolvingAgainstBaseURL: false)!
        if let token = await self.config.authToken() {
            components.queryItems = [URLQueryItem(name: "token", value: token)]
        }
        guard let url = components.url else { throw RealtimeError.badURL }

        let task = session.webSocketTask(with: url)
        let proxySession = ProxyRealtimeSession(task: task)
        task.resume()

        // First frame carries the scenario/persona so the bridge can build the
        // Actor instructions (§4.4). Prompt text itself lives on the server (§7).
        let initFrame = RealtimeInitFrame(variables: config.variables)
        try await proxySession.sendJSON(initFrame)
        proxySession.startReceiveLoop()
        return proxySession
    }
}

public enum RealtimeError: Error, Sendable { case badURL, notConnected }

private struct RealtimeInitFrame: Encodable {
    var type = "init"
    var variables: [String: JSONValue]
}

/// One realtime session over a `URLSessionWebSocketTask`.
final class ProxyRealtimeSession: RealtimeSession, @unchecked Sendable {
    let events: AsyncStream<RealtimeEvent>
    private let continuation: AsyncStream<RealtimeEvent>.Continuation
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
        var cont: AsyncStream<RealtimeEvent>.Continuation!
        self.events = AsyncStream { cont = $0 }
        self.continuation = cont
    }

    func send(audio: AudioBuffer) async throws {
        try await sendJSON([
            "type": "input_audio_buffer.append",
            "audio": audio.data.base64EncodedString(),
        ])
    }

    /// Director → Actor steering mid-scene (§4.4 actor_directive).
    func send(systemUpdate: String) async throws {
        try await sendJSON([
            "type": "session.update",
            "session": ["instructions": systemUpdate],
        ] as [String: Any])
    }

    func interrupt() async throws {
        try await sendJSON(["type": "response.cancel"])
    }

    func close() async {
        task.cancel(with: .goingAway, reason: nil)
        continuation.finish()
    }

    // MARK: - transport

    func sendJSON(_ value: some Encodable) async throws {
        let data = try JSONEncoder().encode(value)
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
    }

    func sendJSON(_ dict: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: dict)
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
    }

    func startReceiveLoop() {
        Task { [weak self] in
            guard let self else { return }
            while true {
                do {
                    let message = try await self.task.receive()
                    switch message {
                    case .string(let text): self.handle(text)
                    case .data(let data): self.handle(String(decoding: data, as: UTF8.self))
                    @unknown default: break
                    }
                } catch {
                    self.continuation.yield(.error(error.localizedDescription))
                    self.continuation.finish()
                    return
                }
            }
        }
    }

    /// Map OpenAI Realtime events to our provider-agnostic `RealtimeEvent`s.
    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }

        switch type {
        case "response.audio.delta", "response.output_audio.delta":
            if let b64 = obj["delta"] as? String, let audio = Data(base64Encoded: b64) {
                continuation.yield(.assistantAudio(AudioBuffer(data: audio, encoding: .pcm16, sampleRate: 24000)))
            }
        case "response.audio_transcript.delta", "response.output_audio_transcript.delta":
            if let delta = obj["delta"] as? String {
                continuation.yield(.assistantTranscript(delta))
            }
        case "conversation.item.input_audio_transcription.completed":
            if let transcript = obj["transcript"] as? String {
                continuation.yield(.partialTranscript(role: .learner, text: transcript))
            }
        case "response.done", "response.output_audio.done":
            continuation.yield(.turnEnded(role: .actor))
        case "error":
            let message = (obj["error"] as? [String: Any])?["message"] as? String ?? "realtime error"
            continuation.yield(.error(message))
        default:
            break
        }
    }
}
