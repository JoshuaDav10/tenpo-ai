import SwiftUI

@main
struct KizunaApp: App {
    private let bootstrap = AppBootstrap()
    @StateObject private var compliance = ComplianceStore()

    var body: some Scene {
        WindowGroup {
            switch bootstrap.result {
            case .success(let container):
                // §8.1: block practice behind explicit third-party-AI consent.
                if compliance.hasConsented {
                    HomeView(container: container, compliance: compliance)
                } else {
                    ConsentView(store: compliance)
                }
            case .failure(let error):
                BootFailureView(error: error)
            }
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
