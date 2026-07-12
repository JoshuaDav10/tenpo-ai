import SwiftUI

/// Blocking third-party-AI consent gate (§8.1 Guideline 5.1.2(i), Nov 2025 update).
/// Names every AI processor and states that voice audio and conversation text are
/// sent to them, before the first session. Explicit opt-in; consent stored.
struct ConsentView: View {
    let store: ComplianceStore

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Before you start")
                        .font(.largeTitle).bold()

                    Text("Kizuna uses AI services to understand and grade your Japanese. When you practice, your **voice recordings and conversation text** are sent to the providers below for processing.")
                        .font(.body)

                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(AIProviders.all) { p in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "cloud")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 22)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(p.name).font(.subheadline).bold()
                                    Text(p.purpose).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .padding()
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))

                    Text("These providers process your data to run the app and, per their API terms, do not train their models on it. You can review the full list any time in Settings → Privacy. Audio is deleted after grading unless you turn on “save recordings.”")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding()
            }

            VStack(spacing: 8) {
                Button {
                    store.grantConsent()
                } label: {
                    Text("I understand and agree")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)

                Text("Agreeing is required to use practice features.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding()
            .background(.bar)
        }
    }
}
