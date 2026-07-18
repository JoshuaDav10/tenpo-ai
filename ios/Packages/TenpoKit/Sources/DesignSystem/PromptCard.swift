import SwiftUI

/// Shared drill-shell primitive (§4.6 SessionRunner UI). Grows in Phase 2
/// alongside AnswerBar, FuriganaText, PitchContourView, TranscriptView.
public struct PromptCard: View {
    let title: String
    let subtitle: String?

    public init(title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    public var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.title)
                .multilineTextAlignment(.center)
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}
