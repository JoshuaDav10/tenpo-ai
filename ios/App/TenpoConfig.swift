import Foundation
import AuthKit
import SpeechKit
import SyncKit
import RealtimeKit

/// Deployment endpoints, read from the bundled `TenpoConfig.plist`. All values are
/// PUBLIC identifiers (the Supabase anon key is designed to ship in clients; secrets
/// live only in Fly). Blank values mean "not deployed yet" — the container then keeps
/// the corresponding mock/no-op provider, so the app always boots.
struct TenpoConfig {
    /// https://<app>.fly.dev — the deployed proxy. Blank → mock speech/chat/realtime.
    let proxyURL: URL?
    /// https://<ref>.supabase.co — the Supabase project. Blank → no auth, no sync.
    let supabaseURL: URL?
    let supabaseAnonKey: String?

    static func load(bundle: Bundle = .main) -> TenpoConfig {
        let dict = bundle.url(forResource: "TenpoConfig", withExtension: "plist")
            .flatMap { NSDictionary(contentsOf: $0) as? [String: String] } ?? [:]
        func url(_ key: String) -> URL? {
            guard let raw = dict[key]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
            return URL(string: raw)
        }
        func string(_ key: String) -> String? {
            guard let raw = dict[key]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
            return raw
        }
        return TenpoConfig(
            proxyURL: url("PROXY_URL"),
            supabaseURL: url("SUPABASE_URL"),
            supabaseAnonKey: string("SUPABASE_ANON_KEY")
        )
    }

    // MARK: - derived per-service configs

    var authConfig: SupabaseAuthConfig? {
        guard let supabaseURL, let supabaseAnonKey else { return nil }
        return SupabaseAuthConfig(
            authURL: supabaseURL.appendingPathComponent("auth/v1"), anonKey: supabaseAnonKey)
    }

    func syncConfig(userID: String, accessToken: @escaping @Sendable () async -> String?) -> SupabaseConfig? {
        guard let supabaseURL, let supabaseAnonKey else { return nil }
        return SupabaseConfig(
            restURL: supabaseURL.appendingPathComponent("rest/v1"),
            anonKey: supabaseAnonKey, userID: userID, accessToken: accessToken)
    }

    func proxyConfig(authToken: @escaping @Sendable () async -> String?) -> ProxyConfig? {
        guard let proxyURL else { return nil }
        return ProxyConfig(baseURL: proxyURL, authToken: authToken)
    }

    /// wss:// endpoint for the realtime bridge, derived from the proxy URL.
    func realtimeConfig(authToken: @escaping @Sendable () async -> String?) -> ProxyRealtimeConfig? {
        guard let proxyURL,
              var components = URLComponents(url: proxyURL.appendingPathComponent("realtime"),
                                             resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        guard let url = components.url else { return nil }
        return ProxyRealtimeConfig(baseURL: url, authToken: authToken)
    }
}
