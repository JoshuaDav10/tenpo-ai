import SwiftUI
import CoreModels
import ModeEngine
import DesignSystem

/// The pane below home: what's ahead — today's queue and the lesson roadmap.
struct PlanPane: View {
    let container: AppContainer

    @State private var dueCount = 0
    @State private var lessons: [LessonScript] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("swipe up to get back")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 74) // full-screen pane: clear the status bar

                Text("My plan")
                    .font(.title2.bold())
                    .padding(.top, 6)

                HStack(spacing: 12) {
                    Image(systemName: "checklist")
                        .font(.title3)
                        .foregroundStyle(TenpoBlob.defaultPalette[0])
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Today")
                            .font(.headline)
                        Text(dueCount > 0
                             ? "\(dueCount) reviews due, then one lesson"
                             : "Nothing due — a lesson and a conversation")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding()
                .background(.white, in: RoundedRectangle(cornerRadius: 16))

                Text("Lesson roadmap")
                    .font(.headline)
                    .padding(.top, 8)

                ForEach(Array(lessons.enumerated()), id: \.element.id) { index, lesson in
                    HStack(spacing: 12) {
                        Text("\(index + 1)")
                            .font(.subheadline.bold().monospacedDigit())
                            .frame(width: 30, height: 30)
                            .background(TenpoBlob.defaultPalette[index % 3].opacity(0.15), in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(lesson.title).font(.subheadline.bold())
                            Text(lesson.topicEN)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Spacer()
                        Text(lesson.band)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding()
                    .background(.white, in: RoundedRectangle(cornerRadius: 16))
                }

                Text("More lessons unlock as the curriculum grows — each one feeds what it hears back into your reviews.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 30)
            }
            .padding(.horizontal, 18)
        }
        .task {
            dueCount = (try? await container.learner.dueCount(now: Date())) ?? 0
            lessons = ((try? await container.lessons()) ?? []).compactMap(LessonScript.init)
        }
    }
}
