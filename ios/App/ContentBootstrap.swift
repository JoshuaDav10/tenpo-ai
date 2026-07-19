import Foundation
import ContentKit

/// First-launch content seeding (§9 Phase 1 step 3). Idempotent: loads the bundled
/// `tools/seed` curriculum into the local store only when it is empty.
enum ContentBootstrap {
    @discardableResult
    static func run(_ container: AppContainer) async -> Int {
        do {
            let fresh = try await container.content.seedIfEmpty(from: .main, subdirectory: "seed")
            // Kinds added after this device was first seeded (e.g. lessons) —
            // seedIfEmpty won't fire on a populated store.
            let topUp = try await container.content.seedMissingKinds(from: .main, subdirectory: "seed")
            return fresh + topUp
        } catch {
            // A seeding failure must not brick the app — drills just have nothing
            // to draw yet. Surface via the count; log for the debug screen later.
            print("content seed failed: \(error)")
            return 0
        }
    }
}
