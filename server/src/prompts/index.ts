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
