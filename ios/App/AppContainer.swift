import Foundation
import CoreModels
import Persistence
import LearnerModel
import ContentKit
import SpeechKit
import RealtimeKit
import ModeEngine
import Modes
import SyncKit
import JapanesePack
import LanguagePackCore

/// The single DI container (§4.2: no singletons — one AppContainer builds the graph).
/// Phase 0 wires mock providers everywhere network would be needed; live providers
/// replace them per phase (on-device STT in Phase 2, realtime + Director in Phase 3).
@MainActor
final class AppContainer {
    let db: DatabaseManager
    let pack: any LanguagePack
    let content: any ContentService
    let learner: any LearnerModelService
    let speech: any SpeechService
    let realtime: any RealtimeVoiceService
    let chat: any ChatProvider
    let sync: any SyncService
    let store: any SessionStore
    let modeRegistry: ModeRegistry

    init(
        db: DatabaseManager,
        pack: any LanguagePack,
        content: any ContentService,
        learner: any LearnerModelService,
        speech: any SpeechService,
        realtime: any RealtimeVoiceService,
        chat: any ChatProvider,
        sync: any SyncService,
        store: any SessionStore,
        modeRegistry: ModeRegistry
    ) {
        self.db = db
        self.pack = pack
        self.content = content
        self.learner = learner
        self.speech = speech
        self.realtime = realtime
        self.chat = chat
        self.sync = sync
        self.store = store
        self.modeRegistry = modeRegistry
    }

    /// The context handed to non-realtime drill modes (§4.6).
    func drillContext() -> ModeContext {
        ModeContext(learner: learner, content: content, speech: speech, pack: pack)
    }

    /// Build a runner for today's session: pull the daily queue and run VocabIntro
    /// over it. (More modes join the rotation as they land.)
    func makeDailySession(count: Int = 10) async throws -> SessionRunner {
        let items = try await learner.requestItems(count: count, dimension: nil)
        let plan = SessionPlan(items: items)
        let mode = VocabIntroMode(context: drillContext())
        return SessionRunner(mode: mode, plan: plan, store: store, learner: learner, sync: sync)
    }

    private static func registerModes(_ registry: inout ModeRegistry) {
        registry.register(VocabIntroMode.self)
        registry.register(EchoDrillMode.self)
        registry.register(ProductionMode.self)
        registry.register(ComprehensionMode.self)
        registry.register(ClozeMode.self)
    }

    static func live() throws -> AppContainer {
        let db = try DatabaseManager.appDefault()
        let pack = JapanesePack()
        var registry = ModeRegistry()
        registerModes(&registry)
        return AppContainer(
            db: db,
            pack: pack,
            content: LiveContentService(db: db),
            learner: LiveLearnerModelService(db: db),
            // On-device recognizer is real (free, instant, private). Server STT /
            // pronunciation / chat stay mock until the Fly.io proxy is deployed —
            // swap to ProxySTTProvider(config:) etc. once its URL + auth exist.
            speech: LiveSpeechService(
                onDeviceSTT: AppleSpeechRecognizer(),
                serverSTT: MockSTTProvider(),
                tts: MockTTSProvider(),
                pronunciation: MockPronunciationAssessor(),
                pack: pack
            ),
            realtime: MockRealtimeVoiceProvider(),
            chat: MockChatProvider(),
            sync: NoopSyncService(),
            store: LiveSessionStore(db: db),
            modeRegistry: registry
        )
    }

    /// Fully in-memory container for previews and UI tests.
    static func preview() throws -> AppContainer {
        let db = try DatabaseManager.inMemory()
        let pack = JapanesePack()
        var registry = ModeRegistry()
        registerModes(&registry)
        return AppContainer(
            db: db,
            pack: pack,
            content: LiveContentService(db: db),
            learner: LiveLearnerModelService(db: db),
            // On-device recognizer is real (free, instant, private). Server STT /
            // pronunciation / chat stay mock until the Fly.io proxy is deployed —
            // swap to ProxySTTProvider(config:) etc. once its URL + auth exist.
            speech: LiveSpeechService(
                onDeviceSTT: AppleSpeechRecognizer(),
                serverSTT: MockSTTProvider(),
                tts: MockTTSProvider(),
                pronunciation: MockPronunciationAssessor(),
                pack: pack
            ),
            realtime: MockRealtimeVoiceProvider(),
            chat: MockChatProvider(),
            sync: NoopSyncService(),
            store: LiveSessionStore(db: db),
            modeRegistry: registry
        )
    }
}
