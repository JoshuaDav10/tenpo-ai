import Testing
import Foundation
import CoreModels
import JapanesePack
@testable import SpeechKit

// The honest-grading acceptance tests (§4.3.4, R5/R6). These are the tests the
// spec calls out: a deliberate wrong answer soft-fails with a diff; a fail is
// never recorded on a single ASR opinion.

private let pack = JapanesePack()
private let clip = AudioClip(data: Data(count: 32), encoding: .wav, sampleRate: 16000)
private let ja = LanguageID.japanese

private func stt(_ text: String, _ confidence: Double, alternatives: [String] = []) -> MockSTTProvider {
    MockSTTProvider(results: [Transcription(text: text, confidence: confidence, alternatives: alternatives, provider: "mock")])
}

private func grader(onDevice: MockSTTProvider, server: MockSTTProvider,
                    pron: MockPronunciationAssessor = MockPronunciationAssessor()) -> HonestGrader {
    HonestGrader(onDeviceSTT: onDevice, serverSTT: server, pronunciation: pron, pack: pack)
}

private let taberu = GradableItem(itemID: "vocab:食べる", acceptedAnswers: ["食べる", "たべる"], canonical: "食べる")

@Suite struct HonestGraderPassTests {
    @Test func highConfidenceMatchPassesOnOneOpinion() async throws {
        let g = grader(onDevice: stt("食べる", 0.95), server: stt("SHOULD NOT BE CALLED", 0.9))
        let outcome = try await g.grade(audio: clip, item: taberu, attempt: 0, locale: ja)
        guard case .pass(_, let opinions) = outcome else { return #expect(Bool(false), "expected pass") }
        #expect(opinions == 1)
        #expect(outcome.reviewGrade(attempt: 0) == .good)
    }

    @Test func kanaAnswerIsAcceptedViaPackEquivalence() async throws {
        let g = grader(onDevice: stt("たべる", 0.9), server: stt("x", 0.1))
        let outcome = try await g.grade(audio: clip, item: taberu, attempt: 0, locale: ja)
        guard case .pass = outcome else { return #expect(Bool(false), "kana form should pass") }
    }

    @Test func serverPassAfterLowOnDeviceConfidenceGradesHard() async throws {
        // On-device unsure (0.7, between retry floor and pass floor), server confirms.
        let g = grader(onDevice: stt("たべる?", 0.70), server: stt("食べる", 0.9))
        let outcome = try await g.grade(audio: clip, item: taberu, attempt: 0, locale: ja)
        guard case .pass(_, let opinions) = outcome else { return #expect(Bool(false), "expected pass") }
        #expect(opinions == 2)
        #expect(outcome.reviewGrade(attempt: 0) == .good) // pass on first attempt = Good regardless of opinions
    }
}

@Suite struct HonestGraderFailTests {
    // R6: a fail is only written after ≥2 distinct ASR opinions.
    @Test func softFailCarriesTwoOpinionsAndADiff() async throws {
        let g = grader(onDevice: stt("のむ", 0.70), server: stt("のむ", 0.88))
        let outcome = try await g.grade(audio: clip, item: taberu, attempt: 0, locale: ja)
        guard case .softFail(let diff, let opinions) = outcome else {
            return #expect(Bool(false), "wrong answer should soft-fail")
        }
        #expect(opinions >= 2)                       // the R6 invariant
        #expect(diff.expected == "食べる")
        #expect(outcome.reviewGrade(attempt: 1) == .again)
    }

    @Test func veryLowConfidenceFirstAttemptRetriesWithNoGrade() async throws {
        // R6 ordering: prompt one no-penalty retry before consulting the cascade.
        let server = stt("SHOULD NOT BE CALLED YET", 0.9)
        let g = grader(onDevice: stt("...", 0.30), server: server)
        let outcome = try await g.grade(audio: clip, item: taberu, attempt: 0, locale: ja)
        guard case .retry = outcome else { return #expect(Bool(false), "expected no-penalty retry") }
        #expect(outcome.reviewGrade(attempt: 0) == nil)   // no grade recorded on retry
    }

    @Test func lowConfidenceOnRetryAttemptProceedsToCascade() async throws {
        // On the retry (attempt 1), we do NOT retry again — go through to a verdict.
        let g = grader(onDevice: stt("...", 0.30), server: stt("食べる", 0.9))
        let outcome = try await g.grade(audio: clip, item: taberu, attempt: 1, locale: ja)
        guard case .pass(_, let opinions) = outcome else { return #expect(Bool(false), "should resolve, not retry") }
        #expect(opinions == 2)
    }
}

@Suite struct PronunciationGradingTests {
    private let echo = GradableItem(
        itemID: "vocab:はし", acceptedAnswers: ["はし"], canonical: "はし",
        isPronunciationGraded: true, pronThreshold: 80
    )

    @Test func lowPhonemeScoreSoftFailsWithNamedPhonemes() async throws {
        // Text matches but pronunciation is below threshold → soft-fail names the phoneme (R5/R10).
        let pron = MockPronunciationAssessor(canned: PronunciationReport(
            overall: 55,
            phonemes: [.init(phoneme: "h", score: 40), .init(phoneme: "a", score: 90)],
            provider: "mock"
        ))
        // Force the cascade: on-device below pass floor so we reach the pron step.
        let g = grader(onDevice: stt("はし", 0.70), server: stt("ちがう", 0.9), pron: pron)
        let outcome = try await g.grade(audio: clip, item: echo, attempt: 1, locale: ja)
        guard case .softFail(let diff, let opinions) = outcome else {
            return #expect(Bool(false), "below-threshold pronunciation should soft-fail")
        }
        #expect(opinions == 3)
        #expect(diff.worstPhonemes.first?.phoneme == "h")
    }

    @Test func abovePronThresholdPasses() async throws {
        let pron = MockPronunciationAssessor(canned: PronunciationReport(overall: 92, provider: "mock"))
        let g = grader(onDevice: stt("はし", 0.70), server: stt("ちがう", 0.9), pron: pron)
        let outcome = try await g.grade(audio: clip, item: echo, attempt: 1, locale: ja)
        guard case .pass(.pronunciation, _) = outcome else {
            return #expect(Bool(false), "good pronunciation should pass on phoneme evidence")
        }
    }
}
