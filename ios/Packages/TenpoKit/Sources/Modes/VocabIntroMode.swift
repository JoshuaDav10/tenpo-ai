import Foundation
import CoreModels
import ContentKit
import ModeEngine

/// Mode 1 (§4.6): introduce a new vocab item, then an immediate retrieval attempt
/// (retrieval practice / testing effect, §3.3). Typed answers exercise written
/// production; spoken answers exercise spoken production.
public struct VocabIntroMode: LearningMode {
    public static let descriptor = ModeDescriptor(
        id: "vocab.intro",
        name: "New words",
        dimensions: [.recognitionReading, .productionWritten, .productionSpoken],
        needsRealtime: false,
        needsNetwork: false
    )

    let context: ModeContext
    public init(context: ModeContext) { self.context = context }

    public func makeSession(plan: SessionPlan) -> any ModeSession {
        GenericDrillSession(plan: plan, context: context, config: DrillConfig(
            modeID: Self.descriptor.id,
            dimension: .productionWritten,
            speechDimension: .productionSpoken,
            errorCategory: .vocab,
            present: { item, _ in
                let f = VocabFields(item)
                return ("New word: \(f.introLine)", "How do you say “\(f.meaningPrompt)” in Japanese?")
            },
            acceptedAnswers: { item, _ in VocabFields(item).acceptedAnswers },
            canonical: { item, _ in VocabFields(item).lemma },
            retryPrompt: { item, _ in "Say “\(VocabFields(item).meaningPrompt)” again." }
        ))
    }
}
