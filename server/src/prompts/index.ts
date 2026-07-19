// Server-side prompt template store (§7). The client sends {template_id,
// variables, messages?}; prompt TEXT lives ONLY here and never reaches the
// client. Each template renders variables (+ any appended transcript messages)
// into a ChatRequest, optionally constrained to a strict JSON schema.

import type { ChatMessage, StructuredSpec } from "../providers/types.ts";

export interface RenderedPrompt {
  system?: string;
  messages: ChatMessage[];
  maxTokens?: number;
  structured?: StructuredSpec; // present → route uses completeStructured
}

export interface PromptTemplate {
  id: string;
  // `kind` gates cost-cap behavior (§4.3.6): only "drill" work is allowed once
  // the daily hard cap is hit; roleplay/content are refused for new sessions.
  kind: "drill" | "roleplay" | "content";
  render(variables: Record<string, unknown>, extra: ChatMessage[]): RenderedPrompt;
}

// The Director verdict schema — §4.4, verbatim shape. Strict JSON the Director
// call must return after every learner turn. Guardrails (min-turns, end_scene
// legality) are enforced in CLIENT code, not the prompt (Decision D6).
export const DIRECTOR_SCHEMA: Record<string, unknown> = {
  type: "object",
  additionalProperties: false,
  properties: {
    goal_updates: {
      type: "array",
      items: {
        type: "object",
        additionalProperties: false,
        properties: {
          goal_id: { type: "string" },
          status: { type: "string", enum: ["completed", "in_progress", "not_started"] },
          evidence_turn: { type: "integer" },
        },
        required: ["goal_id", "status"],
      },
    },
    learner_band: {
      type: "object",
      additionalProperties: false,
      properties: {
        assessment: { type: "string", enum: ["below", "at", "above"] },
        confidence: { type: "number" },
      },
      required: ["assessment", "confidence"],
    },
    difficulty_cmd: { type: "string", enum: ["step_down", "hold", "step_up"] },
    confusion: {
      type: "object",
      additionalProperties: false,
      properties: {
        detected: { type: "boolean" },
        signal: { type: "string", enum: ["repeated_misparse", "silence", "L1_switch", "explicit", "none"] },
        ladder_step: { type: "integer" },
      },
      required: ["detected"],
    },
    errors: {
      type: "array",
      items: {
        type: "object",
        additionalProperties: false,
        properties: {
          category: { type: "string", enum: ["vocab", "grammar", "particle", "pronunciation", "register", "word_order"] },
          surface: { type: "string" },
          expected: { type: "string" },
          item_ref: { type: "string" },
          severity: { type: "string", enum: ["minor", "recurring"] },
        },
        required: ["category", "surface", "expected", "severity"],
      },
    },
    register_notes: {
      type: "array",
      items: {
        type: "object",
        additionalProperties: false,
        properties: {
          expected: { type: "string" },
          observed: { type: "string" },
          turn: { type: "integer" },
        },
        required: ["expected", "observed"],
      },
    },
    actor_directive: { type: "string" },
    scene_control: { type: "string", enum: ["continue", "inject_help", "end_scene"] },
    end_reason: { type: ["string", "null"] },
  },
  required: ["goal_updates", "learner_band", "difficulty_cmd", "confusion", "errors", "scene_control"],
};

const DIRECTOR_SYSTEM = [
  "You are the Director of a Japanese-learning roleplay. You never speak to the learner and never appear in the dialogue.",
  "After each learner turn you evaluate the running transcript against the scenario goals and emit a single JSON verdict via the provided tool.",
  "Rules (honest grading, R1/R15): score ONLY against Director-verified goal completions and per-turn evidence. Never award praise. A session with fewer than 3 substantive learner turns in the target language is incomplete.",
  "Difficulty (R2): rate each learner turn below/at/above the current band and set difficulty_cmd toward comprehensible input (~i+1).",
  "Confusion ladder (R4): on repeated misparse / silence / L1 switch, set confusion.detected and the ladder_step; never end or block on STT failure.",
  "Errors (R8/R10): list vocab/grammar/particle/pronunciation/register/word_order errors with the exact surface and expected form; flag register mismatches separately.",
  "Scene control (R1/R3): only YOU may end a scene. Set scene_control=end_scene ONLY when all required goals are completed, the learner explicitly quit, or the hard time cap was hit — otherwise continue or inject_help. Guardrails are re-checked in code.",
  "Return strictly valid JSON matching the schema. No prose outside the tool call.",
].join("\n");

const directorTurn: PromptTemplate = {
  id: "director_turn",
  kind: "roleplay",
  render(variables, extra) {
    const context = {
      scenario: variables.scenario ?? null,
      goals: variables.goals ?? null,
      current_band: variables.current_band ?? variables.learner_band ?? null,
      ladder_step: variables.ladder_step ?? 0,
      register: variables.register ?? null,
    };
    const messages: ChatMessage[] = [
      {
        role: "user",
        content:
          "Scenario context (JSON):\n" +
          JSON.stringify(context) +
          "\nThe conversation transcript follows. Emit your verdict for the most recent learner turn.",
      },
      ...extra,
    ];
    return {
      system: DIRECTOR_SYSTEM,
      messages,
      maxTokens: 1024,
      structured: {
        name: "director_verdict",
        description: "The Director's structured verdict for the latest learner turn (§4.4).",
        schema: DIRECTOR_SCHEMA,
      },
    };
  },
};

const CONTENT_SYSTEM = [
  "You generate Japanese-learning curriculum content for a voice-first app.",
  "Follow the requested item type, JLPT band, and register exactly. Output only the requested content — no meta-commentary.",
  "Respect vowel-length, small-tsu, pitch-accent and keigo-register accuracy for Japanese (R10).",
].join("\n");

const contentGen: PromptTemplate = {
  id: "content_gen",
  kind: "content",
  render(variables, extra) {
    const instruction = String(variables.instruction ?? "Generate the requested content.");
    const detail: Record<string, unknown> = {
      band: variables.band ?? null,
      register: variables.register ?? null,
      item_type: variables.item_type ?? null,
      count: variables.count ?? null,
    };
    const messages: ChatMessage[] = [
      { role: "user", content: `${instruction}\n\nParameters (JSON): ${JSON.stringify(detail)}` },
      ...extra,
    ];
    return { system: CONTENT_SYSTEM, messages, maxTokens: 2048 };
  },
};

// The Actor (§4.4): the in-character partner for cheap-mode (cascade) roleplay.
// It NEVER ends the scene, awards scores, or praises overall performance — those
// belong to the Director + code guardrails (D6, R3, R15). Persona, register, and
// the Director's directive steer the reply; seed words are elicited naturally.
const ACTOR_SYSTEM = [
  "You are an in-character conversation partner in a Japanese roleplay for a learner.",
  "Speak ONLY in natural Japanese at or just above the learner's JLPT band (comprehensible input, i+1).",
  "One new structure per exchange at most. Use gentle recasts for errors; do not lecture.",
  "ABSOLUTE RULES: never end the scene, never say the learner did well/poorly, never give a score,",
  "never break character, never write English except a brief L1 bridge if explicitly directed.",
  "Match the scenario's register exactly (casual/polite/keigo).",
].join("\n");

const actorTurn: PromptTemplate = {
  id: "actor_turn",
  kind: "roleplay",
  render(variables, extra) {
    const context: Record<string, unknown> = {
      scenario_id: variables.scenario_id ?? null,
      setting: variables.setting ?? null,
      persona_hint: variables.persona_hint ?? null,
      persona: variables.persona ?? "warm_tutor",
      register: variables.register ?? "polite",
      band: variables.band ?? "N5",
      director_directive: variables.directive ?? null,
      elicit_words: variables.seed_items ?? null,
    };
    const messages: ChatMessage[] = [
      { role: "user", content: `Continue the scene in character. Context (JSON): ${JSON.stringify(context)}` },
      ...extra,
    ];
    return { system: ACTOR_SYSTEM, messages, maxTokens: 256 };
  },
};

const TEMPLATES: Record<string, PromptTemplate> = {
  [directorTurn.id]: directorTurn,
  [contentGen.id]: contentGen,
  [actorTurn.id]: actorTurn,
};

export function getTemplate(id: string): PromptTemplate | undefined {
  return TEMPLATES[id];
}

// ── Guided voice lessons (SESSION_DESIGN.md) ─────────────────────────────────
// The conductor (client GuidedLessonMode) drives the realtime session step by
// step: it sends {type:"lesson.step", step:{kind, variables}} control frames and
// the bridge renders these templates into per-response instructions. Prompt TEXT
// lives only here (§7); the client sends data.

export const LESSON_SYSTEM = [
  "You are a warm, patient Japanese teacher in a live one-on-one VOICE lesson with a beginner.",
  "Protocol:",
  "- Explanations, instructions, and encouragement are in ENGLISH. Japanese is for target phrases,",
  "  modeled lines, and roleplay only. Say Japanese targets slowly and clearly, then stop.",
  "- Perform exactly ONE teaching beat per turn (under ~15 seconds of speech), then STOP and wait.",
  "- NEVER ask a question and then answer it yourself. NEVER speak the learner's part.",
  "  NEVER continue past your beat. The lesson advances only when you are told what to do next.",
  "- If told the learner was unintelligible, say you didn't catch it and invite them to try",
  "  again — never pretend to have understood.",
  "- No praise about overall performance, no scores, and never end or wrap up the lesson",
  "  unless the current turn instruction explicitly says to.",
  "- Keep the tone human and encouraging; brief, not chatty.",
].join("\n");

type StepRenderer = (v: Record<string, unknown>) => string;

function transitionNote(v: Record<string, unknown>): string {
  switch (v.transition) {
    case "correct":
      return "Their last attempt was right — acknowledge in a word or two (e.g. \"Nice.\" / \"いいですね。\"), then:";
    case "struggled":
      return "They struggled with the last one — one short encouraging clause (no dwelling), then move on:";
    default:
      return "";
  }
}

const LESSON_STEPS: Record<string, StepRenderer> = {
  "lesson.explain": (v) =>
    [
      v.first === true
        ? "Open the lesson: greet the learner in English, introduce yourself as their Japanese practice partner in one sentence, and say what today's practice is about."
        : "Briefly set up the next part of the lesson in English.",
      `Topic: ${String(v.topic_en ?? "")}`,
      v.focus_en ? `Cover, in your own words: ${String(v.focus_en)}` : "",
      "Do not teach a phrase yet and do not ask a question — just frame it, then stop.",
    ].filter(Boolean).join("\n"),

  "lesson.model_repeat": (v) =>
    [
      "Teach one phrase and elicit a repeat:",
      `Target (Japanese): ${String(v.target ?? "")}`,
      v.reading ? `Pronunciation reading: ${String(v.reading)}` : "",
      `Meaning: ${String(v.gloss_en ?? "")}`,
      "In English, give the meaning in a natural sentence, then say the Japanese target slowly and",
      "clearly ONCE, then invite them to try saying it. Then stop and wait.",
    ].filter(Boolean).join("\n"),

  "lesson.reprompt": (v) =>
    [
      "You couldn't make out what the learner said (noise or silence).",
      "In English, gently say you didn't catch that and invite them to try again.",
      v.target ? `Model the target once more, slowly: ${String(v.target)}` : "",
      "Then stop and wait.",
    ].filter(Boolean).join("\n"),

  "lesson.correct_retry": (v) =>
    [
      "The learner's attempt didn't match the target. Correct it kindly:",
      `What they said (as transcribed): ${String(v.heard ?? "")}`,
      `The target: ${String(v.target ?? "")}`,
      v.reading ? `Reading: ${String(v.reading)}` : "",
      "In English, briefly point out the difference (one concrete thing, no lecture), then model",
      "the target again slowly and invite one more try. Then stop and wait.",
    ].filter(Boolean).join("\n"),

  "lesson.prompt_response": (v) =>
    [
      "Ask the learner a question they should answer in Japanese:",
      `Ask, in Japanese: ${String(v.question_jp ?? "")}`,
      v.expectation_en ? `(They are expected to: ${String(v.expectation_en)})` : "",
      "Ask ONLY the question — slowly and clearly. Do not model an answer. Then stop and wait.",
    ].filter(Boolean).join("\n"),

  // Flavor B (SESSION_DESIGN Act 3B): interrogative probes in English, both directions.
  "lesson.translate_to_jp": (v) =>
    [
      "Production probe. In English, ask the learner how they would say this in Japanese:",
      `The English meaning to elicit: "${String(v.english_prompt ?? "")}"`,
      "Ask naturally (e.g. \"How would you say … in Japanese?\"). Do NOT say the Japanese",
      "answer or any part of it. Then stop and wait.",
    ].join("\n"),

  "lesson.translate_to_en": (v) =>
    [
      "Comprehension probe. Say this Japanese phrase slowly and clearly, then ask in",
      "English what it means:",
      `Phrase: ${String(v.phrase_jp ?? "")}`,
      "(e.g. \"If I said 「…」 — what did I just say?\"). Do NOT reveal the meaning.",
      "Then stop and wait.",
    ].join("\n"),

  "lesson.meaning_retry": (v) =>
    [
      "Their guess at the meaning wasn't right. Without revealing the answer:",
      `What they guessed: ${String(v.heard ?? "")}`,
      `The phrase: ${String(v.phrase_jp ?? "")}`,
      "In English, say that's not quite it, offer one small nudge (context, not the",
      "answer), repeat the phrase once slowly, and ask again. Then stop and wait.",
    ].join("\n"),

  "lesson.hint": (v) =>
    [
      "The learner asked for help. In English, give one short hint toward the expected answer",
      v.hint_en ? `Hint content: ${String(v.hint_en)}` : "",
      v.target ? `If useful, remind them of: ${String(v.target)}` : "",
      "Then re-ask or re-invite briefly. Then stop and wait.",
    ].filter(Boolean).join("\n"),

  "lesson.roleplay_open": (v) =>
    [
      "Switch into roleplay. First, in English and one sentence, tell them you'll now practice it",
      "for real and who you're playing. Then deliver your FIRST in-character line in Japanese.",
      `Scene (JSON): ${JSON.stringify({
        setting: v.setting ?? null,
        persona_hint: v.persona_hint ?? null,
        register: v.register ?? "polite",
        band: v.band ?? "N5",
      })}`,
      "In character: natural Japanese at the learner's band, one exchange, then stop and wait.",
    ].join("\n"),

  "lesson.roleplay_turn": (v) =>
    [
      "Continue the roleplay in character, in Japanese, one exchange only.",
      `Register: ${String(v.register ?? "polite")}, band: ${String(v.band ?? "N5")}.`,
      v.directive ? `Director's steering for this turn (obey it): ${String(v.directive)}` : "",
      "Gentle recasts for errors; never lecture mid-scene, never end the scene. Stop and wait.",
    ].filter(Boolean).join("\n"),

  "lesson.roleplay_help": (v) =>
    [
      "The learner is confused in the roleplay. Help, matched to this level:",
      helpInstruction(String(v.kind ?? "rephrase_simpler"), v),
      "Then stop and wait.",
    ].join("\n"),

  "lesson.wrap": (v) =>
    [
      "Close the lesson, in English, briefly:",
      v.praise_allowed === true
        ? "They earned it today — one warm, specific sentence of praise is allowed."
        : "Do NOT praise overall performance; be encouraging about effort only.",
      typeof v.goals_completed === "number"
        ? `Scene goals completed: ${v.goals_completed} of ${v.goals_total}. State this honestly.`
        : "",
      Array.isArray(v.struggles) && v.struggles.length
        ? `Mention (kindly, one sentence) that these will come back in review: ${(v.struggles as unknown[]).join("、")}`
        : "",
      "End with one sentence about what you'll practice together next time. Then say goodbye briefly.",
    ].filter(Boolean).join("\n"),
};

function helpInstruction(kind: string, v: Record<string, unknown>): string {
  switch (kind) {
    case "rephrase_simpler":
      return "Repeat your last Japanese line more slowly with simpler words (stay in Japanese).";
    case "show_text_furigana":
      return `Say the key phrase again very slowly, syllable by syllable${v.target ? `: ${String(v.target)}` : ""}.`;
    case "l1_bridge":
      return "Briefly explain in English what was just said and what they might answer, then repeat the Japanese line once.";
    case "log_weakness_advance":
      return "In English, reassure them it's fine, give the meaning, and move the scene forward yourself with an easy next line in Japanese.";
    default:
      return "Repeat your last line more slowly and simply.";
  }
}

/** Render a lesson step into per-response instructions. Throws on unknown kind. */
export function renderLessonStep(kind: string, variables: Record<string, unknown>): string {
  const renderer = LESSON_STEPS[kind];
  if (!renderer) throw new Error(`unknown lesson step kind: ${kind}`);
  const parts = [LESSON_SYSTEM, "# This turn", transitionNote(variables), renderer(variables)];
  return parts.filter((p) => p.length > 0).join("\n\n");
}

/** Standing instructions for a lesson-mode realtime session (safety net for any
 * bare response.create; every step render is self-contained regardless). */
export function getLessonSessionInstructions(): string {
  return LESSON_SYSTEM;
}

/** Actor instructions for the realtime (Pipeline A) session.update (§4.3.1). */
export function getRealtimeInstructions(variables: Record<string, unknown>): string {
  const scene = {
    setting: variables.setting ?? null,
    persona_hint: variables.persona_hint ?? null,
    persona: variables.persona ?? "warm_tutor",
    register: variables.register ?? "polite",
    band: variables.band ?? "N5",
  };
  return `${ACTOR_SYSTEM}\n\nScene (JSON): ${JSON.stringify(scene)}`;
}
