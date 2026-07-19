import Foundation
import CoreModels

/// A guided voice lesson (SESSION_DESIGN.md): an ordered script the conductor
/// (GuidedLessonMode) executes over the realtime channel. Stored as a `lesson`
/// content item; hand-authored first, generatable via content_gen later.
public struct LessonScript: Sendable, Identifiable {
    public var id: String
    public var title: String
    public var band: String
    /// English framing of the topic ("Pretend you're meeting a classmate…").
    public var topicEN: String
    public var scenarioRef: ItemID?
    public var steps: [LessonStep]

    public init(id: String, title: String, band: String, topicEN: String,
                scenarioRef: ItemID? = nil, steps: [LessonStep]) {
        self.id = id
        self.title = title
        self.band = band
        self.topicEN = topicEN
        self.scenarioRef = scenarioRef
        self.steps = steps
    }
}

public enum LessonStep: Sendable {
    public struct Repeat: Sendable {
        public var target: String
        public var reading: String?
        public var glossEN: String
        public var accepted: [String]
        public var pronGraded: Bool
        public var pronThreshold: Double
        public var itemRef: ItemID?

        public init(target: String, reading: String? = nil, glossEN: String,
                    accepted: [String] = [], pronGraded: Bool = false,
                    pronThreshold: Double = 80, itemRef: ItemID? = nil) {
            self.target = target
            self.reading = reading
            self.glossEN = glossEN
            self.accepted = accepted.isEmpty ? [target] : accepted
            self.pronGraded = pronGraded
            self.pronThreshold = pronThreshold
            self.itemRef = itemRef
        }
    }

    public struct Probe: Sendable {
        public var questionJP: String
        public var expectationEN: String?
        /// Substrings any of which mark the answer acceptable (normalized match).
        public var expectedPatterns: [String]
        public var hintEN: String?
        public var itemRefs: [ItemID]

        public init(questionJP: String, expectationEN: String? = nil,
                    expectedPatterns: [String] = [], hintEN: String? = nil,
                    itemRefs: [ItemID] = []) {
            self.questionJP = questionJP
            self.expectationEN = expectationEN
            self.expectedPatterns = expectedPatterns
            self.hintEN = hintEN
            self.itemRefs = itemRefs
        }
    }

    /// Flavor B production probe: "How would you say X?" — answered in Japanese.
    public struct TranslateJP: Sendable {
        public var promptEN: String
        public var accepted: [String]
        public var itemRef: ItemID?

        public init(promptEN: String, accepted: [String], itemRef: ItemID? = nil) {
            self.promptEN = promptEN
            self.accepted = accepted
            self.itemRef = itemRef
        }
    }

    /// Flavor B comprehension probe: "What does Y mean?" — answered in English.
    public struct TranslateEN: Sendable {
        public var phraseJP: String
        public var acceptedEN: [String]
        public var itemRef: ItemID?

        public init(phraseJP: String, acceptedEN: [String], itemRef: ItemID? = nil) {
            self.phraseJP = phraseJP
            self.acceptedEN = acceptedEN
            self.itemRef = itemRef
        }
    }

    case explain(focusEN: String)
    case modelAndRepeat(Repeat)
    case promptResponse(Probe)
    case translateToJP(TranslateJP)
    case translateToEN(TranslateEN)
    case miniRoleplay(turnCap: Int, scenarioRef: ItemID?)
    case wrap
}

// MARK: - decoding (tolerant: unknown step kinds are skipped, not fatal)

extension LessonScript {
    /// Build from a `lesson` content item's payload. nil when the item is not a
    /// lesson or the payload is structurally unusable.
    public init?(_ item: ContentItem) {
        guard item.kind == .lesson,
              let data = try? JSONEncoder().encode(item.payload),
              let raw = try? JSONDecoder().decode(RawLesson.self, from: data),
              let steps = raw.steps
        else { return nil }
        self.init(
            id: item.id.rawValue,
            title: raw.title ?? item.id.rawValue,
            band: raw.band ?? item.band ?? "N5",
            topicEN: raw.topic_en ?? "",
            scenarioRef: raw.scenario_ref.map(ItemID.init(rawValue:)),
            steps: steps.compactMap(LessonStep.init(raw:))
        )
    }
}

private struct RawLesson: Decodable {
    var title: String?
    var band: String?
    var topic_en: String?
    var scenario_ref: String?
    var steps: [RawStep]?
}

private struct RawStep: Decodable {
    var kind: String?
    var focus_en: String?
    var target: String?
    var reading: String?
    var gloss_en: String?
    var accepted: [String]?
    var pron_graded: Bool?
    var pron_threshold: Double?
    var item_ref: String?
    var question_jp: String?
    var expectation_en: String?
    var expected_patterns: [String]?
    var hint_en: String?
    var item_refs: [String]?
    var turn_cap: Int?
    var scenario_ref: String?
    var english_prompt: String?
    var phrase_jp: String?
    var accepted_en: [String]?
}

private extension LessonStep {
    init?(raw: RawStep) {
        switch raw.kind {
        case "explain":
            self = .explain(focusEN: raw.focus_en ?? "")
        case "model_repeat":
            guard let target = raw.target else { return nil }
            self = .modelAndRepeat(Repeat(
                target: target, reading: raw.reading, glossEN: raw.gloss_en ?? "",
                accepted: raw.accepted ?? [], pronGraded: raw.pron_graded ?? false,
                pronThreshold: raw.pron_threshold ?? 80,
                itemRef: raw.item_ref.map(ItemID.init(rawValue:))))
        case "prompt_response":
            guard let question = raw.question_jp else { return nil }
            self = .promptResponse(Probe(
                questionJP: question, expectationEN: raw.expectation_en,
                expectedPatterns: raw.expected_patterns ?? [], hintEN: raw.hint_en,
                itemRefs: (raw.item_refs ?? []).map(ItemID.init(rawValue:))))
        case "translate_to_jp":
            guard let prompt = raw.english_prompt, let accepted = raw.accepted, !accepted.isEmpty else { return nil }
            self = .translateToJP(TranslateJP(
                promptEN: prompt, accepted: accepted,
                itemRef: raw.item_ref.map(ItemID.init(rawValue:))))
        case "translate_to_en":
            guard let phrase = raw.phrase_jp, let accepted = raw.accepted_en, !accepted.isEmpty else { return nil }
            self = .translateToEN(TranslateEN(
                phraseJP: phrase, acceptedEN: accepted,
                itemRef: raw.item_ref.map(ItemID.init(rawValue:))))
        case "mini_roleplay":
            self = .miniRoleplay(turnCap: raw.turn_cap ?? 6,
                                 scenarioRef: raw.scenario_ref.map(ItemID.init(rawValue:)))
        case "wrap":
            self = .wrap
        default:
            return nil // unknown kinds skip — future step types don't break old builds
        }
    }
}
