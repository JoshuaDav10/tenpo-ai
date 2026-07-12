import SwiftUI
import ModeEngine
import DesignSystem

/// Home = the queue (§6). One primary button building today's session; secondary
/// access to the mastery dashboard. Loads the bundled curriculum on first launch.
struct HomeView: View {
    let container: AppContainer

    @State private var contentCount = 0
    @State private var dueCount = 0
    @State private var loading = true
    @State private var activeSession: ActiveSession?

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                PromptCard(title: "絆 Kizuna", subtitle: "Voice-first Japanese practice")
                    .padding(.horizontal)

                Button {
                    Task { await startSession() }
                } label: {
                    Label("Today's session", systemImage: "waveform")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .disabled(loading || contentCount == 0)
                .padding(.horizontal)

                NavigationLink {
                    RoleplayListView(container: container)
                } label: {
                    Label("Roleplay", systemImage: "bubble.left.and.bubble.right.fill")
                }
                .disabled(loading || contentCount == 0)

                NavigationLink {
                    MasteryDashboardView(container: container)
                } label: {
                    Label("Mastery dashboard", systemImage: "chart.bar.fill")
                }

                Spacer()

                if loading {
                    ProgressView("Preparing your curriculum…")
                } else {
                    Text("\(contentCount) items · \(dueCount) due now")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Kizuna")
            .navigationDestination(item: $activeSession) { session in
                DrillView(runner: session.runner)
            }
            .task { await bootstrap() }
            .onChange(of: activeSession) { _, newValue in
                if newValue == nil { Task { await refreshCounts() } } // session dismissed → refresh
            }
        }
    }

    private func bootstrap() async {
        await ContentBootstrap.run(container)
        await refreshCounts()
        loading = false
    }

    private func refreshCounts() async {
        contentCount = (try? await container.content.itemCount()) ?? 0
        dueCount = (try? await container.learner.dueCount(now: Date())) ?? 0
    }

    private func startSession() async {
        if let runner = try? await container.makeDailySession() {
            activeSession = ActiveSession(runner: runner)
        }
    }
}

/// Identifiable/Hashable wrapper so a session can drive `navigationDestination`.
struct ActiveSession: Identifiable, Hashable {
    let id = UUID()
    let runner: SessionRunner
    static func == (lhs: ActiveSession, rhs: ActiveSession) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

#Preview {
    HomeView(container: try! AppContainer.preview())
}
