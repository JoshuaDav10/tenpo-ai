import Foundation

/// Where the session lives between launches. Keychain in the app; in-memory in tests.
public protocol AuthSessionStore: Sendable {
    func load() -> AuthSession?
    func save(_ session: AuthSession)
    func clear()
}

public final class InMemorySessionStore: AuthSessionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var session: AuthSession?

    public init(session: AuthSession? = nil) { self.session = session }
    public func load() -> AuthSession? { lock.lock(); defer { lock.unlock() }; return session }
    public func save(_ session: AuthSession) { lock.lock(); defer { lock.unlock() }; self.session = session }
    public func clear() { lock.lock(); defer { lock.unlock() }; session = nil }
}

/// Owns the signed-in state: persists the session, hands out access tokens, and
/// refreshes them before expiry. This is the only auth type the rest of the app
/// talks to — `ProxyConfig.authToken` and `SupabaseConfig.accessToken` both close
/// over `validAccessToken()`.
public actor AuthManager {
    private let client: SupabaseAuthClient
    private let store: AuthSessionStore
    private let now: @Sendable () -> Date
    private var session: AuthSession?

    /// Refresh when the access token has less than this long to live.
    private static let refreshLeeway: TimeInterval = 60

    public init(client: SupabaseAuthClient, store: AuthSessionStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client
        self.store = store
        self.now = now
        self.session = store.load()
    }

    public var currentSession: AuthSession? { session }
    public var isSignedIn: Bool { session != nil }
    public var userID: String? { session?.userID }
    public var email: String? { session?.email }

    public func requestCode(email: String) async throws {
        try await client.requestCode(email: email)
    }

    public func verifyCode(email: String, code: String) async throws -> AuthSession {
        let fresh = try await client.verifyCode(email: email, code: code)
        session = fresh
        store.save(fresh)
        return fresh
    }

    /// A token safe to attach to a request right now, refreshing first if it is
    /// about to expire. Returns nil when signed out or the refresh fails (callers
    /// treat that as unauthenticated, not fatal — the app is local-first).
    public func validAccessToken() async -> String? {
        guard let current = session else { return nil }
        if current.expiresAt.timeIntervalSince(now()) > Self.refreshLeeway {
            return current.accessToken
        }
        guard let refreshed = try? await client.refresh(refreshToken: current.refreshToken) else {
            return nil
        }
        session = refreshed
        store.save(refreshed)
        return refreshed.accessToken
    }

    public func signOut() {
        session = nil
        store.clear()
    }
}
