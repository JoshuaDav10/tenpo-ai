import SwiftUI

@main
struct KizunaApp: App {
    private let bootstrap = AppBootstrap()
    @StateObject private var compliance = ComplianceStore()

    var body: some Scene {
        WindowGroup {
            switch bootstrap.result {
            case .success(let container):
                #if DEBUG
                // Dev-only screenshot/preview routing: `-e KIZUNA_ROUTE dashboard|roleplay|
                // settings|drill` jumps straight to a screen (bypasses nav taps). Never ships.
                if let route = ProcessInfo.processInfo.environment["KIZUNA_ROUTE"] {
                    DebugRoute(route: route, container: container, compliance: compliance)
                } else {
                    rootView(container)
                }
                #else
                rootView(container)
                #endif
            case .failure(let error):
                BootFailureView(error: error)
            }
        }
    }

    @ViewBuilder
    private func rootView(_ container: AppContainer) -> some View {
        // §8.1: block practice behind explicit third-party-AI consent.
        if compliance.hasConsented {
            HomeView(container: container, compliance: compliance)
        } else {
            ConsentView(store: compliance)
        }
    }
}

/// Builds the AppContainer once at launch. A database failure at boot is shown,
/// not crashed on — learner state is the app's spine and the user should see why
/// it's unavailable.
@MainActor
private final class AppBootstrap {
    let result: Result<AppContainer, Error>

    init() {
        result = Result { try AppContainer.live() }
    }
}

private struct BootFailureView: View {
    let error: Error

    var body: some View {
        ContentUnavailableView(
            "Couldn't open the learner database",
            systemImage: "externaldrive.badge.exclamationmark",
            description: Text(error.localizedDescription)
        )
    }
}
