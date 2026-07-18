import SwiftUI
import CoreModels
import ModeEngine
import RealtimeKit

/// The conversation-first surface (SESSION_DESIGN.md §1): no send button, no
/// push-to-talk. The AI speaks, listens, auto-endpoints, responds; talking over
/// it interrupts it. This view is the thin host — every decision lives in the
/// unit-tested `VoiceLoop`.
@MainActor
final class VoiceSessionModel: ObservableObject {
    struct Line: Identifiable, Equatable {
        let id = UUID()
        var isLearner: Bool
        var text: String
    }

    @Published var state: VoiceLoopState = .thinking // scene opens with the AI's greeting
    @Published var lines: [Line] = []
    @Published var latencyMS: Int?
    @Published var failure: String?
    @Published var fallbackToText = false
    @Published var micDenied = false

    private let realtime: any RealtimeVoiceService
    private let scenario: Scenario
    private var session: (any RealtimeSession)?
    private var loop = VoiceLoop()
    private var meter = VoiceLatencyMeter()
    private var pump: Task<Void, Never>?
    #if os(iOS)
    private var engine: RealtimeAudioEngine?
    #endif

    init(realtime: any RealtimeVoiceService, scenario: Scenario) {
        self.realtime = realtime
        self.scenario = scenario
    }

    func start() async {
        #if os(iOS)
        guard await AVAudioApplication.requestRecordPermission() else {
            micDenied = true
            return
        }
        #endif
        do {
            // Variables mirror the server's getRealtimeInstructions contract.
            let config = RealtimeConfig(
                actorTemplateID: "actor_turn",
                variables: [
                    "setting": .string(scenario.setting),
                    "persona": .string(Preferences.persona.rawValue),
                    "register": .string(scenario.register),
                    "band": .string(scenario.band),
                ],
                voice: VoiceID(rawValue: Preferences.persona.rawValue),
                locale: LanguageID(rawValue: "ja")
            )
            let session = try await realtime.openSession(config)
            self.session = session

            #if os(iOS)
            let engine = RealtimeAudioEngine { [weak self] chunk in
                Task { [weak self] in await self?.forwardMic(chunk) }
            }
            try engine.start()
            self.engine = engine
            #endif

            pump = Task { [weak self] in
                for await event in session.events {
                    await self?.handle(event)
                }
            }
        } catch {
            failure = "Couldn't open the voice session. Check your connection and try again."
        }
    }

    func end() async {
        pump?.cancel()
        #if os(iOS)
        engine?.stop()
        #endif
        await session?.close()
        session = nil
    }

    private func forwardMic(_ chunk: CoreModels.AudioBuffer) async {
        guard loop.shouldForwardMicAudio, let session else { return }
        try? await session.send(audio: chunk)
    }

    private func handle(_ event: RealtimeEvent) async {
        meter.note(event)
        latencyMS = meter.lastVoiceToVoiceMS
        for action in loop.handle(event) {
            switch action {
            case .play(let buffer):
                #if os(iOS)
                engine?.play(buffer)
                #endif
            case .stopPlayback:
                #if os(iOS)
                engine?.stopPlayback()
                #endif
                // Tell the server to cancel the in-flight reply too (barge-in).
                if state == .speaking || state == .thinking {
                    try? await session?.interrupt()
                }
            case .state(let new):
                state = new
            case .learnerSaid(let text):
                lines.append(Line(isLearner: true, text: text))
            case .assistantSaid(let text):
                lines.append(Line(isLearner: false, text: text))
            case .fallbackToCascade:
                fallbackToText = true
            case .failed(let code):
                failure = Self.friendly(code)
            }
        }
    }

    private static func friendly(_ code: String) -> String {
        switch code {
        case "cost_hard_cap":
            return "Today's spending cap is reached — voice roleplay is paused until tomorrow. Drills are always free."
        case "provider_not_configured":
            return "The voice service isn't set up on the server yet (missing provider key)."
        case "unauthorized":
            return "Sign in (Settings → Account) to use live voice."
        default:
            return "Voice session ended unexpectedly (\(code))."
        }
    }
}

struct VoiceSessionView: View {
    let scenario: Scenario
    /// Builds the text-mode session when the soft cap forces the cascade mid-entry.
    let makeTextFallback: () -> ActiveRoleplay?

    @StateObject private var model: VoiceSessionModel
    @State private var textFallback: ActiveRoleplay?
    @Environment(\.dismiss) private var dismiss

    init(realtime: any RealtimeVoiceService, scenario: Scenario,
         makeTextFallback: @escaping () -> ActiveRoleplay?) {
        self.scenario = scenario
        self.makeTextFallback = makeTextFallback
        _model = StateObject(wrappedValue: VoiceSessionModel(realtime: realtime, scenario: scenario))
    }

    var body: some View {
        VStack(spacing: 24) {
            header
            Spacer()
            orb
            statusLine
            Spacer()
            transcriptPeek
        }
        .padding()
        .navigationTitle(scenario.title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    Task { await model.end(); dismiss() }
                } label: {
                    Label("End", systemImage: "xmark.circle.fill")
                }
            }
            #if DEBUG
            ToolbarItem(placement: .topBarTrailing) {
                if let ms = model.latencyMS {
                    Text("\(ms)ms").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            #endif
        }
        .task { await model.start() }
        .onDisappear { Task { await model.end() } }
        .navigationDestination(item: $textFallback) { rp in
            GuidedRoleplayView(runner: rp.runner, scenario: rp.scenario)
        }
        .onChange(of: model.fallbackToText) { _, needsFallback in
            guard needsFallback else { return }
            textFallback = makeTextFallback()
        }
    }

    private var header: some View {
        Text(scenario.setting)
            .font(.subheadline).foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
    }

    /// The one visual that carries the whole interaction: breathing while
    /// listening, pulsing while thinking, rippling while the AI speaks.
    private var orb: some View {
        ZStack {
            Circle()
                .fill(orbColor.opacity(0.15))
                .frame(width: 190, height: 190)
                .scaleEffect(model.state == .speaking ? 1.15 : 1.0)
                .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true),
                           value: model.state)
            Circle()
                .fill(orbColor.gradient)
                .frame(width: 140, height: 140)
                .scaleEffect(model.state == .listening ? 1.06 : 1.0)
                .animation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true),
                           value: model.state)
            Image(systemName: orbSymbol)
                .font(.system(size: 44))
                .foregroundStyle(.white)
        }
    }

    private var orbColor: Color {
        switch model.state {
        case .listening: return .blue
        case .thinking: return .orange
        case .speaking: return .green
        case .ended: return .gray
        }
    }

    private var orbSymbol: String {
        switch model.state {
        case .listening: return "waveform"
        case .thinking: return "ellipsis"
        case .speaking: return "speaker.wave.2.fill"
        case .ended: return "checkmark"
        }
    }

    private var statusLine: some View {
        Group {
            if model.micDenied {
                Text("Tenpo needs the microphone for conversation practice. Enable it in Settings → Privacy → Microphone.")
                    .foregroundStyle(.red)
            } else if let failure = model.failure {
                Text(failure).foregroundStyle(.red)
            } else {
                Text(statusText).foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .multilineTextAlignment(.center)
    }

    private var statusText: String {
        switch model.state {
        case .listening: return "Your turn — just talk. You can interrupt any time."
        case .thinking: return model.lines.isEmpty ? "Starting the conversation…" : "…"
        case .speaking: return "" // the voice itself is the feedback
        case .ended: return "Session ended."
        }
    }

    /// Ambient transcript: the last few lines, quietly, so reading never becomes
    /// the primary interaction.
    private var transcriptPeek: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(model.lines.suffix(4)) { line in
                HStack {
                    if line.isLearner { Spacer(minLength: 30) }
                    Text(line.text)
                        .font(.footnote)
                        .foregroundStyle(line.isLearner ? .primary : .secondary)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.quaternary.opacity(0.5), in: Capsule())
                    if !line.isLearner { Spacer(minLength: 30) }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.default, value: model.lines)
    }
}

#if os(iOS)
import AVFAudio
#endif
