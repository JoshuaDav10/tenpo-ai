import Testing
import Foundation
import CoreModels
import Persistence
import ContentKit
import SpeechKit
import LearnerModel
import JapanesePack
import SyncKit
@testable import ModeEngine
@testable import Modes

private func vocab(_ id: String, kana: String, gloss: String) -> ContentItem {
    ContentItem(
        id: ItemID(rawValue: "vocab:\(id)"), language: .japanese, kind: .vocab,
        payload: .object(["lemma": .string(id), "kana": .string(kana), "glosses": .array([.string(gloss)])]),
        band: "N5.1"
    )
}

private func makeContext(pack: JapanesePack) -> ModeContext {
    ModeContext(
        learner: MockLearnerModelService(),
        content: LiveContentServiceStub(),
        speech: LiveSpeechService(
            onDeviceSTT: MockSTTProvider(), serverSTT: MockSTTProvider(),
            tts: MockTTSProvider(), pronunciation: MockPronunciationAssessor(), pack: pack
        ),
        pack: pack
    )
}

// Minimal ContentService stand-in (the mode only reads plan.items in this test).
private struct LiveContentServiceStub: ContentService {
    func item(id: ItemID) async throws -> ContentItem? { nil }
    func items(kind: ContentKind, band: String?, limit: Int) async throws -> [ContentItem] { [] }
    func upsert(_ items: [ContentItem]) async throws {}
    func itemCount() async throws -> Int { 0 }
}

@Suite struct VocabIntroSessionTests {
    @Test func correctTextAnswerGradesGoodAndAdvances() async throws {
        let pack = JapanesePack()
        let mode = VocabIntroMode(context: makeContext(pack: pack))
        let plan = SessionPlan(items: [vocab("食べる", kana: "たべる", gloss: "to eat")])
        let session = mode.makeSession(plan: plan)

        await session.start()
        await session.handle(.text("たべる"))       // kana form — accepted via pack equivalence
        let result = await session.finish()

        #expect(result.status == .completed)
        #expect(result.reviews.count == 1)
        #expect(result.reviews.first?.grade == .good)
        #expect(result.reviews.first?.dimension == .productionWritten)
    }

    @Test func wrongAnswerGradesAgainAndEmitsError() async throws {
        let pack = JapanesePack()
        let mode = VocabIntroMode(context: makeContext(pack: pack))
        let plan = SessionPlan(items: [vocab("食べる", kana: "たべる", gloss: "to eat")])
        let session = mode.makeSession(plan: plan)

        await session.start()
        await session.handle(.text("のむ"))
        let result = await session.finish()

        #expect(result.reviews.first?.grade == .again)
        #expect(result.errors.count == 1)
        #expect(result.errors.first?.category == .vocab)
    }
}

@Suite struct SessionRunnerPersistenceTests {
    @Test func runnerPersistsTranscriptAndCommitsReviews() async throws {
        let pack = JapanesePack()
        let db = try DatabaseManager.inMemory()
        let learner = LiveLearnerModelService(db: db)
        let store = LiveSessionStore(db: db)

        // Seed the content_item row so error ingestion / FSRS have a target.
        try await db.write { try ContentItemRecord(vocab("食べる", kana: "たべる", gloss: "to eat")).insert($0) }

        let context = ModeContext(
            learner: learner, content: LiveContentServiceStub(),
            speech: LiveSpeechService(
                onDeviceSTT: MockSTTProvider(), serverSTT: MockSTTProvider(),
                tts: MockTTSProvider(), pronunciation: MockPronunciationAssessor(), pack: pack
            ),
            pack: pack
        )
        let mode = VocabIntroMode(context: context)
        let plan = SessionPlan(items: [vocab("食べる", kana: "たべる", gloss: "to eat")])
        let runner = SessionRunner(mode: mode, plan: plan, store: store, learner: learner, sync: NoopSyncService())

        await runner.start()
        await runner.handle(.text("たべる"))
        let result = await runner.finish()
        #expect(result.status == .completed)

        // R12: the session and its transcript are on disk.
        let sessionCount = try await db.read { try Int.fetchAll($0, sql: "SELECT COUNT(*) FROM session").first ?? 0 }
        #expect(sessionCount == 1)
        let status = try await db.read { try String.fetchOne($0, sql: "SELECT status FROM session") }
        #expect(status == "completed")

        let turns = try await store.transcript(sessionID: plan.sessionID)
        #expect(!turns.isEmpty)

        // The review was committed to the learner model (a review_event row exists).
        let reviewCount = try await db.read { try Int.fetchAll($0, sql: "SELECT COUNT(*) FROM review_event").first ?? 0 }
        #expect(reviewCount == 1)
    }
}
