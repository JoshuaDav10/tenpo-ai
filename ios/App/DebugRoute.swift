#if DEBUG
import SwiftUI
import CoreModels
import ContentKit
import ModeEngine

/// Dev-only deep-route for screenshots/dogfooding. Not compiled into release builds.
/// Launch with e.g. `xcrun simctl launch <dev> <bundle> TENPO_ROUTE dashboard` (env).
struct DebugRoute: View {
    let route: String
    let container: AppContainer
    let compliance: ComplianceStore
    @State private var ready = false
    @State private var drillRunner: SessionRunner?
    @State private var lesson: ActiveLesson?

    var body: some View {
        NavigationStack {
            Group {
                switch route {
                case "roleplay": RoleplayListView(container: container)
                case "settings": SettingsView(container: container, compliance: compliance)
                case "lesson":
                    if let lesson { LessonSessionView(runner: lesson.runner, audio: lesson.audio, lesson: lesson.lesson, analyzer: container.analyzer) }
                    else { ProgressView("Building lesson…") }
                case "transcript":
                    // Renders the tappable transcript with sample lines so the
                    // romaji / kana toggle / tap-to-explain UI is verifiable
                    // without driving a whole session.
                    TranscriptSheet(lines: [
                        .init(isLearner: false, text: "こんにちは。私は先生です。"),
                        .init(isLearner: true, text: "私は水を飲む"),
                        .init(isLearner: false, text: "お名前は何ですか。"),
                        .init(isLearner: true, text: "私はジョシュです"),
                    ], analyzer: container.analyzer)
                case "drill":
                    if let drillRunner { DrillView(runner: drillRunner) }
                    else { ProgressView("Building session…") }
                case "dashboard":
                    if ready { MasteryDashboardView(container: container) }
                    else { ProgressView("Seeding demo data…") }
                default: MasteryDashboardView(container: container)
                }
            }
        }
        .task {
            _ = try? await ContentBootstrap.run(container)
            if route == "dashboard" { await seedDemoReviews() }
            if route == "drill" { drillRunner = try? await container.makeDailySession() }
            if route == "lesson" {
                if let item = (try? await container.lessons())?.first,
                   let made = await container.makeLessonSession(item) {
                    lesson = ActiveLesson(runner: made.runner, audio: made.audio, lesson: made.lesson)
                }
            }
            ready = true
        }
    }

    /// Report a spread of reviews so the mastery/heatmap/forecast tiles have data to show.
    private func seedDemoReviews() async {
        _ = try? await ContentBootstrap.run(container)
        let dims: [SkillDimension] = [.recognitionReading, .recognitionListening, .productionWritten, .productionSpoken]
        let grades: [ReviewGrade] = [.good, .easy, .good, .hard, .again, .good, .easy]
        for kind in [ContentKind.vocab, .grammar, .kanji] {
            let items = (try? await container.content.items(kind: kind, band: nil, limit: 24)) ?? []
            for (i, item) in items.enumerated() {
                let dim = dims[i % dims.count]
                let grade = grades[i % grades.count]
                let event = ReviewEvent(itemID: item.id, dimension: dim, grade: grade,
                                        modeID: "debug", sessionID: nil, latencyMS: 900,
                                        at: Date().addingTimeInterval(-Double(i) * 3600))
                try? await container.learner.report(event)
            }
        }
    }
}
#endif
