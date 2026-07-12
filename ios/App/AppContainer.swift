import Foundation
import CoreModels
import Persistence
import LearnerModel
import ContentKit
import SpeechKit
import RealtimeKit
import ModeEngine
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
        self.modeRegistry = modeRegistry
    }

    static func live() throws -> AppContainer {
        let db = try DatabaseManager.appDefault()
        let pack = JapanesePack()
        let registry = ModeRegistry() // modes register here starting Phase 2
        return AppContainer(
            db: db,
            pack: pack,
            content: LiveContentService(db: db),
            learner: LiveLearnerModelService(db: db),
            speech: LiveSpeechService(
                onDeviceSTT: MockSTTProvider(),
                serverSTT: MockSTTProvider(),
                tts: MockTTSProvider(),
                pronunciation: MockPronunciationAssessor(),
                pack: pack
            ),
            realtime: MockRealtimeVoiceProvider(),
            chat: MockChatProvider(),
            sync: NoopSyncService(),
            modeRegistry: registry
        )
    }

    /// Fully in-memory container for previews and UI tests.
    static func preview() throws -> AppContainer {
        let db = try DatabaseManager.inMemory()
        let pack = JapanesePack()
        return AppContainer(
            db: db,
            pack: pack,
            content: LiveContentService(db: db),
            learner: LiveLearnerModelService(db: db),
            speech: LiveSpeechService(
                onDeviceSTT: MockSTTProvider(),
                serverSTT: MockSTTProvider(),
                tts: MockTTSProvider(),
                pronunciation: MockPronunciationAssessor(),
                pack: pack
            ),
            realtime: MockRealtimeVoiceProvider(),
            chat: MockChatProvider(),
            sync: NoopSyncService(),
            modeRegistry: ModeRegistry()
        )
    }
}
