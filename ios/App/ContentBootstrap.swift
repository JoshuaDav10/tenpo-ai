import Foundation
import ContentKit

/// First-launch content seeding (§9 Phase 1 step 3). Idempotent: loads the bundled
/// `tools/seed` curriculum into the local store only when it is empty.
enum ContentBootstrap {
    @discardableResult
    static func run(_ container: AppContainer) async -> Int {
        do {
            // Upserts every authored seed item, so new/updated lessons, patterns,
            // and glosses reach already-seeded installs on next launch.
            return try await container.content.seedSync(from: .main, subdirectory: "seed")
        } catch {
            // A seeding failure must not brick the app — drills just have nothing
            // to draw yet. Surface via the count; log for the debug screen later.
            print("content seed failed: \(error)")
            return 0
        }
    }
}
