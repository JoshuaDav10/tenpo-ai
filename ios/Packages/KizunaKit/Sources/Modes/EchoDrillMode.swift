import Foundation
import CoreModels
import ContentKit
import ModeEngine

/// Mode 2 (§4.6): pronunciation-graded repeat. Show a word; the learner says it
/// back. Graded on phonemes via the honest cascade (Azure backstop, R5/R10), not
/// on lenient STT. Spoken production only.
public struct EchoDrillMode: LearningMode {
    public static let descriptor = ModeDescriptor(
        id: "drill.echo",
        name: "Say it back",
        dimensions: [.productionSpoken],
        needsRealtime: false,
        needsNetwork: true            // pronunciation grading uses the Azure backstop
    )

    let context: ModeContext
    public init(context: ModeContext) { self.context = context }

    public func makeSession(plan: SessionPlan) -> any ModeSession {
        GenericDrillSession(plan: plan, context: context, config: DrillConfig(
            modeID: Self.descriptor.id,
            dimension: .productionSpoken,
            isPronunciationGraded: true,
            errorCategory: .pronunciation,
            present: { item, _ in
                let f = VocabFields(item)
                return (f.glosses.first.map { "“\($0)”" }, "Say this aloud: \(f.introLine)")
            },
            acceptedAnswers: { item, _ in VocabFields(item).acceptedAnswers },
            canonical: { item, _ in VocabFields(item).reading ?? VocabFields(item).lemma },
            retryPrompt: { item, _ in "Once more: \(VocabFields(item).lemma)" }
        ))
    }
}
