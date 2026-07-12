import Foundation
import CoreModels
import LanguagePackCore

/// What a mode hands the grader: the accepted answers, the canonical form, and
/// whether pronunciation is scored (§4.3.4). Built from a ContentItem by the mode.
public struct GradableItem: Sendable, Hashable {
    public var itemID: ItemID
    /// Any of these count as correct (kana/kanji variants — matched via the pack).
    public var acceptedAnswers: [String]
    /// The single reference form for pronunciation assessment and diffing.
    public var canonical: String
    public var isPronunciationGraded: Bool
    /// Azure overall threshold (0–100) for pronunciation-graded items.
    public var pronThreshold: Double
    /// Which skill dimension this attempt exercises.
    public var dimension: SkillDimension

    public init(
        itemID: ItemID, acceptedAnswers: [String], canonical: String,
        isPronunciationGraded: Bool = false, pronThreshold: Double = 80,
        dimension: SkillDimension = .productionSpoken
    ) {
        self.itemID = itemID
        self.acceptedAnswers = acceptedAnswers
        self.canonical = canonical
        self.isPronunciationGraded = isPronunciationGraded
        self.pronThreshold = pronThreshold
        self.dimension = dimension
    }
}

public enum GradeEvidence: Sendable {
    case transcription(Transcription)
    case pronunciation(PronunciationReport)
}

/// Always renders "I heard: 〜 / expected: 〜" (R5) and offers a reattempt.
public struct GradeDiff: Sendable, Hashable {
    public var heard: String
    public var expected: String
    /// Named phonemes for pronunciation soft-fails (R5).
    public var worstPhonemes: [PronunciationReport.PhonemeScore]

    public init(heard: String, expected: String, worstPhonemes: [PronunciationReport.PhonemeScore] = []) {
        self.heard = heard
        self.expected = expected
        self.worstPhonemes = worstPhonemes
    }
}

public enum RetryReason: Sendable, Hashable {
    /// First-pass ASR confidence was too low to trust either way (R6). No penalty.
    case lowConfidence(heard: String)
}

/// The result of grading one spoken attempt. `opinions` is the number of distinct
/// ASR opinions consulted — the honest-scoring invariant (R6) is that a `.softFail`
/// (the only negative outcome) must carry `opinions >= 2`.
public enum GradeOutcome: Sendable {
    case pass(evidence: GradeEvidence, opinions: Int)
    case softFail(diff: GradeDiff, opinions: Int)
    case retry(reason: RetryReason)

    /// Mechanical mode-result → FSRS grade mapping (§4.5): PASS first try = Good,
    /// PASS after a retry = Hard, SOFT_FAIL = Again. `.retry` records no grade.
    public func reviewGrade(attempt: Int) -> ReviewGrade? {
        switch self {
        case .pass: return attempt == 0 ? .good : .hard
        case .softFail: return .again
        case .retry: return nil
        }
    }
}

/// Confidence thresholds from §4.3.4. Centralized so they're tunable in one place.
public enum GradingThresholds {
    public static let onDevicePassConfidence = 0.85
    public static let lowConfidenceRetry = 0.60
}

/// Honest dual-threshold grading (§4.3.4, R5/R6), implemented verbatim.
///
/// Invariant enforced by construction: a negative outcome (`.softFail`) is only
/// reachable after both the on-device pass (t1) AND the server pass (t2) have run,
/// so `opinions >= 2` before any fail is recorded to the learner model (R6).
public struct HonestGrader: Sendable {
    let onDeviceSTT: any STTProvider
    let serverSTT: any STTProvider
    let pronunciation: any PronunciationAssessor
    let pack: any LanguagePack

    public init(
        onDeviceSTT: any STTProvider, serverSTT: any STTProvider,
        pronunciation: any PronunciationAssessor, pack: any LanguagePack
    ) {
        self.onDeviceSTT = onDeviceSTT
        self.serverSTT = serverSTT
        self.pronunciation = pronunciation
        self.pack = pack
    }

    /// Grade one attempt. `attempt` is 0 for the first try; the caller re-invokes
    /// with `attempt + 1` and fresh audio when a `.retry` is returned.
    public func grade(audio: AudioClip, item: GradableItem, attempt: Int, locale: LanguageID) async throws -> GradeOutcome {
        // t1 — on-device pass, hints-biased toward the accepted answers (R6).
        let t1 = try await onDeviceSTT.transcribe(audio, locale: locale, hints: item.acceptedAnswers)

        // A single high-confidence match is enough for a PASS (R6 only requires
        // two opinions before a FAIL, never before a pass).
        if t1.confidence >= GradingThresholds.onDevicePassConfidence, matches(t1.text, item) {
            return .pass(evidence: .transcription(t1), opinions: 1)
        }

        // Very low confidence on the first attempt: offer one no-penalty retry
        // BEFORE consulting the cascade or recording anything (R6 ordering).
        if t1.confidence < GradingThresholds.lowConfidenceRetry, attempt == 0 {
            return .retry(reason: .lowConfidence(heard: t1.text))
        }

        // t2 — second distinct ASR opinion (server STT / Deepgram).
        let t2 = try await serverSTT.transcribe(audio, locale: locale, hints: item.acceptedAnswers)
        if matches(t2.text, item) {
            return .pass(evidence: .transcription(t2), opinions: 2)
        }

        // Pronunciation-graded items get phoneme-level truth before any fail (R5/R10).
        if item.isPronunciationGraded {
            let report = try await pronunciation.assess(audio, referenceText: item.canonical, locale: locale)
            if report.overall >= item.pronThreshold {
                return .pass(evidence: .pronunciation(report), opinions: 3)
            }
            let diff = GradeDiff(
                heard: bestAlternative(t2, item: item),
                expected: item.canonical,
                worstPhonemes: report.worstPhonemes()
            )
            return .softFail(diff: diff, opinions: 3)
        }

        // Meaning-graded soft-fail: show heard-vs-expected (R5). Two opinions consulted.
        let diff = GradeDiff(heard: bestAlternative(t2, item: item), expected: item.canonical)
        return .softFail(diff: diff, opinions: 2)
    }

    private func matches(_ heard: String, _ item: GradableItem) -> Bool {
        pack.answersMatch(heard, item.acceptedAnswers).isMatch
    }

    /// The transcription text closest to what we expected, for a legible diff.
    private func bestAlternative(_ t: Transcription, item: GradableItem) -> String {
        let candidates = [t.text] + t.alternatives
        return candidates.first { matches($0, item) } ?? t.text
    }
}
