import SwiftUI
import AuthKit

/// Email one-time-code sign-in (Supabase GoTrue). Signing in is what turns on
/// cross-device sync and authenticates proxy calls; the app is fully usable
/// without it (local-first, D7).
struct AccountView: View {
    let auth: AuthManager

    private enum Phase {
        case enterEmail
        case enterCode(email: String)
        case signedIn(email: String?)
    }

    @State private var phase: Phase = .enterEmail
    @State private var email = ""
    @State private var code = ""
    @State private var busy = false
    @State private var errorNote: String?

    var body: some View {
        List {
            switch phase {
            case .enterEmail:
                Section {
                    TextField("you@example.com", text: $email)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Email me a sign-in code") {
                        Task { await requestCode() }
                    }
                    .disabled(busy || !email.contains("@"))
                } header: {
                    Text("Sign in")
                } footer: {
                    Text("We'll email you a 6-digit code — no password to remember. First sign-in creates your account.")
                }

            case .enterCode(let pendingEmail):
                Section {
                    TextField("6-digit code", text: $code)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                    Button("Verify") {
                        Task { await verify(email: pendingEmail) }
                    }
                    .disabled(busy || code.trimmingCharacters(in: .whitespaces).count < 6)
                    Button("Use a different email") {
                        phase = .enterEmail
                        code = ""
                        errorNote = nil
                    }
                    .disabled(busy)
                } header: {
                    Text("Check your email")
                } footer: {
                    Text("Enter the code sent to \(pendingEmail).")
                }

            case .signedIn(let signedInEmail):
                Section("Account") {
                    LabeledContent("Signed in as", value: signedInEmail ?? "your account")
                    Button("Sign out", role: .destructive) {
                        Task { await signOut() }
                    }
                    .disabled(busy)
                }
                Section {
                    EmptyView()
                } footer: {
                    Text("Your review history now syncs across devices and voice practice uses your account's daily budget.")
                }
            }

            if let errorNote {
                Section {
                    Text(errorNote).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Account")
        .task { await reflectCurrentState() }
    }

    private func reflectCurrentState() async {
        if await auth.isSignedIn {
            phase = .signedIn(email: await auth.email)
        }
    }

    private func requestCode() async {
        busy = true; defer { busy = false }
        errorNote = nil
        do {
            let address = email.trimmingCharacters(in: .whitespaces)
            try await auth.requestCode(email: address)
            phase = .enterCode(email: address)
        } catch {
            errorNote = "Couldn't send the code. Check the address and your connection, then try again."
        }
    }

    private func verify(email: String) async {
        busy = true; defer { busy = false }
        errorNote = nil
        do {
            let session = try await auth.verifyCode(
                email: email, code: code.trimmingCharacters(in: .whitespaces))
            phase = .signedIn(email: session.email)
        } catch {
            errorNote = "That code didn't work. Codes expire after a few minutes — request a new one if needed."
        }
    }

    private func signOut() async {
        busy = true; defer { busy = false }
        await auth.signOut()
        phase = .enterEmail
        email = ""
        code = ""
    }
}
