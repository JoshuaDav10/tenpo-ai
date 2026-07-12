import Foundation
import CoreModels
import LearnerModel
import SyncKit

/// Owns session lifecycle (§4.6): begins the session row, runs the mode, persists
/// every turn as it happens (R12 crash-safety), then commits the ModeResult to the
/// learner model and triggers sync. One shared implementation for all modes.
///
/// The UI drives the loop: it calls `start()`, forwards `LearnerInput`s via
/// `handle(_:)`, observes `events`, and calls `finish()` when the mode ends.
/// The runner is the single consumer of the mode's raw stream — it persists each
/// turn and re-publishes every event on its own `events` stream for the UI (an
/// AsyncStream is not multicast, so the UI must read the runner's stream, not the
/// mode's).
public actor SessionRunner {
    private let mode: any LearningMode
    private let session: any ModeSession
    private let plan: SessionPlan
    private let store: any SessionStore
    private let learner: any LearnerModelService
    private let sync: any SyncService
    private let modeID: String

    public nonisolated let events: AsyncStream<ModeEvent>
    private nonisolated let continuation: AsyncStream<ModeEvent>.Continuation
    private var pumpTask: Task<Void, Never>?

    public init(
        mode: any LearningMode, plan: SessionPlan,
        store: any SessionStore, learner: any LearnerModelService, sync: any SyncService
    ) {
        self.mode = mode
        self.plan = plan
        self.store = store
        self.learner = learner
        self.sync = sync
        self.modeID = type(of: mode).descriptor.id
        self.session = mode.makeSession(plan: plan)

        var cont: AsyncStream<ModeEvent>.Continuation!
        self.events = AsyncStream { cont = $0 }
        self.continuation = cont
    }

    public func start() async {
        let record = SessionRecord(
            id: plan.sessionID, modeID: modeID, scenarioID: plan.scenarioID,
            startedAt: Date(), pipeline: .cascade
        )
        try? await store.begin(record)

        // Single consumer of the mode's stream: persist turns, re-publish to the UI.
        // All captures are Sendable (stream, store, id, continuation) so the pump
        // runs off an isolation-clean detached task.
        let modeEvents = session.events
        let store = self.store
        let sessionID = plan.sessionID
        let continuation = self.continuation
        pumpTask = Task {
            await Self.pump(events: modeEvents, store: store, sessionID: sessionID, continuation: continuation)
        }
        await session.start()
    }

    public func handle(_ input: LearnerInput) async {
        await session.handle(input)
    }

    /// Finishes the mode, commits grades/errors to the learner model, marks the
    /// session status, and syncs. Returns the result for the UI to render.
    @discardableResult
    public func finish() async -> ModeResult {
        let result = await session.finish()

        for review in result.reviews {
            try? await learner.report(review)
        }
        for error in result.errors {
            try? await learner.report(error)
        }
        try? await store.complete(
            id: plan.sessionID, status: result.status,
            score: result.score, endedAt: Date()
        )
        pumpTask?.cancel()
        // Sync is best-effort and never blocks the user (R12: transcripts don't depend on it).
        Task { [sync] in try? await sync.syncNow() }
        return result
    }

    private static func pump(
        events modeEvents: AsyncStream<ModeEvent>, store: any SessionStore,
        sessionID: UUID, continuation: AsyncStream<ModeEvent>.Continuation
    ) async {
        var seq = 0
        for await event in modeEvents {
            if let turn = turn(from: event) {
                seq += 1
                try? await store.record(TranscriptTurn(
                    sessionID: sessionID, seq: seq, role: turn.role, text: turn.text, at: Date()
                ))
            }
            continuation.yield(event)
        }
        continuation.finish()
    }

    private static func turn(from event: ModeEvent) -> (role: TranscriptRole, text: String)? {
        switch event {
        case .prompt(let text, _): return (.system, text)
        case .heard(let t): return (.learner, t.text)
        case .info(let text): return (.system, text)
        case .verdict, .progress, .finished: return nil
        }
    }
}
