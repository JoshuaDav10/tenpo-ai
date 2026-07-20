import SwiftUI
import CoreModels
import ModeEngine
import RealtimeKit

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
        guard await AVAudioApplication.requestRecordPermission() else {
            micDenied = true
            return
        }
        let engine = RealtimeAudioEngine { [audio] chunk in
            audio.submitMic(chunk)
        }
        try? engine.start()
        self.engine = engine
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
        .navigationTitle(lesson.title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    Task { await model.end() }
                } label: {
                    Label("End", systemImage: "xmark.circle.fill")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if model.stepTotal > 0 && !model.finished {
                    Text("\(min(model.stepIndex + 1, model.stepTotal))/\(model.stepTotal)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task { await model.start() }
        .onDisappear { Task { await model.teardown() } }
    }

    private var header: some View {
        VStack(spacing: 6) {
            Text(lesson.topicEN)
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let goals = model.goals {
                Label("\(goals.done)/\(goals.total) goals", systemImage: "checkmark.seal")
                    .font(.caption).bold()
            }
            if let banner = model.banner {
                Text(banner)
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(6)
                    .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
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
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .transition(.opacity)
        .animation(.default, value: card)
    }

    private var orb: some View {
        VoiceStateBlob(state: model.state) { Task { await model.tapOrb() } }
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

#if os(iOS)
import AVFAudio
#endif
