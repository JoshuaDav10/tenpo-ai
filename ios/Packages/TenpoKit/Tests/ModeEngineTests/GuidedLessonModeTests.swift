import Testing
import Foundation
@testable import Modes
@testable import ModeEngine
import CoreModels
import ContentKit
import SpeechKit
import RealtimeKit
import JapanesePack
import LearnerModel

// MARK: - harness

private let fastTiming = LessonTiming(transcriptAfterEndpoint: 0.15, learnerPatience: 0.25)

private func lessonItem(steps: String) throws -> ContentItem {
    let json = """
    { "title": "Test lesson", "band": "N5.1", "topic_en": "test topic",
      "scenario_ref": "scenario:self_intro_v1", "steps": [\(steps)] }
    """
    let payload = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    return ContentItem(id: ItemID(rawValue: "lesson:test"), language: .japanese,
                       kind: .lesson, payload: payload, band: "N5.1")
}

private func scenarioItem() throws -> ContentItem {
    let json = """
    { "id": "scenario:self_intro_v1", "title": "自己紹介", "register": "polite", "band": "N5.1",
      "setting": "Meeting a classmate.", "persona_hint": "friendly classmate",
      "goals": [ { "id": "g1", "required": true, "desc_en": "Give your name", "target_items": ["vocab:私"] } ] }
    """
    let payload = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    return ContentItem(id: ItemID(rawValue: "scenario:self_intro_v1"), language: .japanese,
                       kind: .scenario, payload: payload, band: "N5.1")
}

private struct EmptyLessonContent: ContentService {
    func items(kind: ContentKind, band: String?, limit: Int) async throws -> [ContentItem] { [] }
    func item(id: ItemID) async throws -> ContentItem? { nil }
    func upsert(_ items: [ContentItem]) async throws {}
    func itemCount() async throws -> Int { 0 }
}

private final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [ModeEvent] = []
    var events: [ModeEvent] { lock.lock(); defer { lock.unlock() }; return _events }
    func append(_ e: ModeEvent) { lock.lock(); defer { lock.unlock() }; _events.append(e) }
}

private struct Harness {
    let session: any ModeSession
    let provider: MockRealtimeVoiceProvider
    let audio: VoiceAudioIO
    let box: EventBox
    let learner: MockLearnerModelService

    var wire: MockRealtimeSession { provider.sessions[0] }
    var stepKinds: [String] { wire.sentSteps.map(\.kind) }

    /// AI finishes speaking its current beat.
    func assistantDone(_ text: String? = nil) {
        if let text { wire.emit(.assistantTranscript(text)) }
        wire.emit(.turnEnded(role: .actor))
    }

    func learnerSays(_ text: String) {
        wire.emit(.userSpeechStarted)
        wire.emit(.userSpeechStopped)
        wire.emit(.partialTranscript(role: .learner, text: text))
    }
}

private func makeHarness(steps: String, extraItems: [ContentItem] = [],
                         weakItems: [ContentItem] = []) async throws -> Harness {
    let pack = JapanesePack()
    let learner = MockLearnerModelService()
    learner.weakItemsToReturn = weakItems
    let provider = MockRealtimeVoiceProvider()
    let audio = VoiceAudioIO()
    let context = ModeContext(
        learner: learner, content: EmptyLessonContent(),
        speech: LiveSpeechService(onDeviceSTT: MockSTTProvider(), serverSTT: MockSTTProvider(),
                                  tts: MockTTSProvider(), pronunciation: MockPronunciationAssessor(), pack: pack),
        realtime: provider, pack: pack)
    let mode = GuidedLessonMode(context: context, audio: audio, timing: fastTiming)
    let session = mode.makeSession(plan: SessionPlan(items: try [lessonItem(steps: steps)] + extraItems,
                                                     pipeline: .realtime))
    let box = EventBox()
    Task { for await event in session.events { box.append(event) } }
    await session.start()
    return Harness(session: session, provider: provider, audio: audio, box: box, learner: learner)
}

/// Poll until `condition` holds (the conductor hops queues/Tasks internally).
private func waitUntil(timeout: TimeInterval = 2, _ condition: @escaping () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

private let repeatStep = """
{ "kind": "model_repeat", "target": "はじめまして", "gloss_en": "nice to meet you",
  "accepted": ["はじめまして"], "item_ref": "vocab:私" }
"""

// MARK: - tests

@Suite struct GuidedLessonModeTests {

    @Test func happyPath_stepsFlowInOrderWithGrades() async throws {
        let h = try await makeHarness(steps: """
        { "kind": "explain", "focus_en": "intro" }, \(repeatStep), { "kind": "wrap" }
        """)
        // Step 1: the English opening, marked first.
        #expect(await waitUntil { h.stepKinds == ["lesson.explain"] })
        #expect(h.wire.sentSteps[0].variables["first"] == .bool(true))

        h.assistantDone("Welcome!")
        // Framing beat chains straight into the repeat step; card emitted.
        #expect(await waitUntil { h.stepKinds == ["lesson.explain", "lesson.model_repeat"] })
        #expect(h.box.events.contains { if case .card(let t, _, _) = $0 { return t == "はじめまして" } ; return false })

        h.assistantDone("Say it with me")
        h.learnerSays("はじめまして")
        // Correct → wrap carries the folded acknowledgment + earned praise.
        #expect(await waitUntil { h.stepKinds.last == "lesson.wrap" })
        let wrap = h.wire.sentSteps.last!
        #expect(wrap.variables["transition"] == .string("correct"))
        #expect(wrap.variables["praise_allowed"] == .bool(true))

        h.assistantDone("Bye!")
        #expect(await waitUntil { h.box.events.contains { if case .finished = $0 { return true }; return false } })
        let result = await h.session.finish()
        #expect(result.reviews.contains { $0.itemID.rawValue == "vocab:私" && $0.grade == .good })
        #expect(result.status == .completed)
    }

    @Test func wrongOnce_correctiveRetryCarriesHeard_thenHardPass() async throws {
        let h = try await makeHarness(steps: "\(repeatStep), { \"kind\": \"wrap\" }")
        #expect(await waitUntil { h.stepKinds.count == 1 })
        h.assistantDone()
        h.learnerSays("こんにちは") // wrong phrase entirely
        #expect(await waitUntil { h.stepKinds.last == "lesson.correct_retry" })
        #expect(h.wire.sentSteps.last?.variables["heard"] == .string("こんにちは"))

        h.assistantDone()
        h.learnerSays("はじめまして") // right on retry
        #expect(await waitUntil { h.stepKinds.last == "lesson.wrap" })

        h.assistantDone()
        _ = await waitUntil { h.box.events.contains { if case .finished = $0 { return true }; return false } }
        let result = await h.session.finish()
        #expect(result.reviews.contains { $0.grade == .hard }) // pass-after-retry
    }

    @Test func persistentWrong_neverBlocks_logsAgainAndError() async throws {
        let h = try await makeHarness(steps: "\(repeatStep), { \"kind\": \"wrap\" }")
        #expect(await waitUntil { h.stepKinds.count == 1 })
        h.assistantDone()
        for _ in 0..<3 { // three wrong attempts exhaust the retry budget
            h.learnerSays("ぜんぜんちがう")
            _ = await waitUntil { h.stepKinds.last == "lesson.correct_retry" || h.stepKinds.last == "lesson.wrap" }
            if h.stepKinds.last == "lesson.correct_retry" { h.assistantDone() }
        }
        #expect(await waitUntil { h.stepKinds.last == "lesson.wrap" })
        // Honest wrap: struggled transition, no praise.
        let wrap = h.wire.sentSteps.last!
        #expect(wrap.variables["transition"] == .string("struggled"))
        #expect(wrap.variables["praise_allowed"] == .bool(false))

        h.assistantDone()
        _ = await waitUntil { h.box.events.contains { if case .finished = $0 { return true }; return false } }
        let result = await h.session.finish()
        #expect(result.reviews.contains { $0.grade == .again })
        #expect(result.errors.contains { $0.expected == "はじめまして" })
    }

    @Test func noise_repromptsWithoutGradeOrAdvance() async throws {
        let h = try await makeHarness(steps: "\(repeatStep), { \"kind\": \"wrap\" }")
        #expect(await waitUntil { h.stepKinds.count == 1 })
        h.assistantDone()
        h.learnerSays("ん") // sub-threshold: keyboard-clack territory
        #expect(await waitUntil { h.stepKinds.last == "lesson.reprompt" })
        // No grade was recorded and we are still on the same step.
        #expect(!h.box.events.contains { if case .verdict = $0 { return true }; return false })

        // Silence after the reprompt → patient timeout → another gentle reprompt.
        h.assistantDone()
        #expect(await waitUntil(timeout: 2) { h.stepKinds.filter { $0 == "lesson.reprompt" }.count == 2 })
    }

    @Test func probe_hintOnFirstMiss_errorAfterSecond() async throws {
        let h = try await makeHarness(steps: """
        { "kind": "prompt_response", "question_jp": "お名前は何ですか。",
          "expectation_en": "give a name", "expected_patterns": ["です"],
          "hint_en": "use desu", "item_refs": ["vocab:名前"] }, { "kind": "wrap" }
        """)
        #expect(await waitUntil { h.stepKinds == ["lesson.prompt_response"] })
        h.assistantDone()
        h.learnerSays("わかりません") // no です pattern
        #expect(await waitUntil { h.stepKinds.last == "lesson.hint" })
        #expect(h.wire.sentSteps.last?.variables["hint_en"] == .string("use desu"))

        h.assistantDone()
        h.learnerSays("だめ") // misses again → advance with error
        #expect(await waitUntil { h.stepKinds.last == "lesson.wrap" })
        h.assistantDone()
        _ = await waitUntil { h.box.events.contains { if case .finished = $0 { return true }; return false } }
        let result = await h.session.finish()
        #expect(result.errors.contains { $0.itemID?.rawValue == "vocab:名前" })
    }

    @Test func weakItems_wovenAsExtraRepeats() async throws {
        let weak = ContentItem(
            id: ItemID(rawValue: "vocab:水"), language: .japanese, kind: .vocab,
            payload: .object(["lemma": .string("水"), "kana": .string("みず"),
                              "glosses": .array([.string("water")])]))
        let h = try await makeHarness(steps: """
        { "kind": "explain", "focus_en": "intro" }, { "kind": "wrap" }
        """, weakItems: [weak])
        #expect(await waitUntil { h.stepKinds.count == 1 })
        h.assistantDone()
        // The woven weak-item repeat lands between explain and wrap.
        #expect(await waitUntil { h.stepKinds.last == "lesson.model_repeat" })
        #expect(h.wire.sentSteps.last?.variables["target"] == .string("水"))
    }

    @Test func roleplayAct_turnCapLeadsToWrap() async throws {
        let h = try await makeHarness(steps: """
        { "kind": "mini_roleplay", "turn_cap": 2 }, { "kind": "wrap" }
        """, extraItems: [scenarioItem()])
        #expect(await waitUntil { h.stepKinds == ["lesson.roleplay_open"] })
        #expect(h.wire.sentSteps[0].variables["setting"] == .string("Meeting a classmate."))

        h.assistantDone("こんにちは！")
        h.learnerSays("こんにちは、私はジョシュです")
        #expect(await waitUntil { h.stepKinds.last == "lesson.roleplay_turn" })

        h.assistantDone("そうですか")
        h.learnerSays("よろしくお願いします") // second turn hits the cap
        #expect(await waitUntil { h.stepKinds.last == "lesson.wrap" })
        // Goal HUD flowed from the engine.
        #expect(h.box.events.contains { if case .goalProgress = $0 { return true }; return false })
    }

    @Test func quit_wrapsAndFinishesAbandoned() async throws {
        let h = try await makeHarness(steps: "\(repeatStep), { \"kind\": \"wrap\" }")
        #expect(await waitUntil { h.stepKinds.count == 1 })
        await h.session.handle(.quit)
        #expect(await waitUntil { h.stepKinds.last == "lesson.wrap" })
        #expect(h.wire.sentSteps.last?.variables["praise_allowed"] == .bool(false))
        h.assistantDone()
        _ = await waitUntil { h.box.events.contains { if case .finished = $0 { return true }; return false } }
        let result = await h.session.finish()
        #expect(result.status == .abandoned)
    }

    @Test func proxyRefusal_endsGracefullyWithFallbackNote() async throws {
        let h = try await makeHarness(steps: "\(repeatStep)")
        #expect(await waitUntil { h.stepKinds.count == 1 })
        h.wire.emit(.proxyRefused(code: "cost_cheap_mode", cheapModeFallback: true))
        #expect(await waitUntil { h.box.events.contains { if case .finished = $0 { return true }; return false } })
        #expect(h.box.events.contains { if case .info(let t) = $0 { return t.contains("text mode") }; return false })
    }

    @Test func tapInterrupt_cancelsAndOpensTheFloor() async throws {
        let h = try await makeHarness(steps: "\(repeatStep), { \"kind\": \"wrap\" }")
        #expect(await waitUntil { h.stepKinds.count == 1 })
        // AI mid-beat: give it audio so the loop is in .speaking.
        h.wire.emit(.assistantAudio(AudioBuffer(data: Data([1, 0]), encoding: .pcm16, sampleRate: 24000)))
        await h.session.handle(.tap(choiceID: "interrupt"))
        #expect(await waitUntil { h.wire.interrupted })
        // Learner can now just answer.
        h.learnerSays("はじめまして")
        #expect(await waitUntil { h.stepKinds.last == "lesson.wrap" })
    }

    @Test func typedText_devPath_actsAsTranscript() async throws {
        let h = try await makeHarness(steps: "\(repeatStep), { \"kind\": \"wrap\" }")
        #expect(await waitUntil { h.stepKinds.count == 1 })
        h.assistantDone()
        await h.session.handle(.text("はじめまして"))
        #expect(await waitUntil { h.stepKinds.last == "lesson.wrap" })
    }
}
