import SwiftUI
import DesignSystem

/// Home = the queue (§6). One primary button building today's interleaved session.
/// Phase 0: empty state proving the container + database boot; the queue arrives
/// with the learner spine in Phase 1.
struct HomeView: View {
    let container: AppContainer

    @State private var contentCount: Int?
    @State private var trackedCount: Int?

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                PromptCard(
                    title: "絆 Kizuna",
                    subtitle: "Voice-first Japanese practice"
                )
                .padding(.horizontal)

                Button {
                    // SessionRunner starts the daily queue here in Phase 1.
                } label: {
                    Label("Today's session", systemImage: "waveform")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .disabled(true)
                .padding(.horizontal)

                Text("Curriculum arrives in Phase 1 — the queue will build itself from your reviews.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                Spacer()

                if let contentCount, let trackedCount {
                    Text("\(contentCount) content items · \(trackedCount) tracked skills")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .navigationTitle("Kizuna")
            .task { await loadCounts() }
        }
    }

    private func loadCounts() async {
        contentCount = (try? await container.content.itemCount()) ?? 0
        trackedCount = (try? await container.learner.trackedItemCount()) ?? 0
    }
}

#Preview {
    HomeView(container: try! AppContainer.preview())
}
