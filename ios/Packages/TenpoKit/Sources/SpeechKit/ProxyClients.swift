import Foundation
import CoreModels

/// Configuration for talking to the Tenpo proxy (§7). The auth token is fetched
/// lazily so it can refresh (Supabase JWT) without rebuilding the clients.
public struct ProxyConfig: Sendable {
    public var baseURL: URL
    public var authToken: @Sendable () async -> String?

    public init(baseURL: URL, authToken: @escaping @Sendable () async -> String?) {
        self.baseURL = baseURL
        self.authToken = authToken
    }
}

/// Minimal JSON-over-HTTPS client to the proxy. Audio crosses the wire base64-encoded
/// inside JSON — simple and uniform for the handful of calls the cascade makes.
struct ProxyClient: Sendable {
    let config: ProxyConfig
    let session: URLSession

    init(config: ProxyConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    func post<Body: Encodable, Response: Decodable>(
        _ path: String, body: Body, as: Response.Type
    ) async throws -> Response {
        var request = URLRequest(url: config.baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = await config.authToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw SpeechError.proxyError(status: status, body: String(decoding: data, as: UTF8.self))
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }
}

// MARK: - Server STT (Deepgram via proxy /stt)

public struct ProxySTTProvider: STTProvider {
    let client: ProxyClient

    public init(config: ProxyConfig, session: URLSession = .shared) {
        self.client = ProxyClient(config: config, session: session)
    }

    struct Request: Encodable {
        let audio: String        // base64
        let encoding: String
        let sampleRate: Int
        let locale: String
        let hints: [String]
    }
    struct Response: Decodable {
        let text: String
        let confidence: Double
        let alternatives: [String]?
        let provider: String
    }

    public func transcribe(_ audio: AudioClip, locale: LanguageID, hints: [String]) async throws -> Transcription {
        let req = Request(
            audio: audio.data.base64EncodedString(),
            encoding: audio.encoding.rawValue,
            sampleRate: audio.sampleRate,
            locale: locale.rawValue,
            hints: hints
        )
        let res: Response = try await client.post("stt", body: req, as: Response.self)
        return Transcription(
            text: res.text, confidence: res.confidence,
            alternatives: res.alternatives ?? [], provider: ProviderID(rawValue: res.provider)
        )
    }
}

// MARK: - TTS (ElevenLabs/OpenAI via proxy /tts, cache-first on the server)

public struct ProxyTTSProvider: TTSProvider {
    let client: ProxyClient

    public init(config: ProxyConfig, session: URLSession = .shared) {
        self.client = ProxyClient(config: config, session: session)
    }

    struct Request: Encodable {
        let text: String
        let voice: String
        let locale: String
    }
    struct Response: Decodable {
        let audio: String        // base64
        let encoding: String
        let sampleRate: Int
    }

    public func synthesize(_ text: String, voice: VoiceID, locale: LanguageID) async throws -> AudioClip {
        let req = Request(text: text, voice: voice.rawValue, locale: locale.rawValue)
        let res: Response = try await client.post("tts", body: req, as: Response.self)
        guard let data = Data(base64Encoded: res.audio) else { throw SpeechError.encodingUnsupported }
        let encoding = AudioEncoding(rawValue: res.encoding) ?? .mp3
        return AudioClip(data: data, encoding: encoding, sampleRate: res.sampleRate)
    }
}

// MARK: - Pronunciation (Azure via proxy /pron)

public struct ProxyPronunciationAssessor: PronunciationAssessor {
    let client: ProxyClient

    public init(config: ProxyConfig, session: URLSession = .shared) {
        self.client = ProxyClient(config: config, session: session)
    }

    struct Request: Encodable {
        let audio: String        // base64
        let encoding: String
        let sampleRate: Int
        let referenceText: String
        let locale: String
    }
    struct Response: Decodable {
        struct Phoneme: Decodable { let phoneme: String; let score: Double }
        let overall: Double
        let fluency: Double?
        let prosody: Double?
        let phonemes: [Phoneme]?
        let provider: String
    }

    public func assess(_ audio: AudioClip, referenceText: String, locale: LanguageID) async throws -> PronunciationReport {
        let req = Request(
            audio: audio.data.base64EncodedString(),
            encoding: audio.encoding.rawValue,
            sampleRate: audio.sampleRate,
            referenceText: referenceText,
            locale: locale.rawValue
        )
        let res: Response = try await client.post("pron", body: req, as: Response.self)
        return PronunciationReport(
            overall: res.overall, fluency: res.fluency, prosody: res.prosody,
            phonemes: (res.phonemes ?? []).map { .init(phoneme: $0.phoneme, score: $0.score) },
            provider: ProviderID(rawValue: res.provider)
        )
    }
}

/// Reads the proxy's authoritative cost meter (`GET /usage`, §4.3.6). Any failure
/// (unconfigured, offline, non-2xx, bad JSON) returns nil so the caller falls back
/// to the local meter — cost transparency must never block the app.
public struct ProxyUsageService: UsageSource {
    let config: ProxyConfig
    let session: URLSession

    public init(config: ProxyConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    public func todayUsage() async -> ServerUsage? {
        var request = URLRequest(url: config.baseURL.appendingPathComponent("usage"))
        request.httpMethod = "GET"
        if let token = await config.authToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let usage = try? JSONDecoder().decode(ServerUsage.self, from: data)
        else { return nil }
        return usage
    }
}
