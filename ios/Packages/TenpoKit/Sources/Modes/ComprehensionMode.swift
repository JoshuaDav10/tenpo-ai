import Foundation
import CoreModels
import ContentKit
import ModeEngine

/// Mode 3 (§4.6, R9): show/hear a Japanese word, answer its meaning in English.
/// Comprehension is tracked as its own dimension — knowing vs. parroting. Matching
/// is English-aware (case/punctuation, leading "to ", any listed gloss).
public struct ComprehensionMode: LearningMode {
    public static let descriptor = ModeDescriptor(
        id: "comprehension.jp_en",
        name: "What does it mean?",
        dimensions: [.recognitionReading],
        needsRealtime: false,
        needsNetwork: false
    )

    let context: ModeContext
    public init(context: ModeContext) { self.context = context }

    public func makeSession(plan: SessionPlan) -> any ModeSession {
        GenericDrillSession(plan: plan, context: context, config: DrillConfig(
            modeID: Self.descriptor.id,
            dimension: .recognitionReading,
            errorCategory: .vocab,
            present: { item, _ in
                let f = VocabFields(item)
                let shown = f.reading.map { "\(f.lemma)（\($0)）" } ?? f.lemma
                return (nil, "What does “\(shown)” mean?")
            },
            acceptedAnswers: { item, _ in VocabFields(item).glosses },
            canonical: { item, _ in VocabFields(item).glosses.first ?? VocabFields(item).lemma },
            textMatches: { answer, glosses, _ in englishAnswerMatches(answer, glosses) },
            retryPrompt: { _, _ in "Type the English meaning." }
        ))
    }
}
