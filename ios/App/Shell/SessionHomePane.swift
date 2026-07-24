import SwiftUI
import CoreModels
import ModeEngine
import DesignSystem
import RealtimeKit

/// The heart of the shell: a horizontal carousel of session cards, each one
/// swipe + one tap from speaking. The blob is the shared character across
/// cards and into the session itself.
struct SessionHomePane: View {
    let container: AppContainer

    private enum Launch: Identifiable {
        case lesson(ActiveLesson)
        case roleplay(ActiveVoiceRoleplay)
        case roleplayText(ActiveRoleplay)
        case drill(SessionRunner)

        var id: String {
            switch self {
            case .lesson(let l): return "lesson-\(l.id)"
            case .roleplay(let r): return "voice-\(r.id)"
            case .roleplayText(let r): return "text-\(r.id)"
            case .drill: return "drill"
            }
        }
    }

    @State private var selection = 0
    @State private var lessons: [LessonScript] = []
    @State private var lessonItems: [ContentItem] = []
    @State private var scenarios: [ContentItem] = []
    @State private var dueCount = 0
    @State private var launch: Launch?
    @State private var showScenarioPicker = false
    @State private var policy: CostPolicy = .full

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 70)
            TabView(selection: $selection) {
                ForEach(Array(cards.enumerated()), id: \.offset) { index, card in
                    card.tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            pageDots
                .padding(.top, 6)
            Spacer(minLength: 60)
        }
        .task { await load() }
        .fullScreenCover(item: $launch) { launch in
            NavigationStack { destination(launch) }
        }
        .sheet(isPresented: $showScenarioPicker) {
            NavigationStack { RoleplayListView(container: container) }
        }
    }

    // MARK: - cards

    private var cards: [AnyView] {
        var cards: [AnyView] = []
        for (index, lesson) in lessons.enumerated() {
            cards.append(AnyView(ModeCard(
                mood: .idle,
                palette: TenpoBlob.defaultPalette,
                kicker: lesson.topicEN,
                title: lesson.title,
                detail: nil,
                start: { startLesson(index) }
            )))
        }
        cards.append(AnyView(ModeCard(
            mood: .listening,
            palette: [TenpoBlob.defaultPalette[1], TenpoBlob.defaultPalette[0], TenpoBlob.defaultPalette[2]],
            kicker: "Free conversation",
            title: "Just talk",
            detail: "\(scenarios.count) scenes",
            secondaryLabel: "choose a scene",
            secondaryAction: { showScenarioPicker = true },
            start: startConversation
        )))
        cards.append(AnyView(ModeCard(
            mood: .thinking,
            palette: [TenpoBlob.defaultPalette[2], TenpoBlob.defaultPalette[1], TenpoBlob.defaultPalette[0]],
            kicker: "Review & drills",
            title: dueCount > 0 ? "\(dueCount) due today" : "Daily practice",
            detail: nil,
            start: startDrills
        )))
        return cards
    }

    private var pageDots: some View {
        HStack(spacing: 7) {
            ForEach(0..<max(cards.count, 1), id: \.self) { i in
                Capsule()
                    .fill(i == selection ? Color.primary.opacity(0.7) : Color.primary.opacity(0.18))
                    .frame(width: i == selection ? 18 : 7, height: 7)
                    .animation(.spring(duration: 0.3), value: selection)
            }
        }
    }

    // MARK: - launches

    private func startLesson(_ index: Int) {
        guard policy.allowsNewRoleplay, index < lessonItems.count else { return }
        Task {
            if let made = await container.makeLessonSession(lessonItems[index]) {
                launch = .lesson(ActiveLesson(runner: made.runner, audio: made.audio, lesson: made.lesson))
            }
        }
    }

    private func startConversation() {
        guard policy.allowsNewRoleplay,
              let item = scenarios.first, let scenario = Scenario(item) else { return }
        if policy.roleplayPipeline == .realtime {
            launch = .roleplay(ActiveVoiceRoleplay(item: item, scenario: scenario))
        } else if let made = container.makeRoleplaySession(item, pipeline: .cascade) {
            launch = .roleplayText(ActiveRoleplay(runner: made.runner, scenario: made.scenario))
        }
    }

    private func startDrills() {
        Task {
            if let runner = try? await container.makeDailySession() {
                launch = .drill(runner)
            }
        }
    }

    @ViewBuilder
    private func destination(_ launch: Launch) -> some View {
        switch launch {
        case .lesson(let active):
            LessonSessionView(runner: active.runner, audio: active.audio, lesson: active.lesson, analyzer: container.analyzer)
        case .roleplay(let active):
            VoiceSessionView(realtime: container.realtime, scenario: active.scenario) {
                guard let made = container.makeRoleplaySession(active.item, pipeline: .cascade) else { return nil }
                return ActiveRoleplay(runner: made.runner, scenario: made.scenario)
            }
        case .roleplayText(let active):
            GuidedRoleplayView(runner: active.runner, scenario: active.scenario)
        case .drill(let runner):
            DrillView(runner: runner)
        }
    }

    private func load() async {
        lessonItems = (try? await container.lessons()) ?? []
        lessons = lessonItems.compactMap(LessonScript.init)
        scenarios = (try? await container.scenarios()) ?? []
        dueCount = (try? await container.learner.dueCount(now: Date())) ?? 0
        policy = await container.costPolicy()
    }
}

/// One swipeable session card: character, topic, huge title, Start. Nothing else.
private struct ModeCard: View {
    var mood: TenpoBlob.Mood
    var palette: [Color]
    var kicker: String
    var title: String
    var detail: String?
    var secondaryLabel: String?
    var secondaryAction: (() -> Void)?
    var start: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            TenpoBlob(mood: mood, palette: palette, size: 150)
            Text(kicker)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text(title)
                .font(.system(size: 34, weight: .bold))
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.6)
                .lineLimit(2)
            if let detail {
                Text(detail).font(.caption).foregroundStyle(.tertiary)
            }
            Button(action: start) {
                Text("Start")
                    .font(.headline)
                    .frame(width: 150, height: 52)
                    .background(palette.first ?? .blue, in: Capsule())
                    .foregroundStyle(.white)
            }
            .padding(.top, 10)
            if let secondaryLabel, let secondaryAction {
                Button(secondaryLabel, action: secondaryAction)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 30)
    }
}
