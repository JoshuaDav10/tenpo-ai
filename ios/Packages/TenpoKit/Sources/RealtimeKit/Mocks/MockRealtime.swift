import Foundation
import CoreModels

/// Scriptable realtime session for tests and Phase 0 boot: events are pushed
/// via `emit(_:)`, sent audio/system updates are recorded.
public final class MockRealtimeSession: RealtimeSession, @unchecked Sendable {
    private let lock = NSLock()
    public let events: AsyncStream<RealtimeEvent>
    private let continuation: AsyncStream<RealtimeEvent>.Continuation

    private var _sentAudio: [AudioBuffer] = []
    private var _systemUpdates: [String] = []
    private var _sentSteps: [LessonStepDirective] = []
    private var _committedInput = 0
    private var _createdResponses = 0
    private var _interrupted = false
    private var _closed = false

    public var sentAudio: [AudioBuffer] { synced { _sentAudio } }
    public var systemUpdates: [String] { synced { _systemUpdates } }
    public var sentSteps: [LessonStepDirective] { synced { _sentSteps } }
    public var committedInput: Int { synced { _committedInput } }
    public var createdResponses: Int { synced { _createdResponses } }
    public var interrupted: Bool { synced { _interrupted } }
    public var closed: Bool { synced { _closed } }

    public init() {
        var continuation: AsyncStream<RealtimeEvent>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    public func emit(_ event: RealtimeEvent) {
        continuation.yield(event)
    }

    public func send(audio: AudioBuffer) async throws {
        synced { _sentAudio.append(audio) }
    }

    public func send(systemUpdate: String) async throws {
        synced { _systemUpdates.append(systemUpdate) }
    }

    public func send(step: LessonStepDirective) async throws {
        synced { _sentSteps.append(step) }
    }

    public func commitInput() async throws {
        synced { _committedInput += 1 }
    }

    public func createResponse() async throws {
        synced { _createdResponses += 1 }
    }

    public func interrupt() async throws {
        synced { _interrupted = true }
    }

    public func close() async {
        synced { _closed = true }
        continuation.finish()
    }

    private func synced<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

public final class MockRealtimeVoiceProvider: RealtimeVoiceProvider, RealtimeVoiceService, @unchecked Sendable {
    private let lock = NSLock()
    private var _openedConfigs: [RealtimeConfig] = []
    private var _sessions: [MockRealtimeSession] = []

    public var openedConfigs: [RealtimeConfig] { synced { _openedConfigs } }
    public var sessions: [MockRealtimeSession] { synced { _sessions } }

    public init() {}

    public func openSession(_ config: RealtimeConfig) async throws -> any RealtimeSession {
        let session = MockRealtimeSession()
        synced {
            _openedConfigs.append(config)
            _sessions.append(session)
        }
        return session
    }

    private func synced<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
