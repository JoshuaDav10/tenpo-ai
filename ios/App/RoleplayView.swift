import SwiftUI
import CoreModels
import ModeEngine
import SpeechKit
import RealtimeKit

// MARK: - Scenario picker

struct RoleplayListView: View {
    let container: AppContainer
    @State private var scenarios: [ContentItem] = []
    @State private var lessons: [ContentItem] = []
    @State private var active: ActiveRoleplay?
    @State private var activeVoice: ActiveVoiceRoleplay?
    @State private var activeLesson: ActiveLesson?
    @State private var policy: CostPolicy = .full

    var body: some View {
        List {
            if policy != .full {
                Section { CostNotice(policy: policy) }
            }
            if !lessons.isEmpty {
                Section("Lessons") {
                    ForEach(lessons) { item in
                        if let script = LessonScript(item) {
                            Button {
                                guard policy.allowsNewRoleplay else { return }
                                Task {
                                    // Cheap mode: the lesson's scenario in text cascade.
                                    if policy.roleplayPipeline != .realtime {
                                        if let ref = script.scenarioRef,
                                           let scenarioItem = try? await container.content.item(id: ref),
                                           let made = container.makeRoleplaySession(scenarioItem, pipeline: .cascade) {
                                            active = ActiveRoleplay(runner: made.runner, scenario: made.scenario)
                                        }
                                        return
                                    }
                                    if let made = await container.makeLessonSession(item) {
                                        activeLesson = ActiveLesson(runner: made.runner, audio: made.audio, lesson: made.lesson)
                                    }
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(script.title).font(.headline)
                                        Spacer()
                                        Image(systemName: "waveform.circle.fill")
                                            .foregroundStyle(.tint)
                                    }
                                    Text(script.topicEN).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .disabled(!policy.allowsNewRoleplay)
                        }
                    }
                }
            }
            Section {
                ForEach(scenarios) { item in
                    if let scenario = Scenario(item) {
                        Button {
                            // R13: caps gate STARTING. Past the hard cap, no new roleplay.
                            guard policy.allowsNewRoleplay else { return }
                            // Full budget → the voice loop (Pipeline A). Cheap mode →
                            // the text cascade. §4.3.6; the proxy re-checks on open.
                            if policy.roleplayPipeline == .realtime {
                                activeVoice = ActiveVoiceRoleplay(item: item, scenario: scenario)
                            } else if let made = container.makeRoleplaySession(item, pipeline: .cascade) {
                                active = ActiveRoleplay(runner: made.runner, scenario: made.scenario)
                            }
                        } label: {
                            row(scenario)
                        }
                        .disabled(!policy.allowsNewRoleplay)
                    }
                }
            }
        }
        .navigationTitle("Roleplay")
        .navigationDestination(item: $active) { rp in
            GuidedRoleplayView(runner: rp.runner, scenario: rp.scenario)
        }
        .navigationDestination(item: $activeVoice) { rp in
            VoiceSessionView(realtime: container.realtime, scenario: rp.scenario) {
                // Soft-cap refusal mid-open → same scenario, text pipeline.
                guard let made = container.makeRoleplaySession(rp.item, pipeline: .cascade) else { return nil }
                return ActiveRoleplay(runner: made.runner, scenario: made.scenario)
            }
        }
        .navigationDestination(item: $activeLesson) { lesson in
            LessonSessionView(runner: lesson.runner, audio: lesson.audio, lesson: lesson.lesson)
        }
        .task {
            scenarios = (try? await container.scenarios()) ?? []
            lessons = (try? await container.lessons()) ?? []
            policy = await container.costPolicy()
        }
    }

    private func row(_ scenario: Scenario) -> some View {
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

/// Explains why roleplay is degraded/blocked today (R13/§4.3.6 cost caps). Honest,
/// non-punitive framing per R14.
private struct CostNotice: View {
    let policy: CostPolicy
    var body: some View {
        switch policy {
        case .cheapMode:
            Label("Today's voice budget is used up — roleplays run in text/cheap mode for now. Drills are unaffected.",
                  systemImage: "tortoise")
                .font(.caption).foregroundStyle(.secondary)
        case .drillsOnly:
            Label("Daily spending cap reached — new roleplays are paused until tomorrow. Your drills are always free.",
                  systemImage: "pause.circle")
                .font(.caption).foregroundStyle(.secondary)
        case .full:
            EmptyView()
        }
    }
}

struct ActiveRoleplay: Identifiable, Hashable {
    let id = UUID()
    let runner: SessionRunner
    let scenario: Scenario
    static func == (l: ActiveRoleplay, r: ActiveRoleplay) -> Bool { l.id == r.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

struct ActiveVoiceRoleplay: Identifiable, Hashable {
    let id = UUID()
    let item: ContentItem
    let scenario: Scenario
    static func == (l: ActiveVoiceRoleplay, r: ActiveVoiceRoleplay) -> Bool { l.id == r.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

struct ActiveLesson: Identifiable, Hashable {
    let id = UUID()
    let runner: SessionRunner
    let audio: VoiceAudioIO
    let lesson: LessonScript
    static func == (l: ActiveLesson, r: ActiveLesson) -> Bool { l.id == r.id }
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
    @Published var errors: [ErrorEvent] = []
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
            errors = result.errors // R8: categorized error list for the post-session breakdown
            consume?.cancel()
        case .verdict, .progress, .choices, .card:
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
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { dismiss() } label: {
                    Label("Exit", systemImage: "chevron.left")
                }
            }
        }
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
                    if model.finished && !model.errors.isEmpty {
                        ErrorTaxonomyView(errors: model.errors)
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

/// R8 post-session error taxonomy: the Director's categorized error list, grouped
/// by category (vocab / grammar / particle / pronunciation / register). Each error
/// is a drillable item already enrolled in tomorrow's review (R8 → SRS, R7).
/// Shared by the roleplay and lesson debrief screens.
struct ErrorTaxonomyView: View {
    let errors: [ErrorEvent]

    private var grouped: [(category: ErrorCategory, items: [ErrorEvent])] {
        ErrorCategory.allCases.compactMap { cat in
            let items = errors.filter { $0.category == cat }
            return items.isEmpty ? nil : (cat, items)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What to firm up")
                .font(.headline)
            ForEach(grouped, id: \.category) { group in
                VStack(alignment: .leading, spacing: 6) {
                    Label(group.category.displayName, systemImage: group.category.icon)
                        .font(.subheadline).bold()
                        .foregroundStyle(.secondary)
                    ForEach(group.items, id: \.id) { err in
                        ErrorRow(err: err)
                    }
                }
            }
            Text("These are queued for tomorrow's review.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct ErrorRow: View {
    let err: ErrorEvent
    var body: some View {
        HStack(spacing: 8) {
            if let surface = err.surface, let expected = err.expected {
                Text(surface).strikethrough().foregroundStyle(.red)
                Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                Text(expected).foregroundStyle(.green)
            } else if let surface = err.surface {
                Text(surface)
            } else if let expected = err.expected {
                Text(expected)
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
    }
}

private extension ErrorCategory {
    var displayName: String {
        switch self {
        case .vocab: return "Vocabulary"
        case .grammar: return "Grammar"
        case .particle: return "Particles"
        case .pronunciation: return "Pronunciation"
        case .register: return "Politeness / register"
        case .wordOrder: return "Word order"
        }
    }
    var icon: String {
        switch self {
        case .vocab: return "character.book.closed"
        case .grammar: return "text.badge.checkmark"
        case .particle: return "link"
        case .pronunciation: return "waveform"
        case .register: return "person.2"
        case .wordOrder: return "arrow.left.arrow.right"
        }
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
