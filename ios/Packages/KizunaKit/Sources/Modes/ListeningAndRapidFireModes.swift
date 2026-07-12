import Foundation
import CoreModels
import ContentKit
import ModeEngine

/// Mode 6 (§4.6, R9): hear a Japanese word, pick its meaning. Listening
/// comprehension as its own tracked dimension — verifying understanding, not
/// parroting. The stimulus is TTS audio; the answer is a tap.
public struct ListeningPickMeaningMode: LearningMode {
    public static let descriptor = ModeDescriptor(
        id: "listening.pick_meaning",
        name: "Listen & choose",
        dimensions: [.recognitionListening],
        needsRealtime: false,
        needsNetwork: true            // TTS stimulus (cached after first generation)
    )

    let context: ModeContext
    public init(context: ModeContext) { self.context = context }

    public func makeSession(plan: SessionPlan) -> any ModeSession {
        ChoiceDrillSession(plan: plan, context: context, config: ChoiceDrillConfig(
            modeID: Self.descriptor.id,
            dimension: .recognitionListening,
            prompt: { _, _ in "What did you hear?" },
            audioText: { item, _ in VocabFields(item).reading ?? VocabFields(item).lemma },
            label: { item, _ in VocabFields(item).glosses.first ?? VocabFields(item).lemma }
        ))
    }
}

/// Mode 7 (§4.6): rapid recognition — see the word, recall its reading fast.
/// Interleaving + retrieval practice (§3.3). Recognition dimension; the timer is a
/// UI affordance layered on top of the same grade loop.
public struct RapidFireMode: LearningMode {
    public static let descriptor = ModeDescriptor(
        id: "rapidfire.reading",
        name: "Rapid fire",
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
                return (f.glosses.first, "Reading of  \(f.lemma)  ?")
            },
            acceptedAnswers: { item, _ in
                let f = VocabFields(item)
                return [f.reading, f.lemma].compactMap { $0 }
            },
            canonical: { item, _ in VocabFields(item).reading ?? VocabFields(item).lemma },
            retryPrompt: { item, _ in "Reading of \(VocabFields(item).lemma)?" }
        ))
    }
}
