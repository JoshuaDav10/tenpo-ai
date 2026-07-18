import Foundation

/// Supabase GoTrue connection (the `/auth/v1` sibling of the PostgREST URL SyncKit
/// talks to). Email one-time-code sign-in is the MVP auth method: it needs no Apple
/// entitlements, so it works on a free-Apple-ID sideload build. Sign in with Apple
/// can join later without touching callers (they only see `AuthManager`).
public struct SupabaseAuthConfig: Sendable {
    public var authURL: URL          // https://<ref>.supabase.co/auth/v1
    public var anonKey: String

    public init(authURL: URL, anonKey: String) {
        self.authURL = authURL
        self.anonKey = anonKey
    }
}

/// A signed-in user's tokens. `userID` is the Supabase auth UUID — the same value
/// RLS compares against `auth.uid()`, so it is what SyncKit stamps into `user_id`.
public struct AuthSession: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String
    public var userID: String
    public var email: String?
    public var expiresAt: Date

    public init(accessToken: String, refreshToken: String, userID: String, email: String?, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.userID = userID
        self.email = email
        self.expiresAt = expiresAt
    }
}

public enum AuthError: Error, Sendable {
    case http(status: Int, body: String)
    case malformedResponse
    case notSignedIn
}

/// Thin client for the three GoTrue endpoints the app needs. Stateless; the
/// `AuthManager` owns persistence and refresh policy.
public actor SupabaseAuthClient {
    private let config: SupabaseAuthConfig
    private let session: URLSession

    public init(config: SupabaseAuthConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    /// Emails the user a 6-digit one-time code (creates the account on first use).
    public func requestCode(email: String) async throws {
        _ = try await post(path: "otp", body: ["email": email, "create_user": true])
    }

    /// Exchanges the emailed code for tokens.
    public func verifyCode(email: String, code: String) async throws -> AuthSession {
        let data = try await post(path: "verify", body: ["type": "email", "email": email, "token": code])
        return try Self.parseSession(data)
    }

    /// Trades a refresh token for a fresh access token.
    public func refresh(refreshToken: String) async throws -> AuthSession {
        let data = try await post(path: "token", query: [URLQueryItem(name: "grant_type", value: "refresh_token")],
                                  body: ["refresh_token": refreshToken])
        return try Self.parseSession(data)
    }

    // MARK: - transport

    private func post(path: String, query: [URLQueryItem] = [], body: [String: Any]) async throws -> Data {
        let url = config.authURL.appendingPathComponent(path)
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if !query.isEmpty { components?.queryItems = query }
        guard let finalURL = components?.url else { throw AuthError.malformedResponse }
        var request = URLRequest(url: finalURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw AuthError.http(status: status, body: String(decoding: data, as: UTF8.self))
        }
        return data
    }

    /// GoTrue token payload → AuthSession. `expires_at` (epoch seconds) is preferred;
    /// older responses only carry `expires_in`.
    static func parseSession(_ data: Data, now: Date = Date()) throws -> AuthSession {
        struct TokenResponse: Decodable {
            struct User: Decodable { let id: String; let email: String? }
            let access_token: String
            let refresh_token: String
            let expires_in: Double?
            let expires_at: Double?
            let user: User
        }
        guard let parsed = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            throw AuthError.malformedResponse
        }
        let expiresAt = parsed.expires_at.map { Date(timeIntervalSince1970: $0) }
            ?? now.addingTimeInterval(parsed.expires_in ?? 3600)
        return AuthSession(
            accessToken: parsed.access_token, refreshToken: parsed.refresh_token,
            userID: parsed.user.id, email: parsed.user.email, expiresAt: expiresAt
        )
    }
}
