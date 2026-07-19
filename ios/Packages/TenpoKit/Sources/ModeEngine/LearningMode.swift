import Foundation
import CoreModels
import LearnerModel
import ContentKit
import SpeechKit
import RealtimeKit
import LanguagePackCore

// §4.6 — every learning activity is a plugin. A new mode = one Swift target
// + a registry entry; zero changes to core.

public struct ModeDescriptor: Sendable, Hashable {
    public var id: String
    public var name: String
    public var dimensions: [SkillDimension]
    public var needsRealtime: Bool
    public var needsNetwork: Bool
    public var supportedBands: [String]

    public init(
        id: String, name: String, dimensions: [SkillDimension],
        needsRealtime: Bool = false, needsNetwork: Bool = false, supportedBands: [String] = []
    ) {
        self.id = id
        self.name = name
        self.dimensions = dimensions
        self.needsRealtime = needsRealtime
        self.needsNetwork = needsNetwork
        self.supportedBands = supportedBands
    }
}

/// What the SessionRunner hands a mode: the items to exercise this session.
public struct SessionPlan: Sendable {
    public var sessionID: UUID
    public var items: [ContentItem]
    public var scenarioID: ItemID?
    /// Which pipeline this session runs on (§4.3.1). Defaults to the cheap cascade;
    /// the cost governor sets `.realtime` for full-experience roleplay (R13/§4.3.6).
    public var pipeline: SessionPipeline

    public init(sessionID: UUID = UUID(), items: [ContentItem], scenarioID: ItemID? = nil, pipeline: SessionPipeline = .cascade) {
        self.sessionID = sessionID
        self.items = items
        self.scenarioID = scenarioID
        self.pipeline = pipeline
    }
}

/// Events a mode emits to drive the shared UI shell (grows with the shell in Phase 2).
public struct ChoiceOption: Sendable, Hashable, Identifiable {
    public var id: String
    public var label: String
    public init(id: String, label: String) { self.id = id; self.label = label }
}

public enum ModeEvent: Sendable {
    case prompt(text: String, audio: AudioClip?)
    /// Multiple-choice prompt (listening / pick-the-meaning). Answer via `.tap(choiceID)`.
    case choices(prompt: String, audio: AudioClip?, options: [ChoiceOption])
    case heard(Transcription)
    case verdict(itemID: ItemID, grade: ReviewGrade, diff: String?)
    case progress(current: Int, total: Int)
    /// Roleplay goal HUD: how many required goals the Director has confirmed (R1 —
    /// makes honest scoring visible). Drill modes never emit this.
    case goalProgress(completed: Int, total: Int)
    case info(String)
    /// Study-context card for the current step (lesson target phrase + furigana +
    /// gloss). UI chrome, not a transcript turn — never persisted.
    case card(text: String, reading: String?, gloss: String?)
    case finished
}

public enum LearnerInput: Sendable {
    case speech(AudioClip)
    case text(String)
    case tap(choiceID: String)
    case requestHint
    case quit
}

/// Per-item grades + error events + duration, committed by the SessionRunner.
public struct ModeResult: Sendable {
    public var reviews: [ReviewEvent]
    public var errors: [ErrorEvent]
    public var status: SessionStatus
    public var score: JSONValue?
    public var duration: TimeInterval

    public init(
        reviews: [ReviewEvent] = [], errors: [ErrorEvent] = [],
        status: SessionStatus = .completed, score: JSONValue? = nil, duration: TimeInterval = 0
    ) {
        self.reviews = reviews
        self.errors = errors
        self.status = status
        self.score = score
        self.duration = duration
    }
}

/// Injected services (§4.6). `realtime` is nil when descriptor.needsRealtime == false;
/// `director` is non-nil for roleplay modes only.
public struct ModeContext: Sendable {
    public let learner: any LearnerModelService
    public let content: any ContentService
    public let speech: any SpeechService
    public let realtime: (any RealtimeVoiceService)?
    public let pack: any LanguagePack
    public let director: (any DirectorService)?
    public let actor: (any ActorService)?

    public init(
        learner: any LearnerModelService, content: any ContentService,
        speech: any SpeechService, realtime: (any RealtimeVoiceService)? = nil,
        pack: any LanguagePack, director: (any DirectorService)? = nil,
        actor: (any ActorService)? = nil
    ) {
        self.learner = learner
        self.content = content
        self.speech = speech
        self.realtime = realtime
        self.pack = pack
        self.director = director
        self.actor = actor
    }
}

public protocol LearningMode: Sendable {
    static var descriptor: ModeDescriptor { get }
    init(context: ModeContext)
    func makeSession(plan: SessionPlan) -> any ModeSession
}

public protocol ModeSession: AnyObject, Sendable {
    var events: AsyncStream<ModeEvent> { get }
    func start() async
    func handle(_ input: LearnerInput) async
    func finish() async -> ModeResult
}

// DirectorService (§4.4) is defined in Director.swift.
