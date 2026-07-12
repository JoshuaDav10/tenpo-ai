import Foundation
import CoreModels
import ContentKit
import SpeechKit
import ModeEngine

/// Mode 1 (§4.6): introduce a new vocab item, then an immediate retrieval attempt
/// (retrieval practice / testing effect, §3.3). Production is graded via text match
/// or the honest speech grader; comprehension is tracked as a separate dimension.
public struct VocabIntroMode: LearningMode {
    public static let descriptor = ModeDescriptor(
        id: "vocab.intro",
        name: "New words",
        dimensions: [.recognitionReading, .productionWritten, .productionSpoken],
        needsRealtime: false,
        needsNetwork: false
    )

    let context: ModeContext

    public init(context: ModeContext) {
        self.context = context
    }

    public func makeSession(plan: SessionPlan) -> any ModeSession {
        VocabIntroSession(plan: plan, context: context)
    }
}

actor VocabIntroSession: ModeSession {
    nonisolated let events: AsyncStream<ModeEvent>
    private nonisolated let continuation: AsyncStream<ModeEvent>.Continuation

    private let plan: SessionPlan
    private let context: ModeContext
    private let startedAt = Date()

    private var index = 0
    private var attempt = 0
    private var reviews: [ReviewEvent] = []
    private var errors: [ErrorEvent] = []

    init(plan: SessionPlan, context: ModeContext) {
        self.plan = plan
        self.context = context
        var cont: AsyncStream<ModeEvent>.Continuation!
        self.events = AsyncStream { cont = $0 }
        self.continuation = cont
    }

    private var vocabItems: [ContentItem] {
        plan.items.filter { $0.kind == .vocab }
    }

    func start() async {
        presentCurrent()
    }

    func handle(_ input: LearnerInput) async {
        guard index < vocabItems.count else { return }
        let item = vocabItems[index]
        let fields = VocabFields(item)

        switch input {
        case .requestHint:
            continuation.yield(.info("Hint: \(fields.introLine)"))
            return

        case .quit:
            continuation.yield(.finished)
            continuation.finish()
            return

        case .text(let answer):
            let match = context.pack.answersMatch(answer, fields.acceptedAnswers)
            let grade: ReviewGrade = match.isMatch ? (attempt == 0 ? .good : .hard) : .again
            recordAndAdvance(item: item, dimension: .productionWritten, grade: grade,
                             diff: match.isMatch ? nil : "\(answer) → \(fields.lemma)")

        case .speech(let clip):
            let gradable = GradableItem(
                itemID: item.id, acceptedAnswers: fields.acceptedAnswers,
                canonical: fields.lemma, dimension: .productionSpoken
            )
            let outcome = try? await context.speech.grade(audio: clip, item: gradable, attempt: attempt, locale: context.pack.id)
            switch outcome {
            case .pass, .softFail:
                if let grade = outcome?.reviewGrade(attempt: attempt) {
                    let diff = Self.diffText(outcome)
                    recordAndAdvance(item: item, dimension: .productionSpoken, grade: grade, diff: diff)
                }
            case .retry(let reason):
                // No-penalty retry: re-prompt the same item (R6).
                attempt += 1
                if case .lowConfidence(let heard) = reason {
                    continuation.yield(.info("I wasn't sure I heard that — try once more. (heard: \(heard))"))
                }
                continuation.yield(.prompt(text: "Say it again: “\(fields.meaningPrompt)”", audio: nil))
            case .none:
                continuation.yield(.info("Something went wrong grading that — moving on."))
                recordAndAdvance(item: item, dimension: .productionSpoken, grade: .hard, diff: nil)
            }

        case .tap:
            continuation.yield(.info("Tap isn't used in this mode — type or speak your answer."))
        }
    }

    func finish() async -> ModeResult {
        // R1-adjacent honesty: an empty attempt list can't earn a completed status.
        let status: SessionStatus = reviews.isEmpty ? .abandoned : .completed
        return ModeResult(
            reviews: reviews, errors: errors, status: status,
            score: nil, duration: Date().timeIntervalSince(startedAt)
        )
    }

    // MARK: - helpers

    private func recordAndAdvance(item: ContentItem, dimension: SkillDimension, grade: ReviewGrade, diff: String?) {
        reviews.append(ReviewEvent(
            itemID: item.id, dimension: dimension, grade: grade,
            modeID: VocabIntroMode.descriptor.id, sessionID: plan.sessionID
        ))
        if grade == .again {
            errors.append(ErrorEvent(sessionID: plan.sessionID, itemID: item.id, category: .vocab,
                                     surface: diff, expected: VocabFields(item).lemma, severity: "minor"))
        }
        continuation.yield(.verdict(itemID: item.id, grade: grade, diff: diff))
        index += 1
        attempt = 0
        presentCurrent()
    }

    private func presentCurrent() {
        guard index < vocabItems.count else {
            continuation.yield(.finished)
            continuation.finish()
            return
        }
        let fields = VocabFields(vocabItems[index])
        continuation.yield(.progress(current: index + 1, total: vocabItems.count))
        continuation.yield(.info("New word: \(fields.introLine)"))
        continuation.yield(.prompt(text: "How do you say “\(fields.meaningPrompt)” in Japanese?", audio: nil))
    }

    private static func diffText(_ outcome: GradeOutcome?) -> String? {
        if case .softFail(let diff, _)? = outcome { return "\(diff.heard) → \(diff.expected)" }
        return nil
    }
}
