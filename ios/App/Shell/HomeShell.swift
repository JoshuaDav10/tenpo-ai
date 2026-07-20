import SwiftUI
import DesignSystem

/// The session-first app shell. The home pane IS the pre-session screen; progress
/// lives one swipe above, the plan one swipe below. Chrome is exiled to corner
/// chips and edge hints — nothing competes with Start.
struct HomeShell: View {
    let container: AppContainer
    let compliance: ComplianceStore

    private enum Pane: Int {
        case progress = 0, home = 1, plan = 2
    }

    @State private var pane: Pane = HomeShell.initialPane
    @GestureState private var drag: CGFloat = 0
    @State private var showSettings = false
    @State private var streak = 0

    /// DEBUG screenshot hook: launch with TENPO_PANE=progress|plan to land there.
    private static var initialPane: Pane {
        #if DEBUG
        switch ProcessInfo.processInfo.environment["TENPO_PANE"] {
        case "progress": return .progress
        case "plan": return .plan
        default: return .home
        }
        #else
        return .home
        #endif
    }

    var body: some View {
        GeometryReader { geo in
            // geo covers the FULL screen (ignoresSafeArea below); panes own their
            // internal padding, so no neighbor ever peeks through an inset gap.
            let height = geo.size.height
            ZStack(alignment: .top) {
                VStack(spacing: 0) {
                    ProgressPane(container: container)
                        .frame(width: geo.size.width, height: height)
                    SessionHomePane(container: container)
                        .frame(width: geo.size.width, height: height)
                    PlanPane(container: container)
                        .frame(width: geo.size.width, height: height)
                }
                .offset(y: -CGFloat(pane.rawValue) * height + drag)
                .animation(.spring(response: 0.42, dampingFraction: 0.86), value: pane)
                .animation(.interactiveSpring, value: drag)

                chrome(height: height)
                    .padding(.top, 62) // manual status-bar clearance (safe area ignored)
            }
            .gesture(
                DragGesture(minimumDistance: 12)
                    .updating($drag) { value, state, _ in
                        // Only vertical intent moves the pane stack; the mode
                        // carousel owns horizontal.
                        guard abs(value.translation.height) > abs(value.translation.width) else { return }
                        state = rubberBanded(value.translation.height, height: height)
                    }
                    .onEnded { value in
                        guard abs(value.translation.height) > abs(value.translation.width) else { return }
                        let threshold = height / 5
                        if value.predictedEndTranslation.height < -threshold, pane.rawValue < 2 {
                            pane = Pane(rawValue: pane.rawValue + 1) ?? pane
                        } else if value.predictedEndTranslation.height > threshold, pane.rawValue > 0 {
                            pane = Pane(rawValue: pane.rawValue - 1) ?? pane
                        }
                    }
            )
        }
        .ignoresSafeArea()
        .background(Color(red: 0.98, green: 0.97, blue: 0.95).ignoresSafeArea())
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView(container: container, compliance: compliance)
            }
        }
        .task { streak = await container.streakDays() }
    }

    /// Corner chips + edge hints, visible on the home pane only.
    @ViewBuilder
    private func chrome(height: CGFloat) -> some View {
        VStack {
            HStack {
                Button { showSettings = true } label: {
                    Image(systemName: "person.crop.circle")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .padding(10)
                        .background(.thinMaterial, in: Circle())
                }
                Spacer()
                HStack(spacing: 5) {
                    Image(systemName: "flame.fill")
                        .foregroundStyle(streak > 0 ? .orange : .secondary)
                    Text("\(streak)")
                        .font(.subheadline.bold().monospacedDigit())
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.thinMaterial, in: Capsule())
            }
            .padding(.horizontal, 20)

            Button { pane = .progress } label: {
                VStack(spacing: 2) {
                    Image(systemName: "chevron.compact.up")
                    Text("My progress").font(.caption2)
                }
                .foregroundStyle(.tertiary)
            }
            Spacer()
            Button { pane = .plan } label: {
                VStack(spacing: 2) {
                    Text("My plan").font(.caption2)
                    Image(systemName: "chevron.compact.down")
                }
                .foregroundStyle(.tertiary)
            }
            .padding(.bottom, 6)
        }
        .opacity(pane == .home && drag == 0 ? 1 : 0)
        .animation(.easeInOut(duration: 0.2), value: pane)
    }

    private func rubberBanded(_ translation: CGFloat, height: CGFloat) -> CGFloat {
        let atTop = pane == .progress && translation > 0
        let atBottom = pane == .plan && translation < 0
        if atTop || atBottom {
            return translation * 0.25 // resist beyond the ends
        }
        return translation
    }
}
