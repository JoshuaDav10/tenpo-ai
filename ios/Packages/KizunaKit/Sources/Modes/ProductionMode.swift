import Foundation
import CoreModels
import ContentKit
import ModeEngine

/// Mode 4 (§4.6): English prompt → produce the Japanese. Output hypothesis (Swain,
/// §3.3): production attempts drive acquisition. Typed = written production;
/// spoken = spoken production.
public struct ProductionMode: LearningMode {
    public static let descriptor = ModeDescriptor(
        id: "drill.production",
        name: "Say it in Japanese",
        dimensions: [.productionWritten, .productionSpoken],
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
                return (nil, "In Japanese: “\(f.meaningPrompt)”")
            },
            acceptedAnswers: { item, _ in VocabFields(item).acceptedAnswers },
            canonical: { item, _ in VocabFields(item).lemma },
            retryPrompt: { item, _ in "Say “\(VocabFields(item).meaningPrompt)” again." }
        ))
    }
}
