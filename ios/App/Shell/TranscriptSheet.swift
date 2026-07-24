import SwiftUI
import CoreModels
import ContentKit
import DesignSystem

/// The on-demand transcript (Joshua's parity items 3–7): every line, with romaji
/// under the Japanese, a kanji⇄kana toggle, and every word tappable for an
/// explanation. This is where a learner gets granular after the fact.
struct TranscriptSheet: View {
    let lines: [LessonSessionModel.Line]
    let analyzer: SentenceAnalyzer

    @Environment(\.dismiss) private var dismiss
    @AppStorage("transcript_show_romaji") private var showRomaji = true
    @AppStorage("transcript_show_kana") private var showKana = false
    @State private var analyses: [UUID: AnalyzedSentence] = [:]
    @State private var explaining: AnalyzedToken?

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(lines) { line in
                            TranscriptBubble(
                                line: line,
                                analysis: analyses[line.id],
                                showRomaji: showRomaji,
                                showKana: showKana,
                                onTapToken: { explaining = $0 }
                            )
                            .id(line.id)
                        }
                    }
                    .padding()
                }
                .onAppear { proxy.scrollTo(lines.last?.id, anchor: .bottom) }
            }
            .background(TenpoTheme.canvas)
            .navigationTitle("Transcript")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Toggle("Romaji", isOn: $showRomaji)
                        Toggle("Kana instead of kanji", isOn: $showKana)
                    } label: {
                        Image(systemName: "textformat.size.ja")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task(id: lines.count) { await analyzeAll() }
            .sheet(item: $explaining) { token in
                WordExplanation(token: token)
                    .presentationDetents([.height(280), .medium])
            }
        }
    }

    private func analyzeAll() async {
        for line in lines where analyses[line.id] == nil {
            analyses[line.id] = await analyzer.analyze(line.text)
        }
    }
}

/// One transcript line: tappable words, optional kana substitution, romaji under.
private struct TranscriptBubble: View {
    let line: LessonSessionModel.Line
    let analysis: AnalyzedSentence?
    let showRomaji: Bool
    let showKana: Bool
    var onTapToken: (AnalyzedToken) -> Void

    var body: some View {
        HStack {
            if line.isLearner { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 6) {
                if let analysis, !analysis.tokens.isEmpty {
                    tokenFlow(analysis)
                    if showRomaji, !analysis.romaji.isEmpty {
                        Text(analysis.romaji)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(line.text)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(line.isLearner ? TenpoTheme.pink.opacity(0.14) : TenpoTheme.surface,
                        in: RoundedRectangle(cornerRadius: 16))
            if !line.isLearner { Spacer(minLength: 40) }
        }
    }

    /// Words laid out as wrapping tappable chips; explainable ones are underlined
    /// so it's discoverable that they can be tapped.
    private func tokenFlow(_ analysis: AnalyzedSentence) -> some View {
        FlowLayout(spacing: 1) {
            ForEach(analysis.tokens) { token in
                let text = showKana ? (token.reading ?? token.surface) : token.surface
                Text(text)
                    .font(.body)
                    .underline(token.isExplainable, color: TenpoTheme.blue.opacity(0.35))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard token.isExplainable else { return }
                        onTapToken(token)
                    }
            }
        }
    }
}

/// Tap-a-word explanation: reading, romaji, meaning, and grammar note.
struct WordExplanation: View {
    let token: AnalyzedToken

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(token.surface)
                    .font(.system(size: 40, weight: .semibold))
                if let reading = token.reading, reading != token.surface {
                    Text(reading).font(.title3).foregroundStyle(.secondary)
                }
                if let romaji = token.romaji, !romaji.isEmpty {
                    Text(romaji).font(.callout).foregroundStyle(.tertiary)
                }
            }

            if !token.glosses.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Meaning").font(.caption.bold()).foregroundStyle(.secondary)
                    Text(token.glosses.joined(separator: ", ")).font(.body)
                }
            }

            if let note = token.note {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Grammar").font(.caption.bold()).foregroundStyle(.secondary)
                    Text(note).font(.body)
                }
            }

            if token.itemID != nil {
                Label("In your review deck", systemImage: "brain.head.profile")
                    .font(.caption)
                    .foregroundStyle(TenpoTheme.blue)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
        .background(TenpoTheme.canvas)
    }
}

/// Minimal wrapping layout — words flow like text but stay individually tappable.
struct FlowLayout: Layout {
    var spacing: CGFloat = 2

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
