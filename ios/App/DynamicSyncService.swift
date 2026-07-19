import Foundation
import AuthKit
import SyncKit
import Persistence

/// Sync that follows the auth state: no-op while signed out, Supabase once a user
/// exists. Consulting the AuthManager on every `syncNow()` means signing in (or out)
/// mid-run takes effect on the next session boundary — no container rebuild, no
/// app restart.
actor DynamicSyncService: SyncService {
    private let db: DatabaseManager
    private let config: TenpoConfig
    private let auth: AuthManager
    private var live: (userID: String, service: SupabaseSyncService)?
    private(set) var lastSyncedAt: Date?

    init(db: DatabaseManager, config: TenpoConfig, auth: AuthManager) {
        self.db = db
        self.config = config
        self.auth = auth
    }

    /// §8.2: delete every remote row the signed-in user owns, then drop the live
    /// service so a later sign-in starts clean. No-op while signed out.
    func purgeRemote() async throws {
        guard let userID = await auth.userID else { return }
        let supabase = try await resolveService(userID: userID)
        try await supabase?.purgeRemote()
        live = nil
    }

    private func resolveService(userID: String) async throws -> SupabaseSyncService? {
        if live?.userID == userID { return live?.service }
        guard let supabase = config.syncConfig(userID: userID, accessToken: { [auth] in
            await auth.validAccessToken()
        }) else { return nil }
        let service = SupabaseSyncService(db: db, config: supabase)
        live = (userID, service)
        return service
    }

    func syncNow() async throws {
        guard let userID = await auth.userID else { return } // signed out → local-only
        if live?.userID != userID {
            guard let supabase = config.syncConfig(userID: userID, accessToken: { [auth] in
                await auth.validAccessToken()
            }) else { return }
            live = (userID, SupabaseSyncService(db: db, config: supabase))
        }
        try await live?.service.syncNow()
        lastSyncedAt = Date()
    }
}
