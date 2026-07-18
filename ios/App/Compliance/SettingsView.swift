import SwiftUI

/// Settings (§8): privacy transparency, licenses, and the required account controls
/// (in-app deletion + data export).
struct SettingsView: View {
    let container: AppContainer
    let compliance: ComplianceStore

    @State private var exportURL: URL?
    @State private var showDeleteConfirm = false
    @State private var busy = false
    @State private var deletedNote: String?

    @State private var persona = Preferences.persona
    @State private var forceCheap = Preferences.forceCheapMode
    @State private var signedInEmail: String?

    var body: some View {
        List {
            Section {
                if let auth = container.auth {
                    NavigationLink {
                        AccountView(auth: auth)
                    } label: {
                        if let signedInEmail {
                            Label(signedInEmail, systemImage: "person.crop.circle.badge.checkmark")
                        } else {
                            Label("Sign in for sync & voice", systemImage: "person.crop.circle")
                        }
                    }
                }
            } header: {
                Text("Account")
            } footer: {
                if container.auth == nil {
                    Text("Sync is off in this build (no backend configured). Everything stays on this device.")
                }
            }
            .task {
                if let auth = container.auth, await auth.isSignedIn {
                    signedInEmail = await auth.email ?? "Signed in"
                }
            }

            Section("Roleplay partner") {
                Picker("Voice & persona", selection: $persona) {
                    ForEach(Preferences.personaChoices) { choice in
                        Text(choice.name).tag(choice.persona)
                    }
                }
                if let blurb = Preferences.personaChoices.first(where: { $0.persona == persona })?.blurb {
                    Text(blurb).font(.caption).foregroundStyle(.secondary)
                }
            }
            .onChange(of: persona) { _, new in Preferences.persona = new }

            Section {
                Toggle("Save on voice costs", isOn: $forceCheap)
                    .onChange(of: forceCheap) { _, new in Preferences.forceCheapMode = new }
            } footer: {
                Text("Always use the cheaper text-based roleplay pipeline instead of live voice. Turn this off for the full spoken-conversation experience.")
            }

            Section("Privacy") {
                NavigationLink {
                    ProvidersView(consentDate: compliance.consentDate)
                } label: {
                    Label("AI providers & data use", systemImage: "cloud")
                }
                NavigationLink {
                    LicensesView()
                } label: {
                    Label("Licenses & Sources", systemImage: "doc.text")
                }
            }

            Section("Your data") {
                Button {
                    Task { await export() }
                } label: {
                    Label("Export my data (JSON)", systemImage: "square.and.arrow.up")
                }
                .disabled(busy)

                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label("Delete my account & data", systemImage: "trash")
                }
                .disabled(busy)

                if let deletedNote {
                    Text(deletedNote).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section {
                LabeledContent("Version", value: "0.1.0")
            } footer: {
                Text("Tenpo keeps your audio only long enough to grade it, then deletes it, unless you turn on saved recordings. Learner data stays on your device.")
            }
        }
        .navigationTitle("Settings")
        .sheet(item: $exportURL) { url in
            ShareSheet(items: [url])
        }
        .confirmationDialog("Delete everything?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete my account & data", role: .destructive) {
                Task { await deleteAccount() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes your reviews, mastery, and session history from this device. The curriculum stays. This can't be undone.")
        }
    }

    private func export() async {
        busy = true; defer { busy = false }
        exportURL = try? await DataManager.exportJSON(container.db)
    }

    private func deleteAccount() async {
        busy = true; defer { busy = false }
        try? await DataManager.deleteLearnerData(container.db)
        compliance.revokeConsent()
        deletedNote = "Your data was deleted."
    }
}

private struct ProvidersView: View {
    let consentDate: Date?
    var body: some View {
        List {
            if let consentDate {
                Section {
                    LabeledContent("Consent given", value: consentDate.formatted(date: .abbreviated, time: .shortened))
                }
            }
            Section {
                ForEach(AIProviders.all) { p in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.name).font(.subheadline)
                        Text(p.purpose).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Processors")
            } footer: {
                Text("Voice audio and conversation text are sent to these providers to run the app. Per their API terms they do not train on your data.")
            }
        }
        .navigationTitle("AI Providers")
    }
}

/// Minimal UIActivityViewController wrapper for the export share sheet.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
