import SwiftUI
import CoreModels

/// Mode 10 (§4.6): graded reading passages with a furigana toggle. Tap-to-lookup
/// via JMdict lands when the dictionary is imported (Phase 1 data); for now the
/// reader shows the sentence, its reading (furigana), and the translation.
struct ReaderView: View {
    let container: AppContainer

    @State private var sentences: [ContentItem] = []
    @State private var showFurigana = true

    var body: some View {
        List {
            Section {
                Toggle("Show furigana", isOn: $showFurigana)
            }
            ForEach(sentences) { item in
                SentenceRow(item: item, showFurigana: showFurigana)
            }
            if sentences.isEmpty {
                ContentUnavailableView("No passages yet", systemImage: "book",
                                       description: Text("Reading passages load with the curriculum."))
            }
        }
        .navigationTitle("Reader")
        .task { await load() }
    }

    private func load() async {
        // Sentence items, excluding the cloze drills (id "cloze:*").
        let all = (try? await container.content.items(kind: .sentence, band: nil, limit: 200)) ?? []
        sentences = all.filter { !$0.id.rawValue.hasPrefix("cloze:") }
    }
}

private struct SentenceRow: View {
    let item: ContentItem
    let showFurigana: Bool

    private var ja: String { item.payload["ja"]?.stringValue ?? "" }
    private var reading: String? { item.payload["reading"]?.stringValue }
    private var en: String? { item.payload["en"]?.stringValue }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if showFurigana, let reading, reading != ja {
                Text(reading).font(.caption).foregroundStyle(.secondary)
            }
            Text(ja).font(.title3)
            if let en {
                Text(en).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
