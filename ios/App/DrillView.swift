import SwiftUI
import CoreModels
import ModeEngine
import SpeechKit
import DesignSystem

/// Drives a `SessionRunner` and renders the shared drill shell (§4.6). Phase-1
/// scope is text answers; the mic path lands with the on-device recorder.
@MainActor
final class DrillViewModel: ObservableObject {
    @Published var prompt: String = "Loading…"
    @Published var info: String?
    @Published var progress: (current: Int, total: Int)?
    @Published var lastVerdict: VerdictBadge?
    @Published var answer: String = ""
    @Published var finished = false
    @Published var reviewedCount = 0
    @Published var isRecording = false
    @Published var micDenied = false
    @Published var choices: [ChoiceOption] = []

    struct VerdictBadge: Equatable {
        var grade: ReviewGrade
        var diff: String?
    }

    private let runner: SessionRunner
    private var consumeTask: Task<Void, Never>?
    #if os(iOS)
    private let recorder = AudioRecorder()
    #endif

    init(runner: SessionRunner) {
        self.runner = runner
    }

    /// Toggle mic capture: start on first tap, stop + grade the clip on the second.
    func toggleMic() async {
        #if os(iOS)
        if isRecording {
            isRecording = false
            if let clip = recorder.stop() {
                await runner.handle(.speech(clip))
            }
        } else {
            guard await recorder.requestPermission() else { micDenied = true; return }
            do {
                try recorder.start()
                isRecording = true
            } catch {
                isRecording = false
            }
        }
        #endif
    }

    func start() async {
        let events = runner.events
        consumeTask = Task { [weak self] in
            for await event in events {
                await self?.apply(event)
            }
        }
        await runner.start()
    }

    func submit() async {
        let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        answer = ""
        await runner.handle(.text(text))
    }

    func quit() async {
        await runner.handle(.quit)
    }

    func choose(_ id: String) async {
        choices = []
        await runner.handle(.tap(choiceID: id))
    }

    private func apply(_ event: ModeEvent) async {
        switch event {
        case .prompt(let text, _):
            prompt = text
            choices = []
            lastVerdict = nil
        case .choices(let text, _, let options):
            prompt = text
            choices = options
            lastVerdict = nil
        case .info(let text):
            info = text
        case .progress(let current, let total):
            progress = (current, total)
        case .goalProgress, .card:
            break   // roleplay HUD only; drills don't emit this
        case .verdict(_, let grade, let diff):
            lastVerdict = VerdictBadge(grade: grade, diff: diff)
            reviewedCount += 1
        case .heard:
            break
        case .finished:
            _ = await runner.finish()   // commit grades/errors to the learner model
            finished = true
            consumeTask?.cancel()
        }
    }
}

struct DrillView: View {
    @StateObject private var model: DrillViewModel
    @Environment(\.dismiss) private var dismiss

    init(runner: SessionRunner) {
        _model = StateObject(wrappedValue: DrillViewModel(runner: runner))
    }

    var body: some View {
        VStack(spacing: 20) {
            if let progress = model.progress {
                ProgressView(value: Double(progress.current), total: Double(progress.total))
                    .padding(.horizontal)
                Text("\(progress.current) / \(progress.total)")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Spacer()

            if model.finished {
                finishedView
            } else {
                drillView
            }

            Spacer()
        }
        .padding()
        .navigationTitle("Session")
        .navigationBarTitleDisplayMode(.inline)
        // Always offer a way out — sessions persist per-turn (R12), so leaving
        // mid-session is safe (it's just abandoned) and never loses committed reviews.
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    dismiss()
                } label: {
                    Label("Exit", systemImage: "chevron.left")
                }
            }
        }
        .task { await model.start() }
    }

    private var drillView: some View {
        VStack(spacing: 20) {
            if let info = model.info {
                Text(info)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            PromptCard(title: model.prompt)

            if let verdict = model.lastVerdict {
                VerdictRow(verdict: verdict)
            }

            if !model.choices.isEmpty {
                VStack(spacing: 8) {
                    ForEach(model.choices) { choice in
                        Button {
                            Task { await model.choose(choice.id) }
                        } label: {
                            Text(choice.label)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            } else {
            HStack {
                TextField("Type your answer", text: $model.answer)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .onSubmit { Task { await model.submit() } }
                Button("Check") { Task { await model.submit() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.answer.isEmpty)
            }

            Button {
                Task { await model.toggleMic() }
            } label: {
                Label(model.isRecording ? "Stop & check" : "Speak your answer",
                      systemImage: model.isRecording ? "stop.circle.fill" : "mic.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.bordered)
            .tint(model.isRecording ? .red : .accentColor)

            if model.micDenied {
                Text("Microphone access is off. Enable it in Settings to speak your answers.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            }
        }
    }

    private var finishedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("Session complete")
                .font(.title2).bold()
            Text("Reviewed \(model.reviewedCount) item\(model.reviewedCount == 1 ? "" : "s"). Your schedule just updated.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
    }
}

private struct VerdictRow: View {
    let verdict: DrillViewModel.VerdictBadge

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: verdict.grade == .again ? "xmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(verdict.grade == .again ? .orange : .green)
            VStack(alignment: .leading) {
                Text(label)
                    .font(.subheadline).bold()
                if let diff = verdict.diff {
                    Text(diff).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private var label: String {
        switch verdict.grade {
        case .again: return "Not quite — let's revisit this"
        case .hard: return "Got it (that was tricky)"
        case .good: return "Correct"
        case .easy: return "Easy!"
        }
    }
}
