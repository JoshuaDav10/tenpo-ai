import Testing
import Foundation
@testable import AuthKit

// MARK: - URLProtocol stub (same pattern as SyncKitTests: process-global, serialized)

final class AuthStub: URLProtocol, @unchecked Sendable {
    struct Captured: Sendable { let method: String; let url: URL; let body: Data? }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _captured: [Captured] = []
    nonisolated(unsafe) private static var _responder: (@Sendable (URL) -> (Int, Data))?

    static func reset(responder: @escaping @Sendable (URL) -> (Int, Data)) {
        lock.lock(); defer { lock.unlock() }
        _captured = []; _responder = responder
    }
    static var captured: [Captured] {
        lock.lock(); defer { lock.unlock() }; return _captured
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let body: Data? = request.httpBody ?? request.httpBodyStream.map { stream in
            stream.open(); defer { stream.close() }
            var data = Data(); var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buf, maxLength: buf.count)
                if read <= 0 { break }
                data.append(buf, count: read)
            }
            return data
        }
        Self.lock.lock()
        Self._captured.append(.init(method: request.httpMethod ?? "GET", url: request.url!, body: body))
        let responder = Self._responder
        Self.lock.unlock()
        let (status, data) = responder?(request.url!) ?? (500, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

// MARK: - helpers

private func makeClient() -> SupabaseAuthClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [AuthStub.self]
    return SupabaseAuthClient(
        config: SupabaseAuthConfig(
            authURL: URL(string: "https://example.supabase.co/auth/v1")!, anonKey: "anon-key"),
        session: URLSession(configuration: config)
    )
}

private func tokenJSON(access: String = "at-1", refresh: String = "rt-1",
                       expiresAt: Double? = nil, expiresIn: Double? = 3600) -> Data {
    var payload: [String: Any] = [
        "access_token": access, "refresh_token": refresh, "token_type": "bearer",
        "user": ["id": "uuid-99", "email": "j@example.com"],
    ]
    if let expiresAt { payload["expires_at"] = expiresAt }
    if let expiresIn { payload["expires_in"] = expiresIn }
    return try! JSONSerialization.data(withJSONObject: payload)
}

@Suite(.serialized) struct AuthKitTests {

    @Test func requestCodeHitsOTPEndpointWithEmail() async throws {
        AuthStub.reset { _ in (200, Data("{}".utf8)) }
        try await makeClient().requestCode(email: "j@example.com")

        let call = AuthStub.captured.first
        #expect(call?.url.path.hasSuffix("/auth/v1/otp") == true)
        let body = try JSONSerialization.jsonObject(with: call?.body ?? Data()) as? [String: Any]
        #expect(body?["email"] as? String == "j@example.com")
        #expect(body?["create_user"] as? Bool == true)
    }

    @Test func verifyCodeParsesTokensAndUser() async throws {
        AuthStub.reset { url in
            url.path.hasSuffix("/verify") ? (200, tokenJSON(expiresAt: 2_000_000_000)) : (404, Data())
        }
        let session = try await makeClient().verifyCode(email: "j@example.com", code: "123456")

        #expect(session.accessToken == "at-1")
        #expect(session.refreshToken == "rt-1")
        #expect(session.userID == "uuid-99")
        #expect(session.expiresAt == Date(timeIntervalSince1970: 2_000_000_000))

        let body = try JSONSerialization.jsonObject(with: AuthStub.captured.first?.body ?? Data()) as? [String: Any]
        #expect(body?["type"] as? String == "email")
        #expect(body?["token"] as? String == "123456")
    }

    @Test func validTokenIsReturnedWithoutRefreshWhenFresh() async throws {
        AuthStub.reset { _ in (500, Data()) } // any network call would fail the test
        let fresh = AuthSession(accessToken: "at-live", refreshToken: "rt", userID: "u",
                                email: nil, expiresAt: Date().addingTimeInterval(3600))
        let manager = AuthManager(client: makeClient(), store: InMemorySessionStore(session: fresh))

        #expect(await manager.validAccessToken() == "at-live")
        #expect(AuthStub.captured.isEmpty) // no refresh happened
    }

    @Test func expiringTokenIsRefreshedAndPersisted() async throws {
        AuthStub.reset { url in
            guard url.path.hasSuffix("/token"),
                  url.query?.contains("grant_type=refresh_token") == true else { return (404, Data()) }
            return (200, tokenJSON(access: "at-new", refresh: "rt-new"))
        }
        let store = InMemorySessionStore(session: AuthSession(
            accessToken: "at-old", refreshToken: "rt-old", userID: "u",
            email: nil, expiresAt: Date().addingTimeInterval(10))) // inside the 60s leeway
        let manager = AuthManager(client: makeClient(), store: store)

        #expect(await manager.validAccessToken() == "at-new")
        #expect(store.load()?.refreshToken == "rt-new") // rotated token persisted
        let body = try JSONSerialization.jsonObject(with: AuthStub.captured.first?.body ?? Data()) as? [String: Any]
        #expect(body?["refresh_token"] as? String == "rt-old")
    }

    @Test func signOutClearsSessionAndStore() async throws {
        AuthStub.reset { _ in (500, Data()) }
        let store = InMemorySessionStore(session: AuthSession(
            accessToken: "at", refreshToken: "rt", userID: "u",
            email: nil, expiresAt: Date().addingTimeInterval(3600)))
        let manager = AuthManager(client: makeClient(), store: store)

        await manager.signOut()
        #expect(await manager.isSignedIn == false)
        #expect(store.load() == nil)
        #expect(await manager.validAccessToken() == nil)
    }
}
