import SwiftUI
import CoreModels
import ModeEngine
import RealtimeKit
import DesignSystem

/// The conducted voice lesson screen (SESSION_DESIGN.md): orb + study card +
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
    @StateObject private var model: LessonSessionModel
    @Environment(\.dismiss) private var dismiss
    #if DEBUG
    @State private var typed = ""
    #endif

    init(runner: SessionRunner, audio: VoiceAudioIO, lesson: LessonScript) {
        self.lesson = lesson
        _model = StateObject(wrappedValue: LessonSessionModel(runner: runner, audio: audio))
    }

    var body: some View {
        VStack(spacing: 16) {
            topBar
            header
            if let card = model.card { studyCard(card) }
            Spacer(minLength: 8)
            orb
            statusLine
            Spacer(minLength: 8)
            if model.finished { debrief } else { transcriptPeek }
            #if DEBUG
            if !model.finished { devTextEntry }
            #endif
        }
        .padding()
        .navigationBarHidden(true)
        .tenpoCanvas()
        .task { await model.start() }
        .onDisappear { Task { await model.teardown() } }
    }

    /// In-content top bar (no system nav chrome) matching the shell's calm look:
    /// End on the left, a segmented step progress bar filling the width.
    private var topBar: some View {
        HStack(spacing: 12) {
            Button { Task { await model.end() } } label: {
                Image(systemName: "xmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 34)
                    .background(.thinMaterial, in: Circle())
            }
            if model.stepTotal > 0 {
                StepProgressBar(current: model.finished ? model.stepTotal : model.stepIndex,
                                total: model.stepTotal)
            }
        }
        .padding(.top, 4)
    }

    private var header: some View {
        VStack(spacing: 6) {
            Text(lesson.topicEN)
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let goals = model.goals {
                Label("\(goals.done)/\(goals.total) goals", systemImage: "checkmark.seal")
                    .font(.caption).bold()
                    .foregroundStyle(TenpoTheme.blue)
            }
            if let banner = model.banner {
                Text(banner)
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(8)
                    .background(TenpoTheme.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    /// The study card: what to say, how to read it, what it means.
    private func studyCard(_ card: LessonSessionModel.Card) -> some View {
        VStack(spacing: 6) {
            Text(card.text)
                .font(.system(size: 32, weight: .semibold))
            if let reading = card.reading, reading != card.text {
                Text(reading).font(.callout).foregroundStyle(.secondary)
            }
            if let gloss = card.gloss {
                Text(gloss).font(.footnote).foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(TenpoTheme.surface, in: RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
        .transition(.scale(scale: 0.96).combined(with: .opacity))
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: card)
    }

    private var orb: some View {
        VoiceStateBlob(state: model.state, celebrate: model.finished) { Task { await model.tapOrb() } }
    }

    private var statusLine: some View {
        Group {
            if model.micDenied {
                Text("Tenpo needs the microphone for voice lessons. Enable it in Settings → Privacy → Microphone.")
                    .foregroundStyle(.red)
            } else {
                Text(statusText).foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .multilineTextAlignment(.center)
    }

    private var statusText: String {
        if model.finished { return "Lesson complete!" }
        switch model.state {
        case .listening: return "Your turn — take your time."
        case .thinking: return model.lines.isEmpty ? "Starting your lesson…" : "…"
        case .speaking: return "Tap the circle to jump in."
        case .ended: return ""
        }
    }

    private var transcriptPeek: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(model.lines.suffix(3)) { line in
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

    private var debrief: some View {
        ScrollView {
            VStack(spacing: 12) {
                if let summary = model.summary {
                    Text(summary)
                        .font(.callout).bold()
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                if !model.errors.isEmpty {
                    ErrorTaxonomyView(errors: model.errors)
                }
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    #if DEBUG
    /// Simulator/dev path: type instead of speak (LearnerInput.text).
    private var devTextEntry: some View {
        HStack {
            TextField("dev: type your line", text: $typed)
                .textFieldStyle(.roundedBorder)
                .font(.footnote)
                .onSubmit {
                    let text = typed
                    typed = ""
                    Task { await model.sendTyped(text) }
                }
        }
    }
    #endif
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
