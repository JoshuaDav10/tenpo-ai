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

private func scenarioItem() -> ContentItem {
    ContentItem(
        id: "scenario:pharmacy_headache_v1", language: .japanese, kind: .scenario,
        payload: .object([
            "id": .string("scenario:pharmacy_headache_v1"),
            "title": .string("薬局で"),
            "register": .string("polite"),
            "band": .string("N5.3"),
            "setting": .string("Small pharmacy in Kyoto."),
            "persona_hint": .string("kind pharmacist"),
            "goals": .array([
                .object(["id": .string("g1"), "required": .bool(true), "desc_en": .string("Explain your headache"),
                         "target_items": .array([.string("vocab:頭")])]),
                .object(["id": .string("g2"), "required": .bool(true), "desc_en": .string("Ask for a recommendation"),
                         "target_items": .array([.string("grammar:arimasu")])]),
            ]),
            "seed_weak_items": .bool(true),
        ])
    )
}

private final class ScriptedDirector2: DirectorService, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [DirectorVerdict]
    init(_ v: [DirectorVerdict]) { queue = v }
    func evaluateTurn(_ input: DirectorInput) async throws -> DirectorVerdict {
        synced {
            guard !queue.isEmpty else { return .safeContinue }
            return queue.count == 1 ? queue[0] : queue.removeFirst()
        }
    }
    private func synced<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }
}

private func ctx(director: any DirectorService, actor: any ActorService) -> ModeContext {
    ModeContext(
        learner: MockLearnerModelService(), content: EmptyContent2(),
        speech: LiveSpeechService(onDeviceSTT: MockSTTProvider(), serverSTT: MockSTTProvider(),
                                  tts: MockTTSProvider(), pronunciation: MockPronunciationAssessor(), pack: pack),
        pack: pack, director: director, actor: actor
    )
}

private struct EmptyContent2: ContentService {
    func item(id: ItemID) async throws -> ContentItem? { nil }
    func items(kind: ContentKind, band: String?, limit: Int) async throws -> [ContentItem] { [] }
    func upsert(_ items: [ContentItem]) async throws {}
    func itemCount() async throws -> Int { 0 }
}

private func complete(_ ids: [String], end: Bool = false) -> DirectorVerdict {
    DirectorVerdict(goalUpdates: ids.map { .init(goalID: $0, status: .completed) },
                    sceneControl: end ? .end_scene : .continue)
}

@Suite struct GuidedRoleplaySessionTests {
    @Test func decodesScenarioFromContentItem() throws {
        let scenario = try #require(Scenario(scenarioItem()))
        #expect(scenario.title == "薬局で")
        #expect(scenario.requiredGoalIDs == ["g1", "g2"])
    }

    @Test func emitsOpeningLineAndGoalHUD() async throws {
        let director = ScriptedDirector2([.safeContinue])
        let mode = GuidedRoleplayMode(context: ctx(director: director, actor: EchoActor()))
        let session = mode.makeSession(plan: SessionPlan(items: [scenarioItem()]))

        // start() yields its opening events into the (buffered) stream; read them back.
        await session.start()
        var sawGoalTotal = false
        var sawPrompt = false
        var count = 0
        for await event in session.events {
            if case .goalProgress(_, let total) = event, total == 2 { sawGoalTotal = true }
            if case .prompt = event { sawPrompt = true }
            count += 1
            if count >= 3 { break }
        }
        #expect(sawGoalTotal)
        #expect(sawPrompt)
    }

    @Test func completingGoalsEndsSceneAndProducesReviews() async throws {
        // 3 substantive turns; goals completed on the last (end_scene) → completed.
        let director = ScriptedDirector2([complete(["g1"]), .safeContinue, complete(["g1", "g2"], end: true)])
        let mode = GuidedRoleplayMode(context: ctx(director: director, actor: EchoActor()))
        let session = mode.makeSession(plan: SessionPlan(items: [scenarioItem()]))

        await session.start()
        await session.handle(.text("頭が痛いです"))
        await session.handle(.text("すみません"))
        await session.handle(.text("何かありますか"))
        let result = await session.finish()

        #expect(result.status == .completed)
        #expect(result.reviews.contains { $0.itemID.rawValue == "vocab:頭" })
        #expect(result.score?["praise_allowed"] == .bool(true))
    }

    @Test func seedWeakItemsAreHandedToTheDirector() async throws {
        // Moat loop (§3.2): a seed_weak_items scenario pulls the learner's due items
        // and the engine passes them into every DirectorInput.
        final class SpyDirector: DirectorService, @unchecked Sendable {
            private let box = NSLock()
            private var lastSeed: [ItemID] = []
            func evaluateTurn(_ input: DirectorInput) async throws -> DirectorVerdict {
                synced { lastSeed = input.seedItems }
                return .safeContinue
            }
            func capturedSeed() -> [ItemID] { synced { lastSeed } }
            private func synced<T>(_ body: () -> T) -> T { box.lock(); defer { box.unlock() }; return body() }
        }
        let spy = SpyDirector()
        let learner = MockLearnerModelService()
        learner.weakItemsToReturn = [
            ContentItem(id: "vocab:頭", language: .japanese, kind: .vocab, payload: .object([:]), band: "N5.3")
        ]
        let context = ModeContext(
            learner: learner, content: EmptyContent2(),
            speech: LiveSpeechService(onDeviceSTT: MockSTTProvider(), serverSTT: MockSTTProvider(),
                                      tts: MockTTSProvider(), pronunciation: MockPronunciationAssessor(), pack: pack),
            pack: pack, director: spy, actor: EchoActor()
        )
        let mode = GuidedRoleplayMode(context: context)
        let session = mode.makeSession(plan: SessionPlan(items: [scenarioItem()]))  // scenario has seed_weak_items? see below
        await session.start()
        await session.handle(.text("頭が痛いです"))
        #expect(spy.capturedSeed().contains("vocab:頭"))
    }

    @Test func oneWordSessionIsIncompleteViaTheMode() async throws {
        // R1 end-to-end through the mode: a single turn can't earn a completed status.
        let director = ScriptedDirector2([.safeContinue])
        let mode = GuidedRoleplayMode(context: ctx(director: director, actor: EchoActor()))
        let session = mode.makeSession(plan: SessionPlan(items: [scenarioItem()]))
        await session.start()
        await session.handle(.text("はい"))
        let result = await session.finish()
        #expect(result.status == .incomplete)
        #expect(result.score?["praise_allowed"] == .bool(false))
    }
}
