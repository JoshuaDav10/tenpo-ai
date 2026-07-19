import Testing
import Foundation
@testable import ModeEngine
import CoreModels

/// Mirrors the tools/seed/lessons_n5.json wire shape.
private let lessonJSON = """
{
  "id": "lesson:classmate_intro_v1",
  "title": "Meeting a classmate",
  "band": "N5.1",
  "topic_en": "introducing yourself",
  "scenario_ref": "scenario:self_intro_v1",
  "steps": [
    { "kind": "explain", "focus_en": "Today we practice introductions." },
    { "kind": "model_repeat", "target": "はじめまして", "reading": "ha-ji-me-ma-shi-te",
      "gloss_en": "Nice to meet you", "accepted": ["はじめまして"], "pron_graded": true },
    { "kind": "prompt_response", "question_jp": "お名前は何ですか。",
      "expectation_en": "give their name", "expected_patterns": ["です"],
      "hint_en": "私は…です", "item_refs": ["vocab:名前"] },
    { "kind": "hologram_dance", "target": "future step type" },
    { "kind": "mini_roleplay", "turn_cap": 6, "scenario_ref": "scenario:self_intro_v1" },
    { "kind": "wrap" }
  ]
}
"""

private func lessonItem() throws -> ContentItem {
    let payload = try JSONDecoder().decode(JSONValue.self, from: Data(lessonJSON.utf8))
    return ContentItem(id: ItemID(rawValue: "lesson:classmate_intro_v1"), language: .japanese,
                       kind: .lesson, payload: payload, band: "N5.1")
}

struct LessonScriptTests {

    @Test func decodesSeedShapeAndSkipsUnknownStepKinds() throws {
        let script = try #require(LessonScript(lessonItem()))
        #expect(script.id == "lesson:classmate_intro_v1")
        #expect(script.topicEN == "introducing yourself")
        #expect(script.scenarioRef?.rawValue == "scenario:self_intro_v1")
        // 6 raw steps, 1 unknown ("hologram_dance") skipped tolerantly.
        #expect(script.steps.count == 5)

        guard case .explain(let focus) = script.steps[0] else { Issue.record("step 0"); return }
        #expect(focus.contains("introductions"))

        guard case .modelAndRepeat(let rep) = script.steps[1] else { Issue.record("step 1"); return }
        #expect(rep.target == "はじめまして")
        #expect(rep.pronGraded)
        #expect(rep.accepted == ["はじめまして"])

        guard case .promptResponse(let probe) = script.steps[2] else { Issue.record("step 2"); return }
        #expect(probe.expectedPatterns == ["です"])
        #expect(probe.itemRefs.first?.rawValue == "vocab:名前")

        guard case .miniRoleplay(let cap, let ref) = script.steps[3] else { Issue.record("step 3"); return }
        #expect(cap == 6)
        #expect(ref?.rawValue == "scenario:self_intro_v1")

        guard case .wrap = script.steps[4] else { Issue.record("step 4"); return }
    }

    @Test func repeatStepDefaultsAcceptedToTarget() {
        let rep = LessonStep.Repeat(target: "こんにちは", glossEN: "hello")
        #expect(rep.accepted == ["こんにちは"])
    }

    @Test func nonLessonItemsDecodeToNil() throws {
        var item = try lessonItem()
        item = ContentItem(id: item.id, language: .japanese, kind: .vocab, payload: item.payload)
        #expect(LessonScript(item) == nil)
    }
}
