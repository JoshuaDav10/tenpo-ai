import { test } from "node:test";
import assert from "node:assert/strict";
import { LESSON_SYSTEM, renderLessonStep } from "../src/prompts/index.ts";
import { buildSessionConfig, interceptFrame } from "../src/realtime.ts";

const ALL_KINDS = [
  "lesson.explain",
  "lesson.model_repeat",
  "lesson.reprompt",
  "lesson.correct_retry",
  "lesson.prompt_response",
  "lesson.pattern_teach",
  "lesson.translate_to_jp",
  "lesson.translate_to_en",
  "lesson.meaning_retry",
  "lesson.hint",
  "lesson.recap",
  "lesson.roleplay_open",
  "lesson.roleplay_turn",
  "lesson.roleplay_help",
  "lesson.wrap",
];

test("every lesson step kind renders and embeds the standing protocol", () => {
  for (const kind of ALL_KINDS) {
    const rendered = renderLessonStep(kind, {});
    assert.ok(rendered.includes(LESSON_SYSTEM), `${kind} missing LESSON_SYSTEM`);
    assert.ok(rendered.includes("# This turn"), `${kind} missing turn block`);
  }
});

test("step variables interpolate as data, and unknown kind throws", () => {
  const repeat = renderLessonStep("lesson.model_repeat", {
    target: "はじめまして", reading: "hajimemashite", gloss_en: "Nice to meet you",
  });
  assert.ok(repeat.includes("はじめまして"));
  assert.ok(repeat.includes("Nice to meet you"));

  const retry = renderLessonStep("lesson.correct_retry", { heard: "はじまして", target: "はじめまして" });
  assert.ok(retry.includes("はじまして"));

  const wrap = renderLessonStep("lesson.wrap", {
    praise_allowed: false, goals_completed: 1, goals_total: 2, struggles: ["よろしく"],
  });
  assert.ok(wrap.includes("Do NOT praise"));
  assert.ok(wrap.includes("1 of 2"));
  assert.ok(wrap.includes("よろしく"));

  const praised = renderLessonStep("lesson.wrap", { praise_allowed: true });
  assert.ok(praised.includes("praise is allowed"));

  assert.throws(() => renderLessonStep("lesson.nope", {}), /unknown lesson step kind/);
});

test("interrogative probes interpolate and never leak answers into the ask", () => {
  const toJP = renderLessonStep("lesson.translate_to_jp", { english_prompt: "nice to meet you" });
  assert.ok(toJP.includes("nice to meet you"));
  assert.ok(toJP.includes("Do NOT say the Japanese"));

  const toEN = renderLessonStep("lesson.translate_to_en", { phrase_jp: "お名前は何ですか" });
  assert.ok(toEN.includes("お名前は何ですか"));
  assert.ok(toEN.includes("Do NOT reveal"));

  const retry = renderLessonStep("lesson.meaning_retry", { heard: "goodbye?", phrase_jp: "はじめまして" });
  assert.ok(retry.includes("goodbye?"));
  assert.ok(retry.includes("はじめまして"));
});

test("transition variable folds acknowledgment into the next step", () => {
  const after = renderLessonStep("lesson.model_repeat", { target: "x", transition: "correct" });
  assert.ok(after.includes("acknowledge"));
  const struggled = renderLessonStep("lesson.explain", { transition: "struggled" });
  assert.ok(struggled.includes("encouraging"));
});

test("lesson session config: client holds turn authority, transcription on", () => {
  const cfg = buildSessionConfig({ mode: "lesson" }) as any;
  assert.equal(cfg.type, "realtime");
  const input = cfg.audio.input;
  assert.equal(input.turn_detection.create_response, false);
  assert.equal(input.turn_detection.type, "semantic_vad");
  assert.equal(input.turn_detection.eagerness, "low");
  assert.equal(input.turn_detection.interrupt_response, false);
  assert.ok(input.transcription.model);
  assert.ok(String(cfg.instructions).includes("ONE teaching beat"));
});

test("learner profile rides in the session instructions but is never recited", () => {
  const profile = "Learner: Joshua.\nRecurring weak spot: particles (は/が/を choice) (4 times recently).";
  const cfg = buildSessionConfig({ mode: "lesson", variables: { learner_profile: profile } }) as any;
  const instructions = String(cfg.instructions);
  assert.ok(instructions.includes("Joshua"));
  assert.ok(instructions.includes("particles"));
  // The tutor must adapt to it silently — never read it out, never recite stats.
  assert.ok(instructions.includes("NEVER read this profile aloud"));
  assert.ok(instructions.includes("never imply you are tracking them"));

  // No profile → plain protocol, no empty "who you're teaching" section.
  const plain = String((buildSessionConfig({ mode: "lesson" }) as any).instructions);
  assert.ok(!plain.includes("Who you're teaching"));
});

test("legacy session config keeps the roleplay-actor shape", () => {
  const cfg = buildSessionConfig({ variables: { setting: "cafe" } }) as any;
  assert.equal(cfg.audio.input.turn_detection.create_response, undefined);
  assert.equal(cfg.audio.input.transcription, undefined);
  assert.ok(String(cfg.instructions).includes("cafe"));
});

test("interceptFrame: lesson.step renders server-side into response.create", () => {
  const frame = JSON.stringify({
    type: "lesson.step",
    step: { kind: "lesson.explain", variables: { topic_en: "meeting a classmate", first: true } },
  });
  const routed = interceptFrame(frame);
  assert.ok("upstream" in routed);
  const up = (routed as any).upstream;
  assert.equal(up.type, "response.create");
  assert.ok(up.response.instructions.includes("meeting a classmate"));
  assert.ok(up.response.instructions.includes(LESSON_SYSTEM.slice(0, 40)));
});

test("interceptFrame forwards audio, oversized, malformed, and foreign frames untouched", () => {
  // Oversized (audio append) — must skip parsing entirely.
  const audio = JSON.stringify({ type: "input_audio_buffer.append", audio: "A".repeat(8000) });
  assert.deepEqual(interceptFrame(audio), { forward: audio });
  // Small non-lesson frame.
  const cancel = JSON.stringify({ type: "response.cancel" });
  assert.deepEqual(interceptFrame(cancel), { forward: cancel });
  // Malformed JSON.
  assert.deepEqual(interceptFrame("{nope"), { forward: "{nope" });
  // lesson.step with no kind → forwarded, not crashed.
  const bad = JSON.stringify({ type: "lesson.step", step: {} });
  assert.deepEqual(interceptFrame(bad), { forward: bad });
});
