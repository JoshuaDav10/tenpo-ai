#if DEBUG
import Foundation
import CoreModels
import RealtimeKit

/// DEBUG-only realtime provider that lets a full lesson RUN on the simulator with
/// no proxy, no auth, no API spend — so session visuals can be verified on every
/// change. It plays the conductor's counterpart: when the client sends a step, it
/// "speaks" (emits a short assistant transcript + turnEnded); the conductor then
/// opens the mic for learner-turn steps, which the DEBUG typed-input path fills.
///
/// Enabled by launching with `TENPO_MOCK_VOICE=1`.
final class DevLessonRealtimeProvider: RealtimeVoiceProvider, RealtimeVoiceService, @unchecked Sendable {
    func openSession(_ config: RealtimeConfig) async throws -> any RealtimeSession {
        DevLessonRealtimeSession()
    }
}

final class DevLessonRealtimeSession: RealtimeSession, @unchecked Sendable {
    let events: AsyncStream<RealtimeEvent>
    private let continuation: AsyncStream<RealtimeEvent>.Continuation

    init() {
        var cont: AsyncStream<RealtimeEvent>.Continuation!
        self.events = AsyncStream { cont = $0 }
        self.continuation = cont
    }

    func send(audio: AudioBuffer) async throws {}
    func send(systemUpdate: String) async throws {}
    func commitInput() async throws {}
    func createResponse() async throws {}
    func interrupt() async throws {}
    func close() async { continuation.finish() }

    private static let autoplay = ProcessInfo.processInfo.environment["TENPO_AUTOPLAY"] == "1"

    /// Each conductor step becomes a short spoken beat, then the floor is handed
    /// back. A tiny delay mimics the AI speaking so the orb visibly cycles. Under
    /// TENPO_AUTOPLAY the learner side is auto-answered too, so a full lesson runs
    /// hands-free (for screenshotting the transcript + completion screens).
    func send(step: LessonStepDirective) async throws {
        let line = Self.spokenLine(for: step)
        continuation.yield(.assistantTranscript(line))
        try? await Task.sleep(nanoseconds: 500_000_000)
        continuation.yield(.turnEnded(role: .actor))

        if Self.autoplay, let answer = Self.autoAnswer(for: step) {
            try? await Task.sleep(nanoseconds: 700_000_000)
            continuation.yield(.userSpeechStarted)
            continuation.yield(.userSpeechStopped)
            continuation.yield(.partialTranscript(role: .learner, text: answer))
        }
    }

    /// A plausible learner answer for autoplay. Repeat steps echo the target (pass);
    /// others give a best guess that may fail — retries are capped, so the lesson
    /// still advances to completion.
    private static func autoAnswer(for step: LessonStepDirective) -> String? {
        func v(_ key: String) -> String? {
            if case .string(let s)? = step.variables[key] { return s }
            return nil
        }
        switch step.kind {
        case "lesson.model_repeat", "lesson.correct_retry", "lesson.reprompt":
            return v("target") ?? "はい"
        case "lesson.prompt_response", "lesson.hint":
            return "私はジョシュです"
        case "lesson.translate_to_jp":
            return "わかりません"
        case "lesson.translate_to_en", "lesson.meaning_retry":
            return "I'm not sure"
        case "lesson.roleplay_open", "lesson.roleplay_turn", "lesson.roleplay_help":
            return "はい、ありがとうございます"
        case "lesson.explain", "lesson.pattern_teach", "lesson.wrap":
            return nil // framing beats — no learner turn
        default:
            return nil
        }
    }

    private static func spokenLine(for step: LessonStepDirective) -> String {
        func v(_ key: String) -> String? {
            if case .string(let s)? = step.variables[key] { return s }
            return nil
        }
        switch step.kind {
        case "lesson.explain":
            return "Hi! Today we'll practice \(v("topic_en") ?? "some Japanese") together."
        case "lesson.model_repeat":
            return "\(v("gloss_en") ?? "This") — say it with me: \(v("target") ?? "")"
        case "lesson.correct_retry":
            return "Almost — I heard “\(v("heard") ?? "")”. Try again: \(v("target") ?? "")"
        case "lesson.reprompt":
            return "Sorry, I didn't catch that — one more time?"
        case "lesson.prompt_response":
            return v("question_jp") ?? "..."
        case "lesson.translate_to_jp":
            return "How would you say “\(v("english_prompt") ?? "")” in Japanese?"
        case "lesson.translate_to_en":
            return "If I said “\(v("phrase_jp") ?? "")” — what does that mean?"
        case "lesson.pattern_teach":
            return "Here's a handy pattern: \(v("rule_en") ?? "")"
        case "lesson.roleplay_open":
            return "Let's try it for real. こんにちは！"
        case "lesson.roleplay_turn", "lesson.roleplay_help":
            return "そうですか。いいですね。"
        case "lesson.wrap":
            return "Nice work today — see you next time!"
        default:
            return "..."
        }
    }
}
#endif
