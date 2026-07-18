import Foundation
import CoreModels
import ContentKit
import ModeEngine

/// Mode 5 (§4.6): fill the blank — targeted particle/conjugation practice.
/// Word-order and particle errors are checked by structured match, not fuzzy STT
/// (R5). Written production of the specific grammatical form.
public struct ClozeMode: LearningMode {
    public static let descriptor = ModeDescriptor(
        id: "cloze",
        name: "Fill the blank",
        dimensions: [.productionWritten],
        needsRealtime: false,
        needsNetwork: false
    )

    let context: ModeContext
    public init(context: ModeContext) { self.context = context }

    public func makeSession(plan: SessionPlan) -> any ModeSession {
        GenericDrillSession(plan: plan, context: context, config: DrillConfig(
            modeID: Self.descriptor.id,
            dimension: .productionWritten,
            kinds: [.sentence],
            itemFilter: { ClozeFields.isCloze($0) },
            errorCategory: .particle,
            present: { item, _ in
                guard let c = ClozeFields(item) else { return (nil, "…") }
                let info = [c.hint.map { "Hint: \($0)" }, c.english].compactMap { $0 }.joined(separator: " · ")
                return (info.isEmpty ? nil : info, "Fill the blank:  \(c.prompt)")
            },
            acceptedAnswers: { item, _ in ClozeFields(item).map { [$0.answer] } ?? [] },
            canonical: { item, _ in ClozeFields(item)?.answer ?? "" },
            retryPrompt: { _, _ in "Type the missing part." }
        ))
    }
}
