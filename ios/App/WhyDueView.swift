import SwiftUI
import CoreModels
import ContentKit
import LearnerModel

/// The FSRS "why is this due?" inspector (§3.1 Anki-trust). Exposes the scheduler
/// instead of hiding it: for each due item, the learner sees the current recall
/// probability, memory stability, review history, and a plain-English reason.
struct WhyDueView: View {
    let container: AppContainer

    @State private var rows: [DueExplanation] = []
    @State private var names: [String: String] = [:]   // itemID → display word
    @State private var loaded = false

    var body: some View {
        List {
            Section {
                Text("Your schedule, not a black box. Each item is here because you're due to reinforce it — here's why.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(rows) { row in
                WhyDueRow(row: row, name: names[row.itemID.rawValue])
            }
        }
        .navigationTitle("Why these are due")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if loaded && rows.isEmpty {
                ContentUnavailableView("Nothing due right now",
                                       systemImage: "checkmark.circle",
                                       description: Text("You're all caught up. New items and reviews will appear as they come due."))
            }
        }
        .task { await load() }
    }

    private func load() async {
        let explanations = (try? await container.learner.dueExplanations(now: Date(), limit: 50)) ?? []
        // Resolve display words for the items we can (vocab lemmas); others show their id.
        var resolved: [String: String] = [:]
        for e in explanations {
            if let item = try? await container.content.item(id: e.itemID) {
                let f = VocabFields(item)
                if !f.lemma.isEmpty {
                    resolved[e.itemID.rawValue] = f.reading.map { "\(f.lemma)（\($0)）" } ?? f.lemma
                }
            }
        }
        rows = explanations
        names = resolved
        loaded = true
    }
}

private struct WhyDueRow: View {
    let row: DueExplanation
    let name: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(name ?? row.itemID.rawValue)
                    .font(.headline)
                Spacer()
                Text(dimensionLabel).font(.caption2).foregroundStyle(.secondary)
            }
            RetrievabilityBar(value: row.retrievability)
            Text(row.headline)
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                stat("stability", "\(Int(row.stability.rounded()))d")
                stat("reviews", "\(row.reps)")
                if row.lapses > 0 { stat("lapses", "\(row.lapses)") }
            }
            .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        HStack(spacing: 3) { Text(label); Text(value).bold() }
    }

    private var dimensionLabel: String {
        switch row.dimension {
        case .recognitionReading: return "reading → meaning"
        case .recognitionListening: return "listening → meaning"
        case .productionWritten: return "meaning → written"
        case .productionSpoken: return "meaning → spoken"
        }
    }
}

/// A slim recall-probability meter. Green when well-retained, amber when slipping.
private struct RetrievabilityBar: View {
    let value: Double // 0…1

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(tint).frame(width: max(4, geo.size.width * value))
            }
        }
        .frame(height: 6)
        .overlay(alignment: .trailing) {
            Text("\(Int((value * 100).rounded()))% recall")
                .font(.caption2).foregroundStyle(.secondary)
                .offset(y: -12)
        }
        .padding(.bottom, 10)
    }

    private var tint: Color {
        if value >= 0.9 { return .green }
        if value >= 0.7 { return .yellow }
        return .orange
    }
}
