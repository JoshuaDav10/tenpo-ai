import Foundation
import CoreModels
import ContentKit
import SpeechKit
import ModeEngine
import LanguagePackCore

/// Shared configuration for a present → answer → grade → advance drill (§4.6).
/// The launch drill modes (vocab intro, echo, production, comprehension) differ
/// only in what they show, what they accept, and which dimension they exercise —
/// so they are all thin configs over one `GenericDrillSession`.
public struct DrillConfig: Sendable {
    public var modeID: String
    /// Dimension exercised by a typed answer.
    public var dimension: SkillDimension
    /// Dimension exercised by a spoken answer (defaults to `dimension`).
    public var speechDimension: SkillDimension
    public var isPronunciationGraded: Bool
    /// Only items of these kinds are drilled; others in the plan are skipped.
    public var kinds: Set<ContentKind>
    /// Further narrows which items this mode drills (e.g. only cloze sentences).
    public var itemFilter: @Sendable (ContentItem) -> Bool
    /// What to show: an optional info line + the prompt the learner responds to.
    public var present: @Sendable (ContentItem, any LanguagePack) -> (info: String?, prompt: String)
    /// Accepted answers for matching (JP forms, or English glosses for comprehension).
    public var acceptedAnswers: @Sendable (ContentItem, any LanguagePack) -> [String]
    /// The reference form used for pronunciation assessment + soft-fail diffs.
    public var canonical: @Sendable (ContentItem, any LanguagePack) -> String
    /// How a typed answer is matched. Defaults to the pack's JP-aware matcher;
    /// comprehension overrides this with English matching.
    public var textMatches: @Sendable (String, [String], any LanguagePack) -> Bool
    /// Error category recorded on an Again grade.
    public var errorCategory: ErrorCategory
    /// Re-prompt text on a no-penalty speech retry.
    public var retryPrompt: @Sendable (ContentItem, any LanguagePack) -> String

    public init(
        modeID: String,
        dimension: SkillDimension,
        speechDimension: SkillDimension? = nil,
        isPronunciationGraded: Bool = false,
        kinds: Set<ContentKind> = [.vocab],
        itemFilter: @escaping @Sendable (ContentItem) -> Bool = { _ in true },
        errorCategory: ErrorCategory = .vocab,
        present: @escaping @Sendable (ContentItem, any LanguagePack) -> (info: String?, prompt: String),
        acceptedAnswers: @escaping @Sendable (ContentItem, any LanguagePack) -> [String],
        canonical: @escaping @Sendable (ContentItem, any LanguagePack) -> String,
        textMatches: @escaping @Sendable (String, [String], any LanguagePack) -> Bool = { answer, accepted, pack in
            pack.answersMatch(answer, accepted).isMatch
        },
        retryPrompt: @escaping @Sendable (ContentItem, any LanguagePack) -> String = { _, _ in "Try once more." }
    ) {
        self.modeID = modeID
        self.dimension = dimension
        self.speechDimension = speechDimension ?? dimension
        self.isPronunciationGraded = isPronunciationGraded
        self.kinds = kinds
        self.itemFilter = itemFilter
        self.errorCategory = errorCategory
        self.present = present
        self.acceptedAnswers = acceptedAnswers
        self.canonical = canonical
        self.textMatches = textMatches
        self.retryPrompt = retryPrompt
    }
}

/// English matching for comprehension answers (JP→EN): case/punctuation-insensitive,
/// tolerant of a leading "to " on verbs and of answering with any listed gloss.
public func englishAnswerMatches(_ answer: String, _ glosses: [String]) -> Bool {
    func norm(_ s: String) -> String {
        var t = s.lowercased()
        if t.hasPrefix("to ") { t.removeFirst(3) }
        t = String(t.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == " " })
        return t.trimmingCharacters(in: .whitespaces)
    }
    let a = norm(answer)
    guard !a.isEmpty else { return false }
    return glosses.contains { norm($0) == a }
}

/// The one drill loop all launch drill modes share.
actor GenericDrillSession: ModeSession {
    nonisolated let events: AsyncStream<ModeEvent>
    private nonisolated let continuation: AsyncStream<ModeEvent>.Continuation

    private let plan: SessionPlan
    private let context: ModeContext
    private let config: DrillConfig
    private let startedAt = Date()

    private var index = 0
    private var attempt = 0
    private var reviews: [ReviewEvent] = []
    private var errors: [ErrorEvent] = []

    init(plan: SessionPlan, context: ModeContext, config: DrillConfig) {
        self.plan = plan
        self.context = context
        self.config = config
        var cont: AsyncStream<ModeEvent>.Continuation!
        self.events = AsyncStream { cont = $0 }
        self.continuation = cont
    }

    private var items: [ContentItem] {
        plan.items.filter { config.kinds.contains($0.kind) && config.itemFilter($0) }
    }

    func start() async {
        presentCurrent()
    }

    func handle(_ input: LearnerInput) async {
        guard index < items.count else { return }
        let item = items[index]
        let accepted = config.acceptedAnswers(item, context.pack)

        switch input {
        case .requestHint:
            continuation.yield(.info("Hint: \(config.canonical(item, context.pack))"))

        case .quit:
            continuation.yield(.finished)
            continuation.finish()

        case .text(let answer):
            let ok = config.textMatches(answer, accepted, context.pack)
            let grade: ReviewGrade = ok ? (attempt == 0 ? .good : .hard) : .again
            recordAndAdvance(item: item, dimension: config.dimension, grade: grade,
                             diff: ok ? nil : "\(answer) → \(config.canonical(item, context.pack))")

        case .speech(let clip):
            let gradable = GradableItem(
                itemID: item.id, acceptedAnswers: accepted,
                canonical: config.canonical(item, context.pack),
                isPronunciationGraded: config.isPronunciationGraded,
                dimension: config.speechDimension
            )
            let outcome = try? await context.speech.grade(audio: clip, item: gradable, attempt: attempt, locale: context.pack.id)
            switch outcome {
            case .pass, .softFail:
                if let grade = outcome?.reviewGrade(attempt: attempt) {
                    recordAndAdvance(item: item, dimension: config.speechDimension, grade: grade, diff: Self.diffText(outcome))
                }
            case .retry(let reason):
                attempt += 1
                if case .lowConfidence(let heard) = reason {
                    continuation.yield(.info("I wasn't sure I heard that (\(heard)) — no penalty."))
                }
                continuation.yield(.prompt(text: config.retryPrompt(item, context.pack), audio: nil))
            case .none:
                continuation.yield(.info("Grading hiccup — moving on."))
                recordAndAdvance(item: item, dimension: config.speechDimension, grade: .hard, diff: nil)
            }

        case .tap:
            continuation.yield(.info("Type or speak your answer."))
        }
    }

    func finish() async -> ModeResult {
        ModeResult(
            reviews: reviews, errors: errors,
            status: reviews.isEmpty ? .abandoned : .completed,
            score: nil, duration: Date().timeIntervalSince(startedAt)
        )
    }

    private func recordAndAdvance(item: ContentItem, dimension: SkillDimension, grade: ReviewGrade, diff: String?) {
        reviews.append(ReviewEvent(
            itemID: item.id, dimension: dimension, grade: grade,
            modeID: config.modeID, sessionID: plan.sessionID
        ))
        if grade == .again {
            errors.append(ErrorEvent(
                sessionID: plan.sessionID, itemID: item.id, category: config.errorCategory,
                surface: diff, expected: config.canonical(item, context.pack), severity: "minor"
            ))
        }
        continuation.yield(.verdict(itemID: item.id, grade: grade, diff: diff))
        index += 1
        attempt = 0
        presentCurrent()
    }

    private func presentCurrent() {
        guard index < items.count else {
            continuation.yield(.finished)
            continuation.finish()
            return
        }
        let (info, prompt) = config.present(items[index], context.pack)
        continuation.yield(.progress(current: index + 1, total: items.count))
        if let info { continuation.yield(.info(info)) }
        continuation.yield(.prompt(text: prompt, audio: nil))
    }

    private static func diffText(_ outcome: GradeOutcome?) -> String? {
        if case .softFail(let diff, _)? = outcome { return "\(diff.heard) → \(diff.expected)" }
        return nil
    }
}
