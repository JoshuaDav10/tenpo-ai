import Foundation
import CoreModels

/// What the conversation feels like at this instant — drives the session UI orb.
public enum VoiceLoopState: String, Sendable, Equatable {
    /// Mic open, streaming the learner's audio; the AI is quiet.
    case listening
    /// Learner finished (server VAD endpointed); waiting for the AI's reply to start.
    case thinking
    /// AI audio is playing. Learner speech here triggers barge-in.
    case speaking
    /// Session over or failed; no audio flows.
    case ended
}

/// Side effects the controller asks its host (audio engine + UI) to perform.
/// The controller owns *decisions*; the host owns hardware.
public enum VoiceLoopAction: Sendable, Equatable {
    case play(AudioBuffer)
    /// Flush any queued/playing assistant audio immediately (barge-in).
    case stopPlayback
    case state(VoiceLoopState)
    case learnerSaid(String)
    case assistantSaid(String)
    /// Session must fall back to the cheap text cascade (§4.3.6 soft cap).
    case fallbackToCascade
    case failed(String)
}

extension VoiceLoopAction {
    public static func == (lhs: VoiceLoopAction, rhs: VoiceLoopAction) -> Bool {
        switch (lhs, rhs) {
        case (.play(let a), .play(let b)): return a.data == b.data
        case (.stopPlayback, .stopPlayback): return true
        case (.state(let a), .state(let b)): return a == b
        case (.learnerSaid(let a), .learnerSaid(let b)): return a == b
        case (.assistantSaid(let a), .assistantSaid(let b)): return a == b
        case (.fallbackToCascade, .fallbackToCascade): return true
        case (.failed(let a), .failed(let b)): return a == b
        default: return false
        }
    }
}

/// The conversation-loop brain (SESSION_DESIGN.md §1): AI speaks → listens → server
/// VAD endpoints → AI responds — and learner speech during AI playback interrupts it
/// (barge-in). Pure state machine over `RealtimeEvent`s; every decision is a returned
/// `VoiceLoopAction`, so the whole loop is unit-testable with no socket and no mic.
public struct VoiceLoop: Sendable {
    /// Who owns the floor after the AI finishes a turn.
    /// - `conversational`: the learner — mic opens automatically (legacy voice chat).
    /// - `conducted`: the conductor — the floor returns to `.thinking` and the mic
    ///   opens only via `openMic()` when the current lesson step awaits a learner turn.
    public enum Policy: Sendable { case conversational, conducted }

    /// Starts in `.thinking`: the AI opens every session (SESSION_DESIGN Act 1),
    /// so the session begins waiting for the AI's greeting, not for the user.
    public private(set) var state: VoiceLoopState = .thinking
    /// Accumulates assistant transcript deltas for the current turn.
    private var assistantTurnText = ""
    private let policy: Policy

    public init(policy: Policy = .conversational) {
        self.policy = policy
    }

    /// Feed one wire event; get back the actions the host must perform.
    public mutating func handle(_ event: RealtimeEvent) -> [VoiceLoopAction] {
        guard state != .ended else { return [] }
        switch event {
        case .assistantAudio(let buffer):
            // First audio delta of a reply flips thinking → speaking.
            if state != .speaking {
                state = .speaking
                return [.state(.speaking), .play(buffer)]
            }
            return [.play(buffer)]

        case .assistantTranscript(let delta):
            assistantTurnText += delta
            return []

        case .userSpeechStarted:
            // Turn-based by design (Joshua, field test 1): the AI's turn is not
            // voice-interruptible — only an explicit tap (`tapInterrupt`) cuts it
            // off. Mic audio isn't even forwarded outside `.listening`, so this
            // arrives only during the learner's own turn. Nothing to do.
            return []

        case .userSpeechStopped:
            // Server VAD endpointed the learner's utterance — reply is coming.
            if state == .listening {
                state = .thinking
                return [.state(.thinking)]
            }
            return []

        case .partialTranscript(let role, let text):
            return role == .learner ? [.learnerSaid(text)] : []

        case .turnEnded:
            // AI finished its reply. Conversational: floor goes to the learner.
            // Conducted: floor goes back to the conductor (which chains the next
            // step or opens the mic explicitly).
            let said = assistantTurnText
            assistantTurnText = ""
            let next: VoiceLoopState = policy == .conducted ? .thinking : .listening
            state = next
            var actions: [VoiceLoopAction] = []
            if !said.isEmpty { actions.append(.assistantSaid(said)) }
            actions.append(.state(next))
            return actions

        case .proxyRefused(let code, let cheapModeFallback):
            state = .ended
            return cheapModeFallback
                ? [.stopPlayback, .fallbackToCascade, .state(.ended)]
                : [.stopPlayback, .failed(code), .state(.ended)]

        case .error(let message):
            state = .ended
            return [.stopPlayback, .failed(message), .state(.ended)]
        }
    }

    /// Conducted mode: the conductor hands the floor to the learner (the current
    /// step awaits a spoken answer). No-op when already listening or ended.
    public mutating func openMic() -> [VoiceLoopAction] {
        guard state == .thinking || state == .speaking else { return [] }
        state = .listening
        return [.state(.listening)]
    }

    /// The learner taps the orb to cut the AI off and take the floor. The ONLY
    /// interrupt path — voice never barges in.
    public mutating func tapInterrupt() -> [VoiceLoopAction] {
        guard state == .speaking || state == .thinking else { return [] }
        state = .listening
        return [.stopPlayback, .state(.listening)]
    }

    /// Whether learner mic audio should be forwarded to the wire right now.
    /// Only during the learner's turn: streaming while the AI speaks would let
    /// noise interrupt it (and uploads audio nobody wants graded).
    public var shouldForwardMicAudio: Bool { state == .listening }
}

/// Barge-in latency companion (R18): measures learner-stops-talking → first AI audio.
public struct VoiceLatencyMeter: Sendable {
    private var endpointedAt: Date?
    public private(set) var lastVoiceToVoiceMS: Int?
    public private(set) var samples: [Int] = []

    public init() {}

    public mutating func note(_ event: RealtimeEvent, now: Date = Date()) {
        switch event {
        case .userSpeechStopped:
            endpointedAt = now
        case .assistantAudio:
            if let start = endpointedAt {
                let ms = Int((now.timeIntervalSince(start) * 1000).rounded())
                lastVoiceToVoiceMS = ms
                samples.append(ms)
                endpointedAt = nil
            }
        default:
            break
        }
    }

    public var p50MS: Int? {
        guard !samples.isEmpty else { return nil }
        return samples.sorted()[samples.count / 2]
    }
}
