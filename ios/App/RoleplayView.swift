import SwiftUI
import CoreModels
import ModeEngine
import SpeechKit

// MARK: - Scenario picker

struct RoleplayListView: View {
    let container: AppContainer
    @State private var scenarios: [ContentItem] = []
    @State private var active: ActiveRoleplay?

    var body: some View {
        List(scenarios) { item in
            if let scenario = Scenario(item) {
                Button {
                    if let made = container.makeRoleplaySession(item) {
                        active = ActiveRoleplay(runner: made.runner, scenario: made.scenario)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(scenario.title).font(.headline)
                            Spacer()
                            RegisterBadge(register: scenario.register)
                        }
                        Text(scenario.setting).font(.caption).foregroundStyle(.secondary)
                        Text("\(scenario.goals.filter(\.required).count) goals · \(scenario.band)")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .navigationTitle("Roleplay")
        .navigationDestination(item: $active) { rp in
            GuidedRoleplayView(runner: rp.runner, scenario: rp.scenario)
        }
        .task { scenarios = (try? await container.scenarios()) ?? [] }
    }
}

struct ActiveRoleplay: Identifiable, Hashable {
    let id = UUID()
    let runner: SessionRunner
    let scenario: Scenario
    static func == (l: ActiveRoleplay, r: ActiveRoleplay) -> Bool { l.id == r.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

private struct RegisterBadge: View {
    let register: String
    var body: some View {
        Text(register)
            .font(.caption2).bold()
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
    }
}

// MARK: - Roleplay session view

@MainActor
final class RoleplayViewModel: ObservableObject {
    struct Line: Identifiable, Equatable {
        let id = UUID()
        var isLearner: Bool
        var text: String
    }

    @Published var lines: [Line] = []
    @Published var goalsCompleted = 0
    @Published var goalsTotal = 0
    @Published var banner: String?
    @Published var answer = ""
    @Published var finished = false
    @Published var summary: String?
    @Published var isRecording = false

    private let runner: SessionRunner
    private var consume: Task<Void, Never>?
    #if os(iOS)
    private let recorder = AudioRecorder()
    #endif

    init(runner: SessionRunner) { self.runner = runner }

    func start() async {
        let events = runner.events
        consume = Task { [weak self] in
            for await event in events { await self?.apply(event) }
        }
        await runner.start()
    }

    func send() async {
        let t = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        answer = ""
        await runner.handle(.text(t))
    }

    func endScene() async { await runner.handle(.quit) }

    func toggleMic() async {
        #if os(iOS)
        if isRecording {
            isRecording = false
            if let clip = recorder.stop() { await runner.handle(.speech(clip)) }
        } else {
            guard await recorder.requestPermission() else { return }
            try? recorder.start()
            isRecording = true
        }
        #endif
    }

    private func apply(_ event: ModeEvent) async {
        switch event {
        case .prompt(let text, _):
            lines.append(Line(isLearner: false, text: text))
        case .heard(let t):
            lines.append(Line(isLearner: true, text: t.text))
        case .goalProgress(let done, let total):
            goalsCompleted = done; goalsTotal = total
        case .info(let text):
            banner = text
        case .finished:
            let result = await runner.finish()
            finished = true
            summary = Self.summary(for: result)
            consume?.cancel()
        case .verdict, .progress, .choices:
            break
        }
    }

    private static func summary(for result: ModeResult) -> String {
        switch result.status {
        case .completed:
            let praise = result.score?["praise_allowed"] == .bool(true)
            return praise ? "Scene complete — nicely done. Your errors are now in tomorrow's review."
                          : "Scene complete. A few things to firm up — they're queued for review."
        case .incomplete:
            return "That was a short one — not enough to score yet. Try to hit the scene's goals next time."
        case .abandoned:
            return "Scene ended. Your progress is saved."
        }
    }
}

struct GuidedRoleplayView: View {
    let scenario: Scenario
    @StateObject private var model: RoleplayViewModel
    @Environment(\.dismiss) private var dismiss

    init(runner: SessionRunner, scenario: Scenario) {
        self.scenario = scenario
        _model = StateObject(wrappedValue: RoleplayViewModel(runner: runner))
    }

    var body: some View {
        VStack(spacing: 0) {
            goalHUD
            transcript
            if model.finished { finishedBar } else { inputBar }
        }
        .navigationTitle(scenario.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.start() }
    }

    // Honest scoring made visible (R1): the goal counter is the real Director count.
    private var goalHUD: some View {
        VStack(spacing: 6) {
            HStack {
                Label("\(model.goalsCompleted)/\(model.goalsTotal) goals", systemImage: "checkmark.seal")
                    .font(.subheadline).bold()
                Spacer()
                Text(scenario.register).font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(Array(scenario.goals.filter(\.required).enumerated()), id: \.element.id) { idx, goal in
                HStack(spacing: 6) {
                    Image(systemName: idx < model.goalsCompleted ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(idx < model.goalsCompleted ? .green : .secondary)
                    Text(goal.descEN).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
        .padding()
        .background(.thinMaterial)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let banner = model.banner {
                        Text(banner)
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(8)
                            .background(.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                    }
                    ForEach(model.lines) { line in
                        ChatBubble(line: line)
                    }
                    if let summary = model.summary {
                        Text(summary)
                            .font(.callout).bold()
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding()
            }
            .onChange(of: model.lines.count) { _, _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private var inputBar: some View {
        HStack {
            TextField("Your line…", text: $model.answer)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await model.send() } }
            #if os(iOS)
            Button { Task { await model.toggleMic() } } label: {
                Image(systemName: model.isRecording ? "stop.circle.fill" : "mic.fill")
            }
            .tint(model.isRecording ? .red : .accentColor)
            #endif
            Button { Task { await model.send() } } label: { Image(systemName: "paperplane.fill") }
                .disabled(model.answer.isEmpty)
            Menu {
                Button("End scene", role: .destructive) { Task { await model.endScene() } }
            } label: { Image(systemName: "ellipsis.circle") }
        }
        .padding()
        .background(.bar)
    }

    private var finishedBar: some View {
        Button("Done") { dismiss() }
            .buttonStyle(.borderedProminent)
            .padding()
    }
}

private struct ChatBubble: View {
    let line: RoleplayViewModel.Line
    var body: some View {
        HStack {
            if line.isLearner { Spacer(minLength: 40) }
            Text(line.text)
                .padding(10)
                .background(line.isLearner ? Color.accentColor.opacity(0.15) : Color(.secondarySystemBackground),
                            in: RoundedRectangle(cornerRadius: 14))
            if !line.isLearner { Spacer(minLength: 40) }
        }
    }
}
