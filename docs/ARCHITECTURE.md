# KIZUNA (working title) — Complete Architecture & Implementation Handoff Document
## Voice-First AI Japanese Learning App — iOS First, Multi-Language Ready

**Document version:** 2.0 (Final Handoff)
**Audience:** An AI coding model executing this plan. All major decisions are FINAL and recorded in the Decision Log (§10). Do not relitigate them. Where judgment would be required, this document makes the call explicitly. Follow the phased plan in §9 in order.

---

# 1. Executive Summary & Product Thesis

## 1.1 What we are building

A voice-first Japanese learning app for iOS (iPhone + iPad, SwiftUI) with a thin Node.js backend. The core loop is inspired by Pingo.ai (short lesson: new vocab → drill → roleplay) but rebuilt around three things every competitor lacks in combination:

1. **A roleplay engine that cannot fail silently.** A "Director/Actor" architecture: one LLM plays the in-character conversation partner (Actor); a separate structured-output evaluation layer (Director) tracks scenario goals, detects learner confusion, adjusts difficulty, and decides when the scene actually ends. This directly attacks the #1 category-wide failure: AI roleplays that get confused, accept nonsense, and end prematurely with unearned praise.

2. **A persistent learner model + FSRS scheduler that every mode feeds.** Every error, hesitation, and success — in any mode — becomes evidence in a per-item, per-skill-dimension mastery record (recognition/production × listening/reading/speaking). The SRS drills weaknesses until they are effectively unforgettable. No competitor in the AI-conversation category does cross-mode error tracking with a real SRS.

3. **Honest comprehension verification.** The category's dirty secret is lenient scoring: apps accept mispronunciations, nonsense syllables, even one-word answers, and award 78/100. We build the opposite: modes that *check understanding* (JP question → EN answer, EN prompt → JP production, cloze, listening-only), strict-but-kind scoring, and a transparent mastery dashboard that never lies to the user.

The architecture is **language-agnostic with Japanese as the reference LanguagePack** (tokenization, furigana, pitch accent, keigo registers, kanji/kana/vocab/grammar item types). Adding Spanish or Korean later means writing a new LanguagePack, not rearchitecting.

## 1.2 Why this wins (grounded in complaint mining — see §2)

Every design choice below maps to a documented, repeated user complaint about Pingo, Speak, TalkPal, Duolingo Max, Teuida, and peers:

- Reviewers demonstrated Pingo awarding **78/100 for a 25-second conversation where the learner said one word** ("네"), and praising deliberate nonsense syllables. → We build a Director that scores against explicit scenario goals and a policy that scores below a floor cannot produce praise.
- Pingo's roleplays "didn't adapt to my input in any meaningful way" and stuck to simple exchanges regardless of learner level. → Director-controlled difficulty ladder with per-turn calibration.
- Pingo has **no spaced repetition** for retention; Speak has "no spaced repetition or long-term vocabulary tracking." → FSRS-6 learner model is the app's spine, not a bolt-on.
- Duolingo's Lily calls are ~30 seconds, end abruptly, and get "hung up" on one mispronounced word until the call dies. → Guardrails: minimum-turns floor, stuck-detection with escalating help (rephrase → slow down → hint → L1 bridge), never terminate on STT failure.
- Speech recognition category-wide is either too lenient (Pingo, Speak drills) or too brittle (Duolingo, Teuida rejecting correct speech). → Dual-threshold scoring with confidence display: "I heard X (low confidence) — try once more" instead of silent pass/fail, plus Azure Pronunciation Assessment for phoneme-level truth in drills.
- Japanese-specific neglect: pitch accent and vowel length change meaning, yet apps accept errors on both; keigo register errors pass as "grammatically correct." → Japanese LanguagePack includes Kanjium pitch-accent data, mora-length checking, and register tagging on every scenario.
- Subscription dark patterns (hidden pricing, hard-to-cancel, paywalled after one conversation) are the loudest 1-star driver. → For dogfooding, irrelevant; for launch, StoreKit 2 with visible pricing, generous free tier, one-tap cancel link in settings (§8).

## 1.3 Final stack (decisions locked)

| Layer | Choice | Why |
|---|---|---|
| Client | **Native Swift 5.10+ / SwiftUI**, iOS 17+, universal iPhone+iPad | Lowest audio latency (AVAudioEngine), best on-device speech access, user is iOS-only for dogfooding. Android later = separate Kotlin client against the same backend (backend-heavy design makes this cheap). |
| Local store | **SQLite via GRDB.swift** | Full SQL for FSRS queries, robust migrations, offline-first drills. |
| Sync + backend DB | **Supabase (Postgres + Auth + Realtime)** | iPhone↔iPad sync, one-user-now/multi-user-later, SQL parity with local schema. |
| API proxy | **Node.js 20 + Fastify on Fly.io** (single small VM) | API keys NEVER on device. Proxies LLM/STT/TTS, holds prompts server-side, logs cost per session. |
| Realtime voice (roleplay) | **OpenAI Realtime API** (default) with **Gemini Live** as swappable alternate behind `RealtimeVoiceProvider` | Best turn-taking/interruption handling; provider abstraction (§4.3) makes swapping a config change. |
| Drill STT | **Apple on-device SFSpeechRecognizer (ja-JP)** first pass → **Deepgram Nova (ja)** server pass when confidence < threshold | Free + instant for easy drills; server STT for grading-grade transcription. |
| Pronunciation assessment | **Azure Speech Pronunciation Assessment (ja-JP)** | Only major API with phoneme-level Japanese scoring. |
| Drill/feedback TTS | **ElevenLabs (primary voice quality)**, **OpenAI TTS (cheap fallback)**, pre-generated + cached audio for all curriculum items | Cache-first: curriculum audio is generated once, stored, and replayed free. |
| LLM (Director, evaluation, content gen) | **Claude Sonnet (claude-sonnet-4-6)** via proxy, structured outputs | Strong instruction-following for JSON Director verdicts; provider-agnostic `ChatProvider` interface allows GPT/Gemini swap. |
| SRS | **FSRS-6** (open algorithm, ported to Swift) | State of the art; per-item stability/difficulty; optimizable from the user's own review log later. |

**Dogfooding cost envelope (30–60 min/day):** ~$10–45/month depending on how much time is realtime-voice roleplay vs. cached-audio drills. Cost controls in §4.3.6.

---

# 2. Complaint-Driven Requirements

Method: complaints mined from App Store/Play reviews (via aggregators), Reddit (r/languagelearning, r/LearnJapanese), Hacker News, and long-form third-party reviews of Pingo AI, Speak, TalkPal, Duolingo Max, Teuida, Praktika, Loora, ELSA, and category roundups. Each row is a REQUIREMENT with an acceptance criterion the implementing model must satisfy. IDs are referenced throughout this document.

| ID | Complaint (evidence) | Design requirement | Subsystem | Acceptance criterion |
|---|---|---|---|---|
| R1 | Pingo scored 78/100 for a 25-sec, one-word ("네") conversation; praised typed English "I have no clue what you said"; praised nonsense syllables | **Goal-anchored scoring.** Session scores derive ONLY from Director-verified goal completions + per-turn evidence. Hard floor: < 3 substantive learner turns in target language ⇒ session marked "incomplete," no score, no praise. | Roleplay engine | Replaying the "네-only" test against our engine yields status=incomplete, feedback names the missing goals, zero praise strings emitted. |
| R2 | Pingo roleplays "didn't adapt to my input in any meaningful way"; stuck to simple exchanges regardless of complexity | **Per-turn difficulty calibration.** Director rates each learner turn (below/at/above current band) and instructs Actor to step complexity up/down; comprehensible-input target ≈ i+1. | Roleplay engine (Director) | Transcript logs show Actor vocabulary band changing within a session when learner consistently over/under-performs (test with scripted inputs). |
| R3 | Premature endings: Duolingo Lily calls ~30s, "barely had time to say anything"; Pingo says "well done!" and quits | **Anti-premature-end guardrails.** Scene may end ONLY when (a) all required goals met, or (b) learner explicitly ends, or (c) hard time cap. Actor prompt forbids closing phrases; only the Director can emit `end_scene`. | Roleplay engine | Unit test: Actor asked to "wrap up" by adversarial learner input mid-scene does not end; Director ends only when goal checklist complete. |
| R4 | Lily "got hung up" on one word (Eichhörnchen) through six retries, then the call died; STT loops kill sessions | **Stuck-detection ladder.** Same-item failure twice ⇒ escalate: (1) Actor rephrases slower/simpler, (2) show text + furigana hint, (3) offer L1 bridge ("say it in English, we'll rebuild it in Japanese"), (4) Director marks item as weakness, moves scene forward. NEVER end or block on repeated STT failure. | Roleplay engine + speech pipeline | Scripted 3× consecutive misrecognition triggers ladder steps in order; scene always progresses; item lands in learner model as `error_type=pronunciation_blocked`. |
| R5 | Lenient STT epidemic: Pingo/Speak accept mispronunciations, reversed word order, wrong vocab; "if the app doesn't catch mistakes, you'll keep making them" | **Honest dual-threshold scoring.** Drill answers get: pass (high conf), soft-fail with diff display ("I heard 〜, expected 〜"), or retry (low conf, no penalty). Pronunciation-graded items use Azure phoneme scores, thresholds per item type. Word-order and particle errors are checked by exact/structured match, not fuzzy STT. | Speech pipeline + drill modes | Deliberate wrong-particle answer (は vs が swap) is flagged with the specific particle diffed; deliberate mispronunciation below threshold soft-fails with the phoneme named. |
| R6 | Brittle STT opposite failure: Teuida/Duolingo reject correctly pronounced words; "inconsistent scoring on the same word is demoralizing" | **Never hard-fail on ASR alone.** Low-confidence ≠ wrong: prompt one no-penalty retry, then fall back to server STT (Deepgram), then to Azure assessment before any negative grade is recorded. Show what was heard. | Speech pipeline | Grading path in code provably requires ≥2 ASR opinions before a fail is written to the learner model for a spoken item. |
| R7 | No SRS / no retention system (Pingo: "no spaced repetition to ensure long-term retention"; Speak: "no long-term vocabulary tracking") | **FSRS-6 spine.** Every content item has per-skill FSRS state; daily queue mixes due reviews with new items; roleplay vocabulary is auto-enrolled. | Learner model | Item answered in ANY mode updates FSRS state; due queue reflects it on next launch; forgetting an item raises its review frequency. |
| R8 | Feedback lacks depth (Pingo "usually just accepted my response and moved on"; no categorized error lists) | **Post-session error taxonomy.** After every roleplay: Director produces categorized error list (vocab / grammar point / particle / pronunciation / register) each linked to a drillable item, plus 1–3 "next time" focus points. | Roleplay engine → learner model | Every completed session writes ≥0 structured `error_event` rows with category + item linkage; UI renders them grouped by category. |
| R9 | Parroting without comprehension: apps have you repeat JP but never verify you understood | **Comprehension-check modes** (JP→EN answer, EN→JP production, listening-only pick-the-meaning, cloze). Comprehension is a tracked skill dimension separate from production. | Mode engine + learner model | An item can be "strong" in production and "weak" in recognition simultaneously, and the queue schedules the weak dimension. |
| R10 | Japanese-specific neglect: pitch accent ignored, vowel length/gemination errors accepted, keigo register errors pass | **Japanese LanguagePack** with Kanjium pitch data on every vocab item, mora-length checks in pronunciation grading, register (casual/polite/keigo) tag on every scenario + Director register-mismatch detection. | LanguagePack(ja) + Director | Saying はし with wrong pitch pattern in a pitch-drill mode is flagged with the pattern visualized; using casual form in a keigo-tagged scenario produces a register note (not a fail). |
| R11 | Repetitive content at higher levels (Speak: "lesson variety decreases noticeably"; TalkPal: "chats become repetitive quickly") | **Generative scenario variety.** Scenarios are parameterized templates (place, goal, complication, register) + LLM-generated variants seeded from learner's weak items; no fixed script pool ceiling. | Content service | Two runs of the same scenario template produce different surface dialogue while hitting the same goal checklist. |
| R12 | Bugs/state loss: Pingo kicks users out mid-lesson and doesn't save position; transcript failures | **Crash-safe sessions.** Every turn persisted locally as it happens (SQLite write-ahead); session resume on relaunch; transcripts never depend on network success. | Client | Force-kill mid-roleplay → relaunch offers "resume session" with full transcript intact. |
| R13 | Timer/paywall interruptions mid-lesson; sessions cut off by countdown | **Never interrupt a session.** Time/credit limits gate STARTING sessions, never terminate active ones. | Client + backend | Cost cap reached mid-session ⇒ session completes on cheap pipeline; new sessions blocked with clear message. |
| R14 | Subscription dark patterns: hidden pricing, hard cancellation, one-free-conversation paywalls | **Transparent monetization (launch phase).** StoreKit 2; price + renewal terms on paywall; "Manage/Cancel subscription" link in Settings; meaningful free tier (all drills free forever; realtime voice metered). | Compliance/monetization | Paywall screen displays price, term, and cancel instructions before purchase per guideline 3.1.2; Settings deep-links to subscription management. |
| R15 | Sycophancy: praise regardless of performance destroys trust | **Calibrated feedback tone.** Praise strings are conditional on Director-verified achievement; below-threshold performance gets warm, specific, non-praise coaching ("Let's nail 〜を. Here's the pattern…"). | Roleplay + all modes | Praise copy cannot render when session score < threshold (enforced in code, not prompt). |
| R16 | Boring/robotic voices; Lily's "bored" affect polarizes | **Persona-configurable Actor voices.** 2–3 selectable personas (warm tutor, casual friend, formal senpai) mapped to distinct TTS voices + Actor system-prompt personality; default = warm. | Speech + roleplay | Persona switch changes both voice ID and Actor prompt block; register of persona matches scenario register tags. |
| R17 | Gamification fatigue vs. no motivation structure (streak anxiety complaints AND "no reason to return" complaints) | **Mastery-first motivation.** No loss-aversion streaks. Progress = transparent mastery dashboard (items known, retention curve, weak-area heatmap) + gentle daily queue. Optional streak display OFF by default. | UX | Dashboard shows per-dimension mastery counts and 7/30-day retention; no push notifications in v1. |
| R18 | Latency complaints (slow replies break conversation feel) | **Latency budgets.** Roleplay voice-to-voice p50 < 1.2s (Realtime API); drill grading < 2.5s; all curriculum audio pre-cached (0ms). | Speech pipeline | Instrumented timings logged per turn; budget violations visible in a debug screen. |

---

# 3. Differentiation Strategy & Pedagogical Foundations

## 3.1 What the best competitors do well (steal these)

- **Speak:** tight lesson flow (video → drill → vocab game → AI Q&A) that forces production dozens of times in varied contexts; "Made For You" lessons generated from your mistakes. We generalize this: *every* drill queue is "made for you" because the FSRS queue IS the lesson plan.
- **Langua:** natural voices; post-conversation categorized error lists with follow-up exercises targeting weak areas; saved-vocab review. We adopt categorized error → drill pipeline as a core loop (R8).
- **WaniKani / jpdb.io:** frequency-ordered content, SRS discipline, visible progression levels. We adopt frequency-ordered vocab introduction (BCCWJ/novel frequency lists via Kanjium data) and a visible mastery ladder.
- **Anki:** user trust through transparency and control. We expose the scheduler: users can see WHY an item is due and adjust daily load.
- **Pingo:** low-friction "pick scenario, talk in seconds" entry; scenario variety including debates/speeches. We keep the 3–7 minute session shape — it's the right dose.

## 3.2 The gap nobody fills (our category-defining bet)

**One unified learner model driving all four skills.** Every competitor is either conversation-only with no memory (Pingo, TalkPal), curriculum-first with shallow conversation (Speak, Duolingo), or SRS-only with no speech (Anki, WaniKani, jpdb). Nobody closes the loop: *speech errors becoming flashcards, flashcard weaknesses shaping tomorrow's roleplay scenario.* That loop is our moat — it compounds: the longer you use it, the more personalized (and irreplaceable) it becomes. A venture-backed competitor can copy any single feature; copying six months of YOUR error history is impossible.

Secondary differentiators, in priority order:
1. **Honest assessment** (R1, R5, R15) — trust is the scarce resource in this category.
2. **Japanese depth**: pitch accent training with visual pitch contours (Kanjium data, OJAD patterns), keigo-register-aware scenarios, kanji↔vocab linkage. Only niche tools do any of this; none do it inside conversation practice.
3. **Comprehension verification** (R9) — measurably knowing vs. parroting.
4. **Transparent mastery dashboard** (R17) — "here is exactly what you know, and what you're about to forget."

## 3.3 Pedagogical grounding (constraints the implementation must respect)

These are not decoration; they are engineering constraints:

- **Comprehensible input (Krashen, i+1):** Actor output must sit slightly above learner level. Implementation: Director tags each learner band (JLPT-anchored N5→N1 sub-bands); Actor prompt includes an allowed-vocabulary guidance band + "one new structure per exchange" rule (R2).
- **Output hypothesis (Swain):** production attempts, not just exposure, drive acquisition. Implementation: every session requires learner production; drills bias 60/40 toward production over recognition once an item's recognition stability > 7 days.
- **Retrieval practice / testing effect:** testing beats restudy. Implementation: new vocab gets an immediate retrieval attempt within the same session (intro → 2 distractor turns → retrieval), not just repetition.
- **Desirable difficulties (Bjork) + interleaving:** drill queues interleave item types (vocab/grammar/listening) and never block-drill one item; retrieval is scheduled at the edge of forgetting (that's FSRS's whole job).
- **Corrective feedback (SLA research):** recasts alone are often unnoticed; explicit correction + opportunity to reattempt ("output-prompting") is more effective for form accuracy. Implementation: in-scene, Actor uses gentle recasts (keeps immersion); post-scene, Director surfaces explicit corrections with reattempt drills (R8). Register/pragmatic errors always get explicit notes because recasts can't signal them.
- **Task-based language teaching (TBLT):** roleplay scenarios are TASKS with success conditions ("get the pharmacist to recommend something for a headache, ask about dosage"), not free chat. This is exactly what the Director's goal checklist encodes (R1, R3).

## 3.4 Monetization posture (for later; dogfood phase = no paywall)

Category norms: $10–25/mo subscriptions, loud resentment at weekly billing and bait paywalls. When launching: free tier = all offline drills + N SRS items + 1 short roleplay/day on the cheap pipeline; paid ($12.99/mo, $79.99/yr) = unlimited realtime voice, pitch-accent suite, unlimited scenario generation. No lifetime tier (COGS is per-minute). All of R14 applies.

**Unit economics — TBD from research.** The pricing above is a planning posture, not a
verified P&L. Real per-session COGS is dominated by real-time voice, whose price shifts
quarterly (and has cheaper tiers now than when this was written). Before setting shipping
cost caps or committing to the $12.99/$79.99 points, run the deep-research prompt in
`docs/COSTING_RESEARCH.md` and ingest its findings there; then update the price table
(`server/src/pricing.ts`), cap defaults (`server/src/costMeter.ts`,
`CostGovernor.swift`), and this section.

---

# 4. System Architecture

## 4.1 Topology

```
┌────────────────────────────── iOS Client (SwiftUI) ──────────────────────────────┐
│  Mode Engine (plugins)   Roleplay UI    Drill UI    Dashboard    Reader          │
│        │                                                                          │
│  Core Services (Swift packages):                                                  │
│   LearnerModelService(FSRS)  ContentService  SpeechService  SessionRecorder       │
│   LanguagePack(ja)           SyncService(Supabase)   GRDB/SQLite (source of truth │
│                                                       for learner state, offline) │
└───────────────┬───────────────────────────────────────────────┬──────────────────┘
                │ HTTPS/WSS (never holds provider keys)          │ Supabase client
                ▼                                                ▼
┌────────── Node/Fastify proxy (Fly.io) ──────────┐   ┌──── Supabase (Postgres) ───┐
│ /realtime  → OpenAI Realtime / Gemini Live (WSS) │   │ auth, sync of learner state │
│ /chat      → Claude Sonnet (Director, content)   │   │ session logs, transcripts   │
│ /stt       → Deepgram Nova ja                    │   │ (mirror of local SQLite)    │
│ /tts       → ElevenLabs / OpenAI TTS (+ cache)   │   └─────────────────────────────┘
│ /pron      → Azure Pronunciation Assessment      │
│ cost meter, prompt store, provider router        │
└──────────────────────────────────────────────────┘
```

Principles: (a) client owns learner state locally (offline drills always work, R12); (b) backend owns secrets, prompts, and provider routing; (c) everything provider-facing goes through the abstraction interfaces in §4.3 so providers are config, not code.

## 4.2 Client architecture (Swift)

Project layout (Swift Package Manager workspace, one app target):

```
App/
  KizunaApp.swift            # entry, DI container
Packages/
  CoreModels/                # value types: ContentItem, ReviewEvent, ErrorEvent…
  LearnerModel/              # FSRS engine, mastery queries, error ingestion
  ContentKit/                # curriculum store, scenario templates, JMdict access
  SpeechKit/                 # STT/TTS/pron interfaces + Apple on-device impls
  RealtimeKit/               # WSS client for realtime voice via proxy
  ModeEngine/                # LearningMode protocol + registry + session runner
  Modes/                     #   one target per mode (VocabIntro, EchoDrill, …)
  LanguagePacks/
    LanguagePackCore/        # protocol + shared types
    JapanesePack/            # tokenizer, furigana, pitch, registers, JMdict
  Persistence/               # GRDB setup, migrations, DAOs
  SyncKit/                   # Supabase sync (last-write-wins per row + review-log merge)
  DesignSystem/              # shared UI primitives (PromptCard, AnswerBar, PitchContourView…)
```

Rules for the implementing model: value types in CoreModels are `Codable + Sendable`; services are protocol-first (every service has a protocol + a live impl + a mock impl for tests); no singletons — a single `AppContainer` builds the graph; all provider calls behind `async throws` interfaces.

## 4.3 Speech & LLM pipeline with provider abstraction

### 4.3.1 The two pipelines

- **Pipeline A — Realtime (roleplay only):** client mic → WSS → proxy → OpenAI Realtime API (speech-to-speech, server VAD, barge-in). The proxy injects the Actor system prompt and streams audio both ways. Director runs OUT OF BAND on the accumulating transcript (§4.4).
- **Pipeline B — Cascade (all drills, evaluation, cheap-mode roleplay):** on-device SFSpeechRecognizer(ja-JP) first → if confidence < 0.75 or the item is pronunciation-graded, audio goes to proxy `/stt` (Deepgram) and/or `/pron` (Azure). TTS is cache-first: curriculum audio pre-generated via ElevenLabs and stored in Supabase storage + on-device cache.

### 4.3.2 Provider interfaces (implement exactly these)

```swift
public protocol ChatProvider: Sendable {
  func complete(_ req: ChatRequest) async throws -> ChatResponse            // text
  func completeStructured<T: Decodable>(_ req: ChatRequest,
                                        schema: JSONSchema,
                                        as type: T.Type) async throws -> T  // JSON mode
}

public protocol STTProvider: Sendable {
  func transcribe(_ audio: AudioClip, locale: LanguageID,
                  hints: [String]) async throws -> Transcription            // hints = expected answer(s)
}

public protocol TTSProvider: Sendable {
  func synthesize(_ text: String, voice: VoiceID,
                  locale: LanguageID) async throws -> AudioClip
}

public protocol PronunciationAssessor: Sendable {
  func assess(_ audio: AudioClip, referenceText: String,
              locale: LanguageID) async throws -> PronunciationReport      // phoneme + prosody scores
}

public protocol RealtimeVoiceProvider: Sendable {
  func openSession(_ config: RealtimeConfig) async throws -> RealtimeSession
}
public protocol RealtimeSession: AnyObject, Sendable {
  var events: AsyncStream<RealtimeEvent> { get }   // .partialTranscript, .assistantAudio, .assistantTranscript, .turnEnded, .error
  func send(audio: AudioBuffer) async throws
  func send(systemUpdate: String) async throws      // Director → Actor steering mid-scene
  func interrupt() async throws
  func close() async
}
```

`Transcription` carries `text`, `confidence: Double`, `alternatives: [String]`, `provider: ProviderID`. Grading code MUST consult confidence (R5, R6).

### 4.3.3 Provider routing

The proxy holds a routing table (JSON config, hot-reloadable):

```json
{
  "chat":     { "primary": "anthropic:claude-sonnet-4-6", "fallback": "openai:gpt-4.1-mini" },
  "stt":      { "primary": "deepgram:nova-ja",            "fallback": "openai:whisper-1" },
  "tts":      { "primary": "elevenlabs:voice_map",        "fallback": "openai:tts-1" },
  "pron":     { "primary": "azure:ja-JP" },
  "realtime": { "primary": "openai:realtime",             "fallback": "gemini:live" }
}
```

Client never names providers; it names capabilities. Swapping providers = editing this file. (Verify current model names/pricing at implementation time — provider catalogs change quarterly.)

### 4.3.4 Honest grading algorithm (R5/R6, implement verbatim)

```
grade(spokenAnswer, item):
  t1 = onDeviceSTT(audio, hints: item.acceptedAnswers)
  if t1.confidence >= 0.85 and matches(t1, item):        return PASS(evidence: t1)
  if t1.confidence <  0.60:                              prompt no-penalty retry (once)
  t2 = serverSTT(audio, hints: item.acceptedAnswers)      # Deepgram
  if matches(t2, item):                                   return PASS(evidence: t2)
  if item.isPronunciationGraded:
      p = azureAssess(audio, reference: item.canonical)
      if p.overall >= item.pronThreshold:                 return PASS(evidence: p)
      else:                                               return SOFT_FAIL(phonemeDiff: p.worstPhonemes)
  return SOFT_FAIL(diff: bestAlignment(t2.text, item.canonical))
# SOFT_FAIL always shows "I heard: 〜 / expected: 〜" and offers reattempt; a fail is
# recorded to the learner model only after the second distinct ASR opinion (R6).
```

### 4.3.5 Latency budgets (R18)

Roleplay voice-to-voice p50 < 1.2s / p95 < 2.5s (Realtime API handles this; proxy adds < 50ms). Drill grade round-trip < 2.5s. Curriculum TTS: 100% cache hit after first generation. Instrument every stage with signposts; surface in a hidden debug screen.

### 4.3.6 Cost controls

Proxy meters cost per session (tokens + audio-seconds × price table). Daily soft cap (default $2.50) → new roleplays use Pipeline B cheap mode (STT→Claude→cached-voice TTS, ~10× cheaper, higher latency). Hard cap (default $5) → drills only. NEVER kill an active session (R13). Estimated dogfood spend: drills ≈ $0 marginal (on-device STT + cached TTS); 20 min/day realtime roleplay ≈ $9–35/mo depending on provider pricing at build time — verify current per-minute rates before setting defaults.


## 4.4 Roleplay Engine (Director / Actor)

The subsystem that must not fail. Two roles, strictly separated:

- **Actor** — the in-character partner. Runs on the Realtime API (or cascade in cheap mode). Its system prompt contains: persona, scenario setting, register tag, current difficulty band, "one new structure per exchange" rule, recast-style correction policy, and an ABSOLUTE prohibition on ending the scene, awarding scores, or praising overall performance (R3, R15). The Actor may be steered mid-scene via `send(systemUpdate:)`.
- **Director** — a structured-output Claude call, invoked after EVERY learner turn on the running transcript. It never speaks to the learner. It returns exactly this JSON (define as a strict schema):

```json
{
  "goal_updates":   [{ "goal_id": "g2", "status": "completed", "evidence_turn": 7 }],
  "learner_band":   { "assessment": "below|at|above", "confidence": 0.8 },
  "difficulty_cmd": "step_down|hold|step_up",
  "confusion":      { "detected": true, "signal": "repeated_misparse|silence|L1_switch|explicit", "ladder_step": 2 },
  "errors":         [{ "category": "particle", "surface": "学校を行く", "expected": "学校に行く",
                       "item_ref": "grammar:ni_direction", "severity": "recurring" }],
  "register_notes": [{ "expected": "polite", "observed": "casual", "turn": 5 }],
  "actor_directive": "Rephrase your last question using only N5 vocabulary, speak 20% slower.",
  "scene_control":  "continue|inject_help|end_scene",
  "end_reason":     null
}
```

**Control loop:** client applies `actor_directive` via `systemUpdate`; `scene_control=end_scene` is the ONLY path to ending (guardrail enforced in client code — Actor "goodbye" text without Director end_scene does not end the session). `end_scene` is only legal when all `required` goals are completed, the learner quit, or the hard cap (10 min) hit — enforce in code, not prompt (R1, R3).

**Scenario definition (content format):**

```json
{
  "id": "pharmacy_headache_v1",
  "title": "薬局で", "register": "polite", "band": "N5.3",
  "setting": "Small pharmacy in Kyoto, evening.",
  "persona_hint": "middle-aged pharmacist, kind, speaks clearly",
  "goals": [
    { "id": "g1", "required": true,  "desc_en": "Explain you have a headache", "target_items": ["vocab:頭が痛い"] },
    { "id": "g2", "required": true,  "desc_en": "Ask for a recommendation",     "target_items": ["grammar:何かありますか"] },
    { "id": "g3", "required": false, "desc_en": "Ask about dosage",             "target_items": ["vocab:一日に何回"] }
  ],
  "complication_pool": ["item out of stock", "pharmacist asks about allergies"],
  "seed_weak_items": true
}
```

`seed_weak_items: true` ⇒ ContentService asks LearnerModel for 2–3 due/weak items in-band and instructs the Actor to elicit them naturally. This is the moat loop (§3.2): yesterday's errors shape today's scene.

**Confusion ladder (R4), triggered by Director `confusion.detected`:** step 1 rephrase simpler/slower → step 2 show text + furigana on screen → step 3 L1 bridge (Actor says the English, invites rebuilding it in Japanese) → step 4 log weakness, advance the scene. The ladder counter resets on any successful turn.

**Post-session evaluation:** one final Director call with the full transcript returns the categorized error list (R8), per-goal outcomes, 1–3 focus points, and per-item review grades that are written to the learner model as `ReviewEvent`s (production/speaking dimension). Praise copy is selected by CODE from score bands — the LLM never chooses whether to praise (R15).

## 4.5 Learner Model + FSRS

**Item skill dimensions.** Each content item tracks up to four independent FSRS states:

| Dimension | Meaning | Evidence sources |
|---|---|---|
| `recognitionReading` | see it → know meaning | cloze, reading modes, flashcard |
| `recognitionListening` | hear it → know meaning | listening-only mode, JP→EN answer |
| `productionWritten` | produce it in text | EN→JP typed, cloze-production |
| `productionSpoken` | produce it in speech | drills, roleplay (Director grades) |

FSRS-6 per dimension: `stability`, `difficulty`, `lastReview`, `due`, plus full append-only review log (needed to optimize FSRS weights on the user's own data later). Grades: Again/Hard/Good/Easy. Mode results map to grades mechanically (e.g., PASS first try = Good; PASS after retry = Hard; SOFT_FAIL = Again; roleplay: Director severity `recurring` = Again, `minor` = Hard).

**Error ingestion pipeline (LLM errors → SRS):** Director `errors[]` → resolver matches `item_ref` against the content DB (exact id, else JMdict lemma lookup via the LanguagePack tokenizer, else create a `custom` item flagged for user confirmation) → writes `error_event` + a ReviewEvent(grade: Again) on the relevant dimension → item enters tomorrow's queue and becomes eligible for `seed_weak_items` scenario seeding.

**Daily queue builder:** `queue = interleave(dueReviews (by overdue-ness), newItems (frequency-ordered, default 8/day), weakItemBoosters)`, capped by user-set daily load; dimension chosen per item = its weakest due dimension; enforce 60/40 production bias once recognition stability > 7d (§3.3). Never two consecutive items of the same type (interleaving).

**Mastery dashboard queries (R17):** counts by stability band (learning <2d / young <21d / mature ≥21d) per dimension; predicted-forgetting list (retrievability < 0.85); weak-area heatmap by grammar-point tag and by kanji.

## 4.6 Mode Engine (extensibility core)

Every learning activity is a plugin implementing:

```swift
public protocol LearningMode: Sendable {
  static var descriptor: ModeDescriptor { get }   // id, name, skill dimensions exercised,
                                                  // needsRealtime, needsNetwork, supportedBands
  init(context: ModeContext)                       // injected services, see below
  func makeSession(plan: SessionPlan) -> any ModeSession
}

public protocol ModeSession: AnyObject {
  var events: AsyncStream<ModeEvent> { get }       // drives shared UI shell
  func start() async
  func handle(_ input: LearnerInput) async         // .speech(AudioClip), .text(String), .tap(ChoiceID), .requestHint, .quit
  func finish() async -> ModeResult                // per-item grades + error events + duration
}

public struct ModeContext {
  let learner: LearnerModelService     // requestItems(count:dimension:), report(ReviewEvent)
  let content: ContentService          // items, sentences, scenarios, audio cache
  let speech:  SpeechService           // grade(), tts(), assessPronunciation()
  let realtime: RealtimeVoiceService?  // nil if descriptor.needsRealtime == false
  let pack:    any LanguagePack        // tokenize, furigana, pitch, normalization
  let director: DirectorService?       // roleplay modes only
}
```

The **SessionRunner** (one implementation, shared) owns lifecycle: builds `SessionPlan` from the daily queue, runs the mode, persists every `ModeEvent` as it happens (R12 crash-safety), commits `ModeResult` to LearnerModel + Sync, and renders shared UI primitives from `ModeEvent`s (PromptCard, AnswerBar, FuriganaText, PitchContourView, TranscriptView). A new mode = one Swift target + a registry entry; zero changes to core.

**Launch mode set (build in this order):** 1 VocabIntroMode (intro + immediate retrieval), 2 EchoDrillMode (pron-graded repeat), 3 ComprehensionJPtoEN (hear JP question, answer in English — R9), 4 ProductionENtoJP (English prompt, speak Japanese), 5 ClozeMode (text, particle/conjugation targeted), 6 ListeningPickMeaning, 7 RapidFireMode (timed rote, recognition), 8 GuidedRoleplayMode (Director/Actor, goal HUD), 9 FreeRoleplayMode, 10 ReadingPassageMode (graded text, tap-to-lookup via JMdict, furigana toggle), 11 PitchAccentDrillMode (contour visualization + assessment). Modes 1–5 + 8 are the MVP.

## 4.7 Data model (single schema, SQLite locally = Postgres in Supabase)

```sql
-- content (read-mostly, shipped + generated)
CREATE TABLE content_item (
  id TEXT PRIMARY KEY,                -- "vocab:食べる", "grammar:te_form", "kanji:食"
  language TEXT NOT NULL,             -- BCP-47: "ja"
  kind TEXT NOT NULL,                 -- vocab|grammar|kanji|sentence|scenario
  payload JSONB NOT NULL,             -- kind-specific (see LanguagePack §5)
  band TEXT, frequency_rank INTEGER,
  source TEXT, license TEXT           -- e.g. "JMdict", "EDRDG CC BY-SA 4.0" (§8)
);
CREATE TABLE item_link (              -- kanji↔vocab↔grammar↔sentence graph
  from_id TEXT, to_id TEXT, relation TEXT,  -- contains|exemplifies|uses
  PRIMARY KEY (from_id, to_id, relation)
);

-- learner state
CREATE TABLE skill_state (
  item_id TEXT, dimension TEXT,       -- recognitionReading|recognitionListening|productionWritten|productionSpoken
  stability REAL, difficulty REAL, due TIMESTAMPTZ, last_review TIMESTAMPTZ,
  reps INTEGER, lapses INTEGER, suspended BOOLEAN DEFAULT FALSE,
  PRIMARY KEY (item_id, dimension)
);
CREATE TABLE review_event (           -- append-only; feeds FSRS optimization
  id UUID PRIMARY KEY, item_id TEXT, dimension TEXT,
  grade SMALLINT,                     -- 1 Again 2 Hard 3 Good 4 Easy
  mode_id TEXT, session_id UUID, latency_ms INTEGER, at TIMESTAMPTZ
);
CREATE TABLE error_event (
  id UUID PRIMARY KEY, session_id UUID, item_id TEXT,
  category TEXT,                      -- vocab|grammar|particle|pronunciation|register|word_order
  surface TEXT, expected TEXT, severity TEXT, at TIMESTAMPTZ
);

-- sessions
CREATE TABLE session (
  id UUID PRIMARY KEY, mode_id TEXT, scenario_id TEXT,
  started_at TIMESTAMPTZ, ended_at TIMESTAMPTZ,
  status TEXT,                        -- completed|incomplete|abandoned  (R1)
  score JSONB, cost_usd NUMERIC, pipeline TEXT
);
CREATE TABLE transcript_turn (
  session_id UUID, seq INTEGER, role TEXT,   -- learner|actor|system
  text TEXT, audio_ref TEXT, director_json JSONB, at TIMESTAMPTZ,
  PRIMARY KEY (session_id, seq)
);
```

Sync: `skill_state` last-write-wins by `last_review`; `review_event`/`error_event`/`transcript_turn` append-only merge (no conflicts by construction). iPhone↔iPad continuity: opening the app shows any `incomplete` session from either device (R12).

# 5. Multi-Language Extensibility: the LanguagePack

Everything language-specific lives behind one protocol. FSRS, the mode engine, the Director loop, sync, and UI shells are language-agnostic; the pack supplies text intelligence and data.

```swift
public protocol LanguagePack: Sendable {
  var id: LanguageID { get }                       // "ja"
  var scripts: [ScriptDescriptor] { get }          // kanji/kana; hanzi+pinyin; latin…
  func tokenize(_ text: String) -> [Token]         // lemma, POS, reading per token
  func reading(for text: String) -> RubyAnnotated? // furigana / pinyin / romanization
  func normalizeAnswer(_ s: String) -> String      // kana-fold, width-fold, etc.
  func answersMatch(_ heard: String, _ expected: [String]) -> MatchResult
  var registers: [RegisterDescriptor] { get }      // ja: casual/polite/keigo; es: tú/usted
  var prosody: ProsodyModel { get }                // .pitchAccent(data) | .tones(data) | .stress | .none
  var grammarTaxonomy: [GrammarPoint] { get }      // ordered, band-tagged
  func lookup(_ lemma: String) -> DictionaryEntry? // pack-bundled dictionary
  var frequencyList: FrequencyList { get }
  var ttsVoiceMap: [PersonaID: VoiceID] { get }
  var sttLocale: String { get }                    // "ja-JP"
}
```

**JapanesePack (reference implementation):** tokenizer = bundled **Sudachi** (via SudachiKit or a small C wrapper; fall back to Apple `NLTokenizer` + JMdict longest-match if integration stalls — decision D9); readings/furigana from Sudachi + JMdict; dictionary = **JMdict** (JSON build via jmdict-simplified), kanji = **KANJIDIC2**, decomposition = KRADFILE; pitch accent = **Kanjium accents.txt** (124k words, mora-position format) rendered by `PitchContourView`; example sentences = **Tatoeba** (CC-BY) filtered by band; frequency = Kanjium novel/Wikipedia lists; registers = casual/polite(です・ます)/keigo(尊敬・謙譲) with per-scenario tags; grammar taxonomy = JLPT-ordered point list (author ~120 N5–N4 points for MVP as JSON content). `answersMatch` handles kana/kanji equivalence (食べる=たべる), long-vowel and small-tsu strictness ON for pronunciation-graded items, OFF for meaning-graded ones (R10).

**Adding language #2 (e.g., Spanish):** implement the protocol (tokenizer = NLTokenizer; prosody = .stress; registers = tú/usted; dictionary = Wiktionary extract or FreeDict; frequency = OpenSubtitles list), add TTS/STT locale mappings, author/generate the grammar taxonomy, translate scenario templates (they're language-neutral goal structures + register tags). No core changes. What stays universal: FSRS math, skill dimensions, mode engine, Director JSON contract, session/data model. What is per-language: everything inside the pack + curriculum content.


# 6. UX Blueprint (complaint-informed)

- **Home = the queue.** One primary button: "Today's session (~12 min)" building interleaved drills + one roleplay. Secondary: mode picker, mastery dashboard, reader.
- **Roleplay screen:** transcript with tap-any-word lookup (JMdict popover with pitch + furigana), goal HUD (checkmarks appear as the Director confirms goals — makes honest scoring visible, R1), help button exposing the confusion ladder manually, persona/register badge.
- **Drill shell:** shared PromptCard/AnswerBar; on soft-fail always show heard-vs-expected diff (R5); one-tap "add to focus" on anything.
- **Dashboard:** mastery bands per dimension, forgetting forecast, weak-area heatmap, cost meter (dogfood), FSRS "why is this due?" inspector (§3.1 Anki trust).
- **No streak pressure by default; no notifications in v1** (R17). Session length target 3–7 min so the Pingo-style "quick dose" habit survives.
- **iPad:** same app, `NavigationSplitView`; reader mode shines here.

# 7. Backend Spec (Node/Fastify on Fly.io)

Endpoints (all authed via Supabase JWT): `POST /chat` (Director + content gen; server-side prompt templates by id — client sends `{template_id, variables}`), `WS /realtime` (bridges client↔OpenAI Realtime; injects Actor prompt; emits transcript deltas to client AND to the Director worker), `POST /stt`, `POST /pron`, `POST /tts` (checks audio cache first; writes cache), `GET /usage` (cost meter). Middleware: per-user daily cost accounting (§4.3.6), request logging with session ids, provider router (§4.3.3). Secrets in Fly secrets store. Single shared-cpu-1x VM + Supabase free tier ≈ **$5–10/mo** infra for dogfooding. Provider keys never reach the client (non-negotiable).

# 8. Compliance, Privacy & Licensing (do these; they are cheap now and expensive later)

## 8.1 App Store (Apple, current as of mid-2026 — re-verify at submission)

- **Third-party AI consent (Guideline 5.1.2(i), Nov 2025 update):** before the first session, show a consent screen naming the AI providers (OpenAI, Anthropic, Deepgram, Microsoft Azure, ElevenLabs, Google if enabled) and stating that voice audio and conversation text are sent to them for processing. Blocking, explicit opt-in, re-shown if providers change. Store the consent record.
- **Age rating:** complete Apple's updated age-rating questionnaire (new 13+/16+/18+ tiers). An app with generative AI chat should self-rate conservatively — target **13+**; declare AI chatbot functionality honestly. Not a Kids Category app.
- **Privacy manifest:** ship `PrivacyInfo.xcprivacy` declaring: audio data (app functionality), user content (app functionality), identifiers (account). Audit every SPM dependency for its own manifest (Xcode → Product → Generate Privacy Report before every submission). Required-reason APIs (UserDefaults etc.) must be declared.
- **Privacy nutrition label** must match reality: Data Linked to You → contact info (email via Supabase auth), user content (recordings/transcripts), usage data.
- **Mic permission string** (`NSMicrophoneUsageDescription`): "Kizuna records your voice during practice to transcribe and grade your speaking. Audio is processed by speech-recognition providers listed in Settings → Privacy." Speech recognition permission (`NSSpeechRecognitionUsageDescription`) similarly.
- **Subscriptions (Guideline 3.1.2):** StoreKit 2; paywall shows price, period, renewal terms before purchase; functional Restore Purchases button; Settings link to manage/cancel (R14). No pricing hidden behind trial start.
- Build with the current required SDK (Xcode 26 / iOS 26 SDK required from April 2026).

## 8.2 Privacy law basics (solo-dev scale)

- **Data minimization:** raw audio clips are transient by default — keep transcript + grades, delete audio after grading (retain only if user opts into "save recordings for progress"). This single choice removes most privacy risk.
- **GDPR/CCPA hygiene:** privacy policy URL (in-app + App Store) listing data collected, purposes, processors (the providers above), retention; implement account deletion (Apple requires in-app account deletion anyway) that purges Supabase rows + storage; implement data export (JSON dump of learner state — trivially, it's your sync payload).
- **Provider data-handling settings:** use API tiers that do NOT train on inputs — OpenAI API (no training on API data by default; request zero-data-retention if eligible), Anthropic API (no training on API inputs/outputs by default), Deepgram/Azure/ElevenLabs: review and set data-retention/logging options to minimum. Record the settings chosen in `COMPLIANCE.md` in the repo.
- **Japan APPI:** relevant if marketing to users in Japan later; for dogfood/US launch, the GDPR-style hygiene above covers the posture.
- **COPPA:** not directed at children; 13+ rating; no child-targeted marketing. If Texas SB2420-style age-assurance signals arrive via Apple's Declared Age Range API, respect them.

## 8.3 Content licensing (attribution screen is REQUIRED, not optional)

Create Settings → About → **Licenses & Sources** (a dedicated screen — EDRDG explicitly says a launch-screen mention is NOT sufficient for mobile apps):

- **JMdict/EDICT & KANJIDIC2** — property of the Electronic Dictionary Research and Development Group, used under the Group's licence (CC BY-SA 4.0 framework); include the required acknowledgement text + links to the EDRDG project pages. Commercial use is permitted with attribution; consider the suggested donation. Note: CC BY-SA share-alike applies to the dictionary data and derivatives of it — keep dictionary data in its own files/tables, not blended into proprietary content.
- **KRADFILE** — EDRDG licence as above.
- **Kanjium** (pitch accent, frequency) — attribute per its README ("The pitch accent notation … provided by Uros O. through his free database") plus its upstream EDRDG attributions.
- **Tatoeba** example sentences — CC-BY (attribute Tatoeba.org).
- **Sudachi + SudachiDict** — Apache-2.0 licence notice.
- TTS-generated curriculum audio: verify the provider's licence permits storing/redistributing generated audio in-app (ElevenLabs and OpenAI generally permit use of outputs; record the terms version in `COMPLIANCE.md`).

# 9. Implementation Plan (sequenced for a less-capable executor)

General rules: work strictly in order; each milestone has a Definition of Done (DoD) — do not start the next until the current DoD passes; every service gets a protocol + live impl + mock impl + unit tests; commit after each numbered step.

**Phase 0 — Skeleton (day 1).** 1) Create the SPM workspace exactly as §4.2. 2) GRDB setup + migrations implementing §4.7 verbatim. 3) AppContainer DI + mock providers for every §4.3.2 interface. 4) Deploy Fastify proxy with `/chat` `/stt` `/tts` stubs + Supabase project + JWT auth. DoD: app boots to empty Home; tests green; proxy health check live.

**Phase 1 — Learner spine (days 1–2).** 1) Port FSRS-6 to Swift (`FSRS.swift`, pure functions + default weights; property tests: stability grows on Good, drops on Again; due ordering correct). 2) LearnerModelService: skill_state CRUD, review ingestion, daily queue builder per §4.5. 3) Import content: script `tools/import_content.py` builds SQLite from jmdict-simplified JSON, KANJIDIC2, Kanjium accents/frequency, Tatoeba (band-filtered); author 120 N5 grammar points + starter 400-word frequency-ordered vocab course as JSON. 4) Mastery dashboard (read-only). DoD: seeded DB; simulated 30-day review log produces sane schedules; dashboard renders real counts.

**Phase 2 — Drill modes + honest grading (days 2–4).** 1) SpeechService with Apple on-device STT + cached TTS + grading algorithm §4.3.4 (Deepgram + Azure via proxy). 2) SessionRunner + shared UI shell. 3) Modes 1–5 (§4.6 order), each: implement → unit-test grade mapping → wire to queue. 4) Crash-safe persistence (R12 test: kill mid-session, resume). DoD: full daily session (vocab intro → drills) works offline except server-STT fallback; R5/R6 acceptance tests pass; audio cache hit rate 100% on second run.

**Phase 3 — Roleplay engine (days 4–6).** 1) RealtimeKit WSS client ↔ proxy ↔ OpenAI Realtime. 2) DirectorService: structured-output call with §4.4 schema after each learner turn; strict JSON validation + one retry on invalid. 3) Guardrail enforcement in SessionRunner (end only on Director end_scene; min-turns floor; 10-min cap). 4) Confusion ladder. 5) Post-session evaluation → error ingestion pipeline → SRS enrollment. 6) GuidedRoleplayMode UI with goal HUD. 7) Author 10 N5 scenario templates. 8) Adversarial test suite: replay R1 ("one-word session"), R3 (premature end bait), R4 (3× misrecognition) scripts; all must pass. DoD: pharmacy scenario completable end-to-end; errors appear in tomorrow's queue; `seed_weak_items` demonstrably injects a weak item into a scene.

**Phase 4 — Polish + sync + compliance (days 6–7+).** 1) SyncKit (Supabase) + iPhone↔iPad resume. 2) Cheap-mode roleplay pipeline + cost meter/caps. 3) Modes 6, 7, 10 (listening, rapid-fire, reading w/ tap-lookup + furigana toggle). 4) Consent screen, privacy manifest, licenses screen, account deletion/export (§8). 5) Persona/voice selection (R16). DoD: dogfood-ready on TestFlight; compliance checklist in `COMPLIANCE.md` fully checked.

**Phase 5 (later, not this week):** PitchAccentDrillMode with contour visualization; FSRS weight optimization from the user's own review log; scenario auto-generation UI; second LanguagePack; Android (Kotlin client, same backend); launch monetization per §3.4.

# 10. Decision Log (final — do not relitigate)

| # | Decision | Rationale | Revisit trigger |
|---|---|---|---|
| D1 | Native Swift/SwiftUI, not cross-platform | Voice latency + on-device speech + iOS-only dogfooder; backend-heavy design keeps Android port cheap | Android demand becomes primary |
| D2 | OpenAI Realtime default for roleplay; Gemini Live as alternate behind abstraction | Best interruption/turn-taking today; abstraction makes it config | Pricing or JA quality shifts |
| D3 | Cascade pipeline (on-device→Deepgram→Azure) for drills | Near-zero marginal cost + phoneme truth where it matters | On-device JA STT quality jumps |
| D4 | Claude Sonnet for Director/structured outputs | Reliable JSON adherence; provider-agnostic interface anyway | Cost/quality comparison at build |
| D5 | FSRS-6 with 4 skill dimensions per item | State of the art; dimensions are the honest-model requirement (R9) | Never — core thesis |
| D6 | Director/Actor split; code-enforced guardrails over prompt-enforced | Prompts fail; the category's failures (R1–R4) are prompt-only architectures | Never — core thesis |
| D7 | SQLite (GRDB) local source of truth + Supabase mirror | Offline drills, crash safety, SQL parity | Multi-user scale |
| D8 | No gamification-by-loss-aversion; mastery dashboard instead | Complaint mining shows streak anxiety AND sycophancy erode trust | Retention data post-launch |
| D9 | Sudachi tokenizer, NLTokenizer+JMdict fallback | Best JA segmentation; fallback bounds integration risk | Fallback proves sufficient |
| D10 | Audio transient by default; transcripts retained | Removes most privacy exposure in one stroke | User opts into recordings |

# 11. Risks & Mitigations

- **Realtime API cost/pricing volatility** → cheap-mode pipeline is a first-class citizen (Phase 4.2), verify pricing at build, caps in proxy.
- **Director latency stacking on every turn** → Director runs async while Actor keeps talking; directives apply next turn; only `end_scene` is synchronous.
- **STT on beginner-accented Japanese** → hints-biased recognition, dual-opinion rule (R6), Azure phoneme backstop; log all misrecognitions for tuning.
- **Sudachi Swift integration friction** → D9 fallback, timeboxed to half a day.
- **Structured-output drift (invalid Director JSON)** → strict schema validation, one retry, then safe default `{scene_control: continue}`; never crash a scene on parse failure.
- **Scope creep in week one** → Phases are ordered so the app is useful after Phase 2 even if Phase 3 slips.
- **Solo-dev vs. venture competitors** → the moat is the longitudinal learner model (§3.2) + Japanese depth; ship the loop, not features.

# 12. Open Questions (explicitly deferred — proceed with defaults)

1. Exact provider pricing/model names — verify at build time; routing table makes changes trivial.
2. Whether to expose FSRS parameters to the user — default: read-only inspector now, tuning later.
3. App name/branding — placeholder "Kizuna."
4. Launch pricing — §3.4 defaults stand until real usage data exists.

— End of document —
