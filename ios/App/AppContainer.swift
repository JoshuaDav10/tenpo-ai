import Foundation
import GRDB
import CoreModels
import Persistence
import LearnerModel
import ContentKit
import SpeechKit
import RealtimeKit
import ModeEngine
import Modes
import SyncKit
import AuthKit
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
    /// Readings/romaji/word explanations for the transcript (lazily indexes the
    /// curriculum; one instance so its cache is shared across screens).
    private(set) lazy var analyzer = SentenceAnalyzer(content: content, pack: pack)
    /// Proxy cost meter (§4.3.6). nil until the Fly.io proxy URL exists — then the
    /// client reads authoritative server spend instead of the ~$0 local meter.
    let usage: (any UsageSource)?
    /// Sign-in state (AuthKit). nil until TenpoConfig.plist names a Supabase project.
    let auth: AuthManager?

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
        modeRegistry: ModeRegistry,
        usage: (any UsageSource)? = nil,
        auth: AuthManager? = nil
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
        self.usage = usage
        self.auth = auth
    }

    /// The context handed to non-realtime drill modes (§4.6).
    func drillContext() -> ModeContext {
        ModeContext(learner: learner, content: content, speech: speech, pack: pack)
    }

    /// Context for the guided (cheap-mode) roleplay: Director + Actor over `chat`.
    func roleplayContext() -> ModeContext {
        ModeContext(
            learner: learner, content: content, speech: speech, pack: pack,
            director: LiveDirectorService(chat: chat),
            actor: LiveActorService(chat: chat)
        )
    }

    /// Consecutive days (ending today or yesterday) with at least one session.
    func streakDays() async -> Int {
        let days: [String] = (try? await db.read { database in
            try String.fetchAll(database,
                sql: "SELECT DISTINCT date(started_at) FROM session ORDER BY 1 DESC LIMIT 366")
        }) ?? []
        guard !days.isEmpty else { return 0 }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        let calendar = Calendar.current
        var cursor = calendar.startOfDay(for: Date())
        var streak = 0
        var index = 0
        // A streak survives if today has no session YET but yesterday did.
        if days.first != formatter.string(from: cursor) {
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor)!
        }
        while index < days.count, days[index] == formatter.string(from: cursor) {
            streak += 1
            index += 1
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor)!
        }
        return streak
    }

    /// Sum of session cost recorded today (dogfood cost meter, §4.3.6). Local
    /// sessions cost $0; this populates once the proxy records per-session cost.
    func todaySpendUSD() async -> Double {
        let startOfDay = Calendar.current.startOfDay(for: Date())
        let value = try? await db.read { database in
            try Double.fetchOne(database,
                sql: "SELECT COALESCE(SUM(cost_usd), 0) FROM session WHERE started_at >= ?",
                arguments: [startOfDay])
        }
        return (value ?? 0) ?? 0
    }

    /// Resolve today's cost policy (§4.3.6, R13): reads metered spend + the manual
    /// cheap-mode toggle and decides whether realtime voice / new roleplays may start.
    /// The proxy's meter is the source of truth (it owns the price table); the local
    /// meter is only a fallback when the proxy is unconfigured/offline.
    func costPolicy() async -> CostPolicy {
        let gov = CostGovernor(caps: .dogfoodDefault, forceCheapMode: Preferences.forceCheapMode)
        if let usage, let server = await usage.todayUsage() {
            return gov.policy(serverUsage: server)
        }
        return gov.policy(todaySpendUSD: await todaySpendUSD())
    }

    /// Spend to show on the dashboard: the proxy's authoritative figure when available,
    /// else the local sum (≈ $0 for on-device work).
    func displaySpendUSD() async -> Double {
        if let usage, let server = await usage.todayUsage() { return server.spentUSD }
        return await todaySpendUSD()
    }

    /// All roleplay scenarios in the content store.
    func scenarios() async throws -> [ContentItem] {
        try await content.items(kind: .scenario, band: nil, limit: 100)
    }

    /// All guided voice lessons in the content store.
    func lessons() async throws -> [ContentItem] {
        try await content.items(kind: .lesson, band: nil, limit: 100)
    }

    /// A conducted voice lesson (SESSION_DESIGN.md): runner + the audio pipe the
    /// view drives hardware through. Runs the full four acts through SessionRunner
    /// (persistence R12, SRS commits R8).
    func makeLessonSession(_ lessonItem: ContentItem) async -> (runner: SessionRunner, audio: VoiceAudioIO, lesson: LessonScript)? {
        guard let script = LessonScript(lessonItem) else { return nil }
        var items = [lessonItem]
        if let ref = script.scenarioRef, let scenario = try? await content.item(id: ref) {
            items.append(scenario)
        }
        let audio = VoiceAudioIO()
        let plan = SessionPlan(items: items, scenarioID: script.scenarioRef, pipeline: .realtime)
        // Name the tutor can use — from the signed-in account's email local part,
        // capitalized (joshua.david10x@… → "Joshua"). nil when signed out.
        let name = await auth?.email
            .flatMap { $0.split(separator: "@").first.map(String.init) }
            .flatMap { $0.split(whereSeparator: { !$0.isLetter }).first.map(String.init) }
            .map(\.capitalized)
        let mode = GuidedLessonMode(
            context: ModeContext(
                learner: learner, content: content, speech: speech, realtime: realtime,
                pack: pack, director: LiveDirectorService(chat: chat)),
            audio: audio, learnerName: name)
        let runner = SessionRunner(mode: mode, plan: plan, store: store, learner: learner, sync: sync)
        return (runner, audio, script)
    }

    /// A runner for a specific scenario. Returns the decoded Scenario for the HUD.
    /// `pipeline` (from `costPolicy()`) picks realtime vs. cascade; today the app
    /// only ships the cascade GuidedRoleplayMode, so both currently run cheap-mode,
    /// but the pipeline is recorded on the session for the cost meter and R13.
    func makeRoleplaySession(_ item: ContentItem, pipeline: SessionPipeline = .cascade) -> (runner: SessionRunner, scenario: Scenario)? {
        guard let scenario = Scenario(item) else { return nil }
        let plan = SessionPlan(items: [item], scenarioID: item.id, pipeline: pipeline)
        let mode = GuidedRoleplayMode(context: roleplayContext(), persona: Preferences.persona)
        let runner = SessionRunner(mode: mode, plan: plan, store: store, learner: learner, sync: sync)
        return (runner, scenario)
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
        registry.register(ListeningPickMeaningMode.self)
        registry.register(RapidFireMode.self)
        registry.register(GuidedRoleplayMode.self)
        registry.register(GuidedLessonMode.self)
    }

    static func live() throws -> AppContainer {
        let db = try DatabaseManager.appDefault()
        let pack = JapanesePack()
        var registry = ModeRegistry()
        registerModes(&registry)

        // Deployment endpoints from TenpoConfig.plist. Anything blank keeps its
        // mock so the app boots and works local-first at every stage of setup.
        let config = TenpoConfig.load()
        let auth = config.authConfig.map {
            AuthManager(client: SupabaseAuthClient(config: $0), store: KeychainSessionStore())
        }
        let token: @Sendable () async -> String? = { [auth] in await auth?.validAccessToken() }
        let proxy = config.proxyConfig(authToken: token)

        let realtime: any RealtimeVoiceService
        #if DEBUG
        let mockVoice = ProcessInfo.processInfo.environment["TENPO_MOCK_VOICE"] == "1"
        #else
        let mockVoice = false
        #endif
        if mockVoice {
            #if DEBUG
            realtime = DevLessonRealtimeProvider() // simulator: run lessons w/o proxy/auth
            #else
            realtime = MockRealtimeVoiceProvider()
            #endif
        } else if let realtimeConfig = config.realtimeConfig(authToken: token) {
            realtime = ProxyRealtimeVoiceProvider(config: realtimeConfig)
        } else {
            realtime = MockRealtimeVoiceProvider()
        }
        let chat: any ChatProvider = proxy.map { ProxyChatProvider(config: $0) } ?? MockChatProvider()
        let sync: any SyncService = auth.map { DynamicSyncService(db: db, config: config, auth: $0) } ?? NoopSyncService()

        return AppContainer(
            db: db,
            pack: pack,
            content: LiveContentService(db: db),
            learner: LiveLearnerModelService(db: db),
            // On-device recognizer is always real (free, instant, private); the
            // server legs go live once the proxy URL is configured.
            speech: LiveSpeechService(
                onDeviceSTT: AppleSpeechRecognizer(),
                serverSTT: proxy.map { ProxySTTProvider(config: $0) } ?? MockSTTProvider(),
                tts: proxy.map { ProxyTTSProvider(config: $0) } ?? MockTTSProvider(),
                pronunciation: proxy.map { ProxyPronunciationAssessor(config: $0) } ?? MockPronunciationAssessor(),
                pack: pack
            ),
            realtime: realtime,
            chat: chat,
            sync: sync,
            store: LiveSessionStore(db: db),
            modeRegistry: registry,
            usage: proxy.map { ProxyUsageService(config: $0) },
            auth: auth
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
