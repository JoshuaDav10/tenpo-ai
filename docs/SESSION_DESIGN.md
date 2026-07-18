# Tenpo — Conversation-first session design

Joshua's product direction (2026-07-18): the app must feel like *talking to someone*,
not texting them. The current DrillView/GuidedRoleplayView type-and-send surfaces are
placeholders for the cascade pipeline — the real product interaction is voice-first.
This doc turns that direction into a buildable spec. It extends ARCHITECTURE.md
(§4.4 Director, §4.6 modes) without contradicting its Decision Log.

## 1. The voice loop (non-negotiable feel)

AI speaks → stops → listens → user speaks → **automatic end-of-turn detection** →
AI responds intelligently → repeat. No send button, no push-to-talk in conversation.

- Pipeline: mic PCM → `/realtime` WSS bridge → OpenAI Realtime (server VAD does the
  endpointing) → audio deltas back → speaker. Already bridged server-side; the
  client audio engine + session mode are the build.
- **Barge-in**: user starting to speak while the AI is talking cancels AI playback
  (that's what makes it feel like conversation, not turn-based homework).
- Transcript deltas mirror to the Director worker (§4.4) for grading/steering; the
  Director never sits in the latency path of the voice reply.
- Latency budget: voice-to-voice p50 ≤ 1.2s. The R18 debug HUD gets built alongside.
- Cost reality: realtime minutes are the expensive path — cost caps (§4.3.6) already
  gate session START; cheap-mode cascade remains the fallback and the drills remain
  fully offline.

## 2. Session arc (every conversation session follows this shape)

**Act 1 — Warm open.** AI greets in-persona, frames the scenario in one or two
sentences. If the learner has history: pull `seedWeakItems` (already built, server
template `seed_weak_items` already exists) and hand the Director 3–5 weak/lapsed
items with instructions to *engineer situations that force them* during the session.
The learner should never be told "here are your weak words" — they just keep
"coincidentally" needing them.

**Act 2 — Practice & repeat.** Short guided reps inside the conversation: AI models
a line, user echoes/varies it, AI corrects by recasting naturally (not lecturing).
Existing drill modes stay as the offline SRS spine; this act is their conversational
skin.

**Act 3 — Roleplay finale, with teeth.** Not "vomit back the script." Three flavors
the Director rotates between (per session or interleaved):

- **A. Immersion** — classic both-sides-in-Japanese roleplay (exists:
  GuidedRoleplayMode + RoleplayEngine guardrails R1/R4/R15).
- **B. Interrogative** — AI drops into English and probes both directions:
  - production probe: "How would you say *'Excuse me, where's the station?'*"
  - comprehension probe: "If I said *「駅はあそこです」*, what did I just tell you?"
  Graded by the Director like any turn; misses → error taxonomy → SRS (R8).
- **C. Extrapolation** — the moat. Teach a *productive pattern*, then make the
  learner generalize to words they have NOT been taught. (Joshua's Spanish example:
  "-ito is a diminutive; Josué→Josuesito, taco→taquito. How would you say 'little
  car'? What do you think *perrito* means?") Japanese starter patterns:
  - 〜たい (want-to): 食べる→食べたい … "how would you say 'I want to drink'?"
  - て-form chaining: 食べて→ "make 'drink and sleep'"
  - 〜すぎる (too much): 高い→高すぎる … "guess what 安すぎる means"
  - お+noun politeness, counter generalization (〜つ/〜人), な/い adjective negation
  Credit is for the *generalization*, not the vocabulary; pattern-level lapses get
  their own SRS entries so weak patterns resurface in Act 1 of later sessions.

**Act 4 — Honest debrief.** Existing surfaces: code-gated completion (R1, no
unearned praise), error taxonomy (R8 screen), "queued for tomorrow" note, cost/
latency in the debug HUD. Session ends with one concrete "next time we'll…" hook.

## 3. What exists vs. what gets built

| Piece | Status |
|---|---|
| `/realtime` WSS bridge + cost admission | ✅ server, deployed |
| Client realtime event mapping (`ProxyRealtimeSession`) | ✅ unit-tested |
| Director/guardrail engine + adversarial suite | ✅ |
| seed_weak_items loop (Act 1 weaving) | ✅ both sides |
| Error taxonomy → SRS (R8) | ✅ |
| **Client audio engine** (mic capture→PCM stream; audio-delta playback; barge-in) | 🔨 build |
| **RealtimeRoleplayMode** (SessionRunner wiring, Director worker alongside voice) | 🔨 build |
| **Voice-first session UI** (state orb: listening/thinking/speaking; ambient live transcript; no send button; exit) | 🔨 build |
| R18 latency HUD | 🔨 build (with the above) |
| **Flavor B prompts** (`interrogative_turn` template + mode steering) | 🔨 build — works on cheap/text cascade first, then voice |
| **Flavor C**: `pattern` content type + ~10 authored N5 patterns + grading rules | 🔨 build |
| Session arc orchestration (Act sequencing on top of RoleplayEngine) | 🔨 build |

Build order: audio engine → realtime mode+UI (talk happens here) → R18 HUD →
flavor B (cascade-testable, no voice dependency) → flavor C content + mode → arc
orchestration tying Acts 1–4 together.

## 4. Design-language note (separate pass)

The app is deliberately stock SwiftUI right now. Once the voice loop works, a
DesignSystem pass gives the conversation screen its identity (the orb, motion,
typography). Function first, felt-quality second — but felt-quality is a real
requirement, not a nice-to-have (Pingo comparison stands).
