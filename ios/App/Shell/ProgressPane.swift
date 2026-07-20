import SwiftUI
import DesignSystem
import LearnerModel

/// The pane above home: glanceable widget cards backed by the real learner
/// model (FSRS bands, heatmap, forecast — substance Pingo doesn't have).
struct ProgressPane: View {
    let container: AppContainer

    @State private var streak = 0
    @State private var dueCount = 0
    @State private var summary: MasterySummary?
    @State private var grid: WeakAreaGrid?
    @State private var forecast: DueForecast?
    @State private var spent: Double = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    Text("My progress")
                        .font(.title2.bold())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 74) // full-screen pane: clear the status bar

                    HStack(spacing: 14) {
                        StatCard(value: "\(streak)", label: "day streak",
                                 icon: "flame.fill", tint: .orange)
                        dueCard
                        StatCard(value: "\(summary?.total.total ?? 0)", label: "skills tracked",
                                 icon: "brain.fill", tint: TenpoBlob.defaultPalette[1])
                    }

                    if let summary, !summary.dimensions.isEmpty {
                        card("Mastery by skill") {
                            ForEach(summary.dimensions, id: \.dimension) { entry in
                                DimensionRow(entry: entry)
                            }
                            BandBar(counts: summary.total)
                        }
                    }
                    if let grid, !grid.cells.isEmpty {
                        card("Weak areas") { WeakAreaHeatmap(grid: grid) }
                    }
                    if let forecast {
                        card("Upcoming reviews") { ForgettingForecast(forecast: forecast) }
                    }

                    HStack {
                        Image(systemName: "yensign.circle")
                            .foregroundStyle(.secondary)
                        Text("Voice spend today")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(spent, format: .currency(code: "USD"))
                            .font(.subheadline.bold().monospacedDigit())
                    }
                    .padding()
                    .background(.white, in: RoundedRectangle(cornerRadius: 16))

                    Text("swipe down to get back")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.bottom, 30)
                }
                .padding(.horizontal, 18)
            }
            .background(Color(red: 0.98, green: 0.97, blue: 0.95))
        }
        .task {
            streak = await container.streakDays()
            dueCount = (try? await container.learner.dueCount(now: Date())) ?? 0
            summary = try? await container.learner.masteryCounts()
            grid = try? await container.learner.weakAreaGrid()
            forecast = try? await container.learner.dueForecast(now: Date(), days: 7)
            spent = await container.displaySpendUSD()
        }
    }

    /// Due-now taps through to the why-due inspector (§3.1 Anki-trust).
    private var dueCard: some View {
        NavigationLink {
            WhyDueView(container: container)
        } label: {
            StatCard(value: "\(dueCount)", label: "due now",
                     icon: "clock.fill", tint: TenpoBlob.defaultPalette[0])
        }
        .buttonStyle(.plain)
    }

    private func card(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.white, in: RoundedRectangle(cornerRadius: 20))
    }
}

struct StatCard: View {
    var value: String
    var label: String
    var icon: String
    var tint: Color

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(tint)
            Text(value)
                .font(.title2.bold().monospacedDigit())
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(.white, in: RoundedRectangle(cornerRadius: 16))
    }
}
