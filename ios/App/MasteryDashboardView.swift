import SwiftUI
import CoreModels
import LearnerModel

/// The transparent mastery dashboard (§6, R17): per-dimension counts by stability
/// band. No streaks, no loss-aversion — just an honest picture of what you know.
struct MasteryDashboardView: View {
    let container: AppContainer

    @State private var summary: MasterySummary?
    @State private var dueCount = 0
    @State private var todaySpend = 0.0

    var body: some View {
        List {
            Section {
                if dueCount > 0 {
                    // §3.1 Anki-trust: tap through to see WHY each item is due.
                    NavigationLink {
                        WhyDueView(container: container)
                    } label: {
                        LabeledContent("Due now", value: "\(dueCount)")
                    }
                } else {
                    LabeledContent("Due now", value: "\(dueCount)")
                }
                LabeledContent("Tracked skills", value: "\(summary?.total.total ?? 0)")
                LabeledContent("Spent today", value: todaySpend.formatted(.currency(code: "USD")))
            }

            if let summary, !summary.dimensions.isEmpty {
                Section("Mastery by skill") {
                    ForEach(summary.dimensions, id: \.dimension) { entry in
                        DimensionRow(entry: entry)
                    }
                }
                Section("Overall") {
                    BandBar(counts: summary.total)
                }
            } else {
                ContentUnavailableView(
                    "No reviews yet",
                    systemImage: "chart.bar",
                    description: Text("Finish a session and your mastery will appear here — learning, young, and mature items per skill.")
                )
            }
        }
        .navigationTitle("Mastery")
        .task { await load() }
    }

    private func load() async {
        summary = try? await container.learner.masteryCounts()
        dueCount = (try? await container.learner.dueCount(now: Date())) ?? 0
        todaySpend = await container.todaySpendUSD()
    }
}

private struct DimensionRow: View {
    let entry: DimensionMastery

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline).bold()
            BandBar(counts: entry.counts)
        }
        .padding(.vertical, 4)
    }

    private var title: String {
        switch entry.dimension {
        case .recognitionReading: return "Reading → meaning"
        case .recognitionListening: return "Listening → meaning"
        case .productionWritten: return "Produce (writing)"
        case .productionSpoken: return "Produce (speaking)"
        }
    }
}

/// learning (<2d) / young (<21d) / mature (≥21d) as a proportional bar + legend.
private struct BandBar: View {
    let counts: MasteryBandCounts

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    segment(counts.learning, .orange, geo.size.width)
                    segment(counts.young, .blue, geo.size.width)
                    segment(counts.mature, .green, geo.size.width)
                }
            }
            .frame(height: 10)
            .clipShape(Capsule())

            HStack(spacing: 12) {
                legend(.orange, "Learning \(counts.learning)")
                legend(.blue, "Young \(counts.young)")
                legend(.green, "Mature \(counts.mature)")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func segment(_ value: Int, _ color: Color, _ totalWidth: CGFloat) -> some View {
        let total = max(counts.total, 1)
        color.frame(width: max(0, totalWidth * CGFloat(value) / CGFloat(total)))
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text)
        }
    }
}
