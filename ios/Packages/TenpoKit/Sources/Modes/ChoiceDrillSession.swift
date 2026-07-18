import Foundation
import CoreModels
import ContentKit
import SpeechKit
import ModeEngine
import LanguagePackCore

/// Config for a multiple-choice drill (listening / pick-the-meaning). Distractors
/// are drawn from the other items in the session plan.
public struct ChoiceDrillConfig: Sendable {
    public var modeID: String
    public var dimension: SkillDimension
    public var kinds: Set<ContentKind>
    /// The on-screen prompt (e.g. "What did you hear?").
    public var prompt: @Sendable (ContentItem, any LanguagePack) -> String
    /// If non-nil, this text is spoken via TTS (the listening stimulus).
    public var audioText: @Sendable (ContentItem, any LanguagePack) -> String?
    /// The label shown for an item as a choice (the correct one and the distractors).
    public var label: @Sendable (ContentItem, any LanguagePack) -> String
    public var errorCategory: ErrorCategory

    public init(
        modeID: String, dimension: SkillDimension, kinds: Set<ContentKind> = [.vocab],
        errorCategory: ErrorCategory = .vocab,
        prompt: @escaping @Sendable (ContentItem, any LanguagePack) -> String,
        audioText: @escaping @Sendable (ContentItem, any LanguagePack) -> String? = { _, _ in nil },
        label: @escaping @Sendable (ContentItem, any LanguagePack) -> String
    ) {
        self.modeID = modeID
        self.dimension = dimension
        self.kinds = kinds
        self.errorCategory = errorCategory
        self.prompt = prompt
        self.audioText = audioText
        self.label = label
    }
}

actor ChoiceDrillSession: ModeSession {
    nonisolated let events: AsyncStream<ModeEvent>
    private nonisolated let continuation: AsyncStream<ModeEvent>.Continuation

    private let plan: SessionPlan
    private let context: ModeContext
    private let config: ChoiceDrillConfig
    private let startedAt = Date()

    private var index = 0
    private var reviews: [ReviewEvent] = []
    private var errors: [ErrorEvent] = []

    init(plan: SessionPlan, context: ModeContext, config: ChoiceDrillConfig) {
        self.plan = plan
        self.context = context
        self.config = config
        var cont: AsyncStream<ModeEvent>.Continuation!
        self.events = AsyncStream { cont = $0 }
        self.continuation = cont
    }

    private var items: [ContentItem] { plan.items.filter { config.kinds.contains($0.kind) } }

    func start() async { await present() }

    func handle(_ input: LearnerInput) async {
        guard index < items.count else { return }
        let item = items[index]
        switch input {
        case .tap(let choiceID):
            let correct = choiceID == item.id.rawValue
            let grade: ReviewGrade = correct ? .good : .again
            reviews.append(ReviewEvent(itemID: item.id, dimension: config.dimension, grade: grade,
                                       modeID: config.modeID, sessionID: plan.sessionID))
            if !correct {
                errors.append(ErrorEvent(sessionID: plan.sessionID, itemID: item.id,
                                         category: config.errorCategory, expected: config.label(item, context.pack),
                                         severity: "minor"))
            }
            continuation.yield(.verdict(itemID: item.id, grade: grade,
                                        diff: correct ? nil : "→ \(config.label(item, context.pack))"))
            index += 1
            await present()
        case .quit:
            continuation.yield(.finished); continuation.finish()
        default:
            continuation.yield(.info("Tap an answer."))
        }
    }

    func finish() async -> ModeResult {
        ModeResult(reviews: reviews, errors: errors,
                   status: reviews.isEmpty ? .abandoned : .completed,
                   duration: Date().timeIntervalSince(startedAt))
    }

    private func present() async {
        guard index < items.count else {
            continuation.yield(.finished); continuation.finish(); return
        }
        let item = items[index]
        continuation.yield(.progress(current: index + 1, total: items.count))

        // Build 4 options: the correct item + up to 3 distractors from the plan.
        let distractors = items.filter { $0.id != item.id }.shuffled().prefix(3)
        var options = ([item] + distractors).map {
            ChoiceOption(id: $0.id.rawValue, label: config.label($0, context.pack))
        }
        options.shuffle()

        var audio: AudioClip?
        if let text = config.audioText(item, context.pack) {
            audio = try? await context.speech.synthesize(text, voice: context.pack.ttsVoiceMap[.warmTutor] ?? "default", locale: context.pack.id)
        }
        continuation.yield(.choices(prompt: config.prompt(item, context.pack), audio: audio, options: options))
    }
}
