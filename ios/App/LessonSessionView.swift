import SwiftUI
import CoreModels
import ModeEngine
import RealtimeKit
import DesignSystem
import ContentKit

/// The conducted voice lesson screen (SESSION_DESIGN.md): Pingo-minimal —
/// ambient transcript, no send button. All decisions live in GuidedLessonMode;
/// this view owns only hardware (mic/speaker) and rendering, connected through
/// VoiceAudioIO — which is what lets the lesson run through SessionRunner.
@MainActor
final class LessonSessionModel: ObservableObject {
    struct Line: Identifiable, Equatable {
        let id = UUID()
        var isLearner: Bool
        var text: String
    }
    struct Card: Equatable {
        var text: String
        var reading: String?
        var gloss: String?
    }

    @Published var state: VoiceLoopState = .thinking
    @Published var lines: [Line] = []
    @Published var card: Card?
    @Published var banner: String?
    @Published var stepIndex = 0
    @Published var stepTotal = 0
    @Published var goals: (done: Int, total: Int)?
    @Published var finished = false
    @Published var errors: [ErrorEvent] = []
    @Published var summary: String?
    @Published var micDenied = false

    private let runner: SessionRunner
    private let audio: VoiceAudioIO
    private var eventTask: Task<Void, Never>?
    private var audioTask: Task<Void, Never>?
    #if os(iOS)
    private var engine: RealtimeAudioEngine?
    #endif

    init(runner: SessionRunner, audio: VoiceAudioIO) {
        self.runner = runner
        self.audio = audio
    }

    func start() async {
        #if os(iOS)
        // Dev harness (TENPO_MOCK_VOICE) types input instead of speaking, so it
        // needs no mic — skip the prompt that would otherwise block the sim.
        let mockVoice = ProcessInfo.processInfo.environment["TENPO_MOCK_VOICE"] == "1"
        if !mockVoice {
            guard await AVAudioApplication.requestRecordPermission() else {
                micDenied = true
                return
            }
            let engine = RealtimeAudioEngine { [audio] chunk in
                audio.submitMic(chunk)
            }
            try? engine.start()
            self.engine = engine
        }
        #endif

        audioTask = Task { [weak self] in
            guard let stream = self?.audio.output else { return }
            for await output in stream {
                await self?.applyAudio(output)
            }
        }
        eventTask = Task { [weak self] in
            guard let events = self?.runner.events else { return }
            for await event in events {
                await self?.apply(event)
            }
        }
        await runner.start()
    }

    func tapOrb() async {
        await runner.handle(.tap(choiceID: "interrupt"))
    }

    func sendTyped(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await runner.handle(.text(trimmed))
    }

    func end() async {
        await runner.handle(.quit)
    }

    func teardown() async {
        eventTask?.cancel()
        audioTask?.cancel()
        #if os(iOS)
        engine?.stop()
        #endif
    }

    private func applyAudio(_ output: VoiceAudioIO.Output) {
        switch output {
        case .play(let buffer):
            #if os(iOS)
            engine?.play(buffer)
            #endif
        case .stop:
            #if os(iOS)
            engine?.stopPlayback()
            #endif
        case .state(let new):
            state = new
        }
    }

    private func apply(_ event: ModeEvent) async {
        switch event {
        case .prompt(let text, _):
            lines.append(Line(isLearner: false, text: text))
        case .heard(let t):
            lines.append(Line(isLearner: true, text: t.text))
        case .card(let text, let reading, let gloss):
            card = Card(text: text, reading: reading, gloss: gloss)
        case .progress(let current, let total):
            stepIndex = current
            stepTotal = total
            if card != nil { card = nil } // card belongs to one step only
        case .goalProgress(let done, let total):
            goals = (done, total)
        case .info(let text):
            banner = text
        case .verdict:
            break
        case .choices:
            break
        case .finished:
            let result = await runner.finish()
            finished = true
            errors = result.errors
            summary = result.status == .completed
                ? "Lesson complete. Anything you missed is queued for review."
                : "Lesson ended — your progress is saved."
            await teardown()
        }
    }
}

struct LessonSessionView: View {
    let lesson: LessonScript
    let analyzer: SentenceAnalyzer
    @StateObject private var model: LessonSessionModel
    @Environment(\.dismiss) private var dismiss
    @State private var showTranscript = false
    #if DEBUG
    @State private var typed = ""
    #endif

    init(runner: SessionRunner, audio: VoiceAudioIO, lesson: LessonScript,
         analyzer: SentenceAnalyzer) {
        self.lesson = lesson
        self.analyzer = analyzer
        _model = StateObject(wrappedValue: LessonSessionModel(runner: runner, audio: audio))
    }

    var body: some View {
        ZStack {
            if model.finished {
                CompletionScreen(title: lesson.title, errors: model.errors,
                                 praised: model.summary?.contains("complete") ?? false) {
                    dismiss()
                }
                .transition(.opacity)
            } else {
                conversation
            }
        }
        .animation(.easeInOut(duration: 0.4), value: model.finished)
        .navigationBarHidden(true)
        .task { await model.start() }
        .onDisappear { Task { await model.teardown() } }
        .sheet(isPresented: $showTranscript) {
            TranscriptSheet(lines: model.lines, analyzer: analyzer)
        }
    }

    // MARK: - conversation (Pingo-minimal: character + one hint, nothing else)

    private var conversation: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, 20)
                .padding(.top, 10)
            Spacer()
            VoiceStateBlob(state: model.state) { Task { await model.tapOrb() } }
            hintLine
                .padding(.top, 22)
                .padding(.horizontal, 40)
            Spacer()
            #if DEBUG
            devTextEntry
                .padding(.horizontal, 20)
                .padding(.bottom, 6)
            #endif
            transcriptTab
                .padding(.bottom, 14)
        }
        .tenpoCanvas()
    }

    /// End on the left; a subtle step-progress bar (our edge over Pingo, which
    /// gives no sense of place). No topic, no goals, no cards — pure voice.
    private var topBar: some View {
        HStack(spacing: 14) {
            Button { Task { await model.end() } } label: {
                Image(systemName: "xmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 34)
                    .background(.thinMaterial, in: Circle())
            }
            if model.stepTotal > 0 {
                StepProgressBar(current: model.stepIndex, total: model.stepTotal)
            }
        }
    }

    private var hintLine: some View {
        Group {
            if model.micDenied {
                Text("Tenpo needs the microphone. Enable it in Settings → Privacy → Microphone.")
                    .foregroundStyle(.red)
            } else {
                Text(statusText).foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .multilineTextAlignment(.center)
        .animation(.easeInOut, value: model.state)
    }

    private var statusText: String {
        switch model.state {
        case .listening: return "Your turn — just speak."
        case .thinking: return model.lines.isEmpty ? "Starting your lesson…" : "…"
        case .speaking: return "Tap to interrupt."
        case .ended: return ""
        }
    }

    /// The pull-up affordance for the on-demand transcript.
    private var transcriptTab: some View {
        Button { showTranscript = true } label: {
            VStack(spacing: 2) {
                Image(systemName: "chevron.compact.up")
                Text("Transcript").font(.subheadline.weight(.medium))
            }
            .foregroundStyle(TenpoTheme.blue)
        }
        .disabled(model.lines.isEmpty)
        .opacity(model.lines.isEmpty ? 0.4 : 1)
    }

    #if DEBUG
    /// Simulator/dev path: type instead of speak (LearnerInput.text).
    private var devTextEntry: some View {
        TextField("dev: type your line", text: $typed)
            .textFieldStyle(.roundedBorder)
            .font(.footnote)
            .onSubmit {
                let text = typed
                typed = ""
                Task { await model.sendTyped(text) }
            }
    }
    #endif
}

/// Full-bleed celebration (Pingo's completion), then the honest debrief below —
/// keeping our substance (what to firm up, queued for review).
private struct CompletionScreen: View {
    let title: String
    let errors: [ErrorEvent]
    let praised: Bool
    var onDone: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VoiceStateBlob(state: .ended, celebrate: true) {}
                    .padding(.top, 60)
                Text(praised ? "Nice work!" : "Good effort!")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.85))
                Text("\(title) complete!")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                if !errors.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("A few things queued for review")
                            .font(.subheadline.bold())
                            .foregroundStyle(.white)
                        ErrorTaxonomyView(errors: errors)
                    }
                    .padding()
                    .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, 20)
                }

                Button(action: onDone) {
                    Text("Done")
                        .font(.headline)
                        .frame(width: 200, height: 52)
                        .background(.white, in: Capsule())
                        .foregroundStyle(TenpoTheme.blue)
                }
                .padding(.top, 8)
                Spacer(minLength: 40)
            }
            .frame(maxWidth: .infinity)
        }
        .background(
            LinearGradient(colors: [TenpoTheme.blue, TenpoTheme.blue.opacity(0.82)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
    }
}

/// Segmented lesson progress: one filled pill per completed step.
struct StepProgressBar: View {
    let current: Int
    let total: Int

    var body: some View {
        GeometryReader { geo in
            let gap: CGFloat = 4
            let width = (geo.size.width - gap * CGFloat(max(total - 1, 0))) / CGFloat(max(total, 1))
            HStack(spacing: gap) {
                ForEach(0..<max(total, 1), id: \.self) { i in
                    Capsule()
                        .fill(i < current ? TenpoTheme.blue : Color.primary.opacity(0.12))
                        .frame(width: width, height: 5)
                }
            }
            .animation(.spring(response: 0.3), value: current)
        }
        .frame(height: 5)
    }
}

#if os(iOS)
import AVFAudio
#endif
