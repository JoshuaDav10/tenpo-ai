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

/// End-to-end over the REAL integrated stack: seed the actual `tools/seed`
/// curriculum, build the daily queue (Track A), run a VocabIntro session over it
/// (my runner + mode), and confirm the learner model updated (FSRS + mastery).
private func repoSeedDir() -> URL {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<6 { url.deleteLastPathComponent() }
    return url.appendingPathComponent("tools/seed", isDirectory: true)
}

private func seedContent(into content: LiveContentService) async throws -> Int {
    var items: [ContentItem] = []
    for spec in ContentSeed.manifest {
        let url = repoSeedDir().appendingPathComponent("\(spec.resource).json")
        guard let data = try? Data(contentsOf: url) else { continue }
        items += try ContentSeed.items(fromJSONArray: data, spec: spec)
    }
    try await content.upsert(items)
    return items.count
}

@Suite struct DailySessionIntegrationTests {
    @Test func seededQueueRunsASessionAndUpdatesLearnerModel() async throws {
        let pack = JapanesePack()
        let db = try DatabaseManager.inMemory()
        let content = LiveContentService(db: db)
        let learner = LiveLearnerModelService(db: db)
        let store = LiveSessionStore(db: db)

        let seeded = try await seedContent(into: content)
        #expect(seeded > 100)

        // Track A queue builder: a fresh learner gets frequency-ordered new items.
        let queue = try await learner.requestItems(count: 8, dimension: nil)
        #expect(!queue.isEmpty)
        #expect(queue.contains { $0.kind == .vocab })

        // Run the real mode over the real queue via the real runner.
        let context = ModeContext(
            learner: learner, content: content,
            speech: LiveSpeechService(
                onDeviceSTT: MockSTTProvider(), serverSTT: MockSTTProvider(),
                tts: MockTTSProvider(), pronunciation: MockPronunciationAssessor(), pack: pack
            ),
            pack: pack
        )
        let plan = SessionPlan(items: queue)
        let runner = SessionRunner(
            mode: VocabIntroMode(context: context), plan: plan,
            store: store, learner: learner, sync: NoopSyncService()
        )

        await runner.start()
        // Answer the first vocab item correctly using its own kana reading.
        let firstVocab = queue.first { $0.kind == .vocab }!
        let answer = VocabFields(firstVocab).reading ?? VocabFields(firstVocab).lemma
        await runner.handle(.text(answer))
        await runner.handle(.quit)
        let result = await runner.finish()

        #expect(!result.reviews.isEmpty)

        // FSRS state now exists and mastery reflects the reviewed item.
        let tracked = try await learner.trackedItemCount()
        #expect(tracked >= 1)
        let mastery = try await learner.masteryCounts()
        #expect(mastery.total.total >= 1)
    }
}
