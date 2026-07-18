import Testing
import Foundation
import CoreModels
import ContentKit
import SpeechKit
import LearnerModel
import JapanesePack
@testable import ModeEngine
@testable import Modes

private let pack = JapanesePack()

private func ctx() -> ModeContext {
    ModeContext(
        learner: MockLearnerModelService(),
        content: EmptyContent(),
        speech: LiveSpeechService(
            onDeviceSTT: MockSTTProvider(), serverSTT: MockSTTProvider(),
            tts: MockTTSProvider(), pronunciation: MockPronunciationAssessor(), pack: pack
        ),
        pack: pack
    )
}

private struct EmptyContent: ContentService {
    func item(id: ItemID) async throws -> ContentItem? { nil }
    func items(kind: ContentKind, band: String?, limit: Int) async throws -> [ContentItem] { [] }
    func upsert(_ items: [ContentItem]) async throws {}
    func itemCount() async throws -> Int { 0 }
}

private func vocab(_ id: String, kana: String, gloss: String, gloss2: String? = nil) -> ContentItem {
    var glosses: [JSONValue] = [.string(gloss)]
    if let gloss2 { glosses.append(.string(gloss2)) }
    return ContentItem(
        id: ItemID(rawValue: "vocab:\(id)"), language: .japanese, kind: .vocab,
        payload: .object(["lemma": .string(id), "kana": .string(kana), "glosses": .array(glosses)]),
        band: "N5.1"
    )
}

private func cloze(_ id: String, prompt: String, answer: String) -> ContentItem {
    ContentItem(
        id: ItemID(rawValue: "cloze:\(id)"), language: .japanese, kind: .sentence,
        payload: .object(["prompt": .string(prompt), "answer": .string(answer), "hint": .string("particle")]),
        band: "N5.2"
    )
}

@Suite struct ComprehensionModeTests {
    @Test func acceptsEnglishGlossAnyForm() async throws {
        let mode = ComprehensionMode(context: ctx())
        let session = mode.makeSession(plan: SessionPlan(items: [vocab("食べる", kana: "たべる", gloss: "to eat")]))
        await session.start()
        await session.handle(.text("eat"))   // "to eat" gloss, answered without "to"
        let result = await session.finish()
        #expect(result.reviews.first?.grade == .good)
        #expect(result.reviews.first?.dimension == .recognitionReading)
    }

    @Test func wrongMeaningFails() async throws {
        let mode = ComprehensionMode(context: ctx())
        let session = mode.makeSession(plan: SessionPlan(items: [vocab("水", kana: "みず", gloss: "water")]))
        await session.start()
        await session.handle(.text("fire"))
        let result = await session.finish()
        #expect(result.reviews.first?.grade == .again)
    }
}

@Suite struct ProductionModeTests {
    @Test func typedJapaneseProductionGradesWritten() async throws {
        let mode = ProductionMode(context: ctx())
        let session = mode.makeSession(plan: SessionPlan(items: [vocab("水", kana: "みず", gloss: "water")]))
        await session.start()
        await session.handle(.text("みず"))
        let result = await session.finish()
        #expect(result.reviews.first?.grade == .good)
        #expect(result.reviews.first?.dimension == .productionWritten)
    }
}

@Suite struct ClozeModeTests {
    @Test func correctParticleFillPasses() async throws {
        let mode = ClozeMode(context: ctx())
        let session = mode.makeSession(plan: SessionPlan(items: [cloze("gakko", prompt: "がっこう＿いきます。", answer: "に")]))
        await session.start()
        await session.handle(.text("に"))
        let result = await session.finish()
        #expect(result.reviews.first?.grade == .good)
        #expect(result.reviews.first?.dimension == .productionWritten)
    }

    @Test func wrongParticleFailsWithParticleError() async throws {
        let mode = ClozeMode(context: ctx())
        let session = mode.makeSession(plan: SessionPlan(items: [cloze("pan", prompt: "パン＿たべます。", answer: "を")]))
        await session.start()
        await session.handle(.text("は"))
        let result = await session.finish()
        #expect(result.reviews.first?.grade == .again)
        #expect(result.errors.first?.category == .particle)
    }

    @Test func ignoresNonClozeItems() async throws {
        let mode = ClozeMode(context: ctx())
        // A plain vocab item is not a cloze; the mode should drill nothing.
        let session = mode.makeSession(plan: SessionPlan(items: [vocab("水", kana: "みず", gloss: "water")]))
        await session.start()
        let result = await session.finish()
        #expect(result.reviews.isEmpty)
        #expect(result.status == .abandoned)
    }
}

@Suite struct EchoDrillModeTests {
    @Test func spokenRepeatGradesSpokenDimension() async throws {
        // Mock STT returns the hint (accepted answer) at high confidence → pass.
        let mode = EchoDrillMode(context: ctx())
        let session = mode.makeSession(plan: SessionPlan(items: [vocab("水", kana: "みず", gloss: "water")]))
        await session.start()
        await session.handle(.speech(AudioClip(data: Data(count: 16), encoding: .wav, sampleRate: 16000)))
        let result = await session.finish()
        #expect(result.reviews.first?.dimension == .productionSpoken)
        #expect(result.reviews.first?.grade == .good)
    }
}

@Suite struct ListeningPickMeaningTests {
    @Test func tappingCorrectGlossPasses() async throws {
        let mode = ListeningPickMeaningMode(context: ctx())
        let items = [vocab("水", kana: "みず", gloss: "water"),
                     vocab("火", kana: "ひ", gloss: "fire"),
                     vocab("木", kana: "き", gloss: "tree")]
        let session = mode.makeSession(plan: SessionPlan(items: items))
        await session.start()
        await session.handle(.tap(choiceID: "vocab:水"))   // choice id is the item id
        let result = await session.finish()
        #expect(result.reviews.first?.grade == .good)
        #expect(result.reviews.first?.dimension == .recognitionListening)
    }

    @Test func tappingWrongGlossFails() async throws {
        let mode = ListeningPickMeaningMode(context: ctx())
        let items = [vocab("水", kana: "みず", gloss: "water"),
                     vocab("火", kana: "ひ", gloss: "fire")]
        let session = mode.makeSession(plan: SessionPlan(items: items))
        await session.start()
        await session.handle(.tap(choiceID: "vocab:火"))
        let result = await session.finish()
        #expect(result.reviews.first?.grade == .again)
    }
}

@Suite struct RapidFireModeTests {
    @Test func recallingReadingGradesRecognition() async throws {
        let mode = RapidFireMode(context: ctx())
        let session = mode.makeSession(plan: SessionPlan(items: [vocab("水", kana: "みず", gloss: "water")]))
        await session.start()
        await session.handle(.text("みず"))
        let result = await session.finish()
        #expect(result.reviews.first?.grade == .good)
        #expect(result.reviews.first?.dimension == .recognitionReading)
    }
}

@Suite struct VocabIntroParityTests {
    // Guards that the generic-session refactor preserved VocabIntro behavior.
    @Test func correctKanaAnswerStillGradesGoodWritten() async throws {
        let mode = VocabIntroMode(context: ctx())
        let session = mode.makeSession(plan: SessionPlan(items: [vocab("食べる", kana: "たべる", gloss: "to eat")]))
        await session.start()
        await session.handle(.text("たべる"))
        let result = await session.finish()
        #expect(result.reviews.first?.grade == .good)
        #expect(result.reviews.first?.dimension == .productionWritten)
    }
}
