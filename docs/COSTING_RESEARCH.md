# Costing & Unit-Economics Research

**Status: PENDING external research.** This file holds (1) the deep-research prompt to
run, and (2) a placeholder for the ingested findings. Until findings land, treat all
cost numbers in `ARCHITECTURE.md` §3.4 / §4.3.6 as planning estimates, not verified.

Why this is a separate research task: provider prices for real-time voice, STT, and
TTS shift quarterly, and the dominant cost (real-time speech-to-speech) has fallen and
gained cheaper tiers since these estimates were written. Do not hard-code price-table
defaults or set the shipping cost caps from memory — drive them from this research.

## Dogfood estimate (solo, pre-launch) — rough, to be replaced by research

- Offline drills: **~$0 marginal** (on-device STT + cached/on-device TTS).
- Live-voice roleplay dominates the bill; real-time audio ≈ 95% of a session's cost.
  - Director (Claude Haiku 4.5, ~15 structured calls/session): ~$0.03–0.10/session (grounded).
  - Real-time audio (OpenAI Realtime): ~$0.30–1.50/session (NEEDS VERIFICATION — top of range conservative).
- Casual dogfooding: ~$5–15/mo. Daily 20-min voice: ~$15–45/mo. Infra: ~$0–5/mo.
- Bound it hard while experimenting: `DAILY_HARD_CAP_USD=0.50` ⇒ ~$15/mo ceiling.

## Deep-research prompt (run this; paste findings below)

> **Role:** You are a unit-economics analyst for a voice-first AI language-learning iOS
> app. Produce a costing and profitability model with **current, cited pricing** (include
> the date and source URL for every number; flag anything older than 90 days).
>
> **The product:** A Japanese (later multi-language) learning app. Two cost profiles:
> **(A) offline drills** — on-device speech recognition + cached audio, ~$0 marginal cost;
> **(B) live voice roleplay** — a real-time spoken conversation with an AI partner
> (continuous listen → auto-endpoint → respond), plus an out-of-band "director" LLM making
> one structured-output call per learner turn to track goals and grade. Planned
> subscription: **$12.99/month or $79.99/year**; free tier = unlimited offline drills + N
> spaced-repetition items + 1 short roleplay/day on a cheaper pipeline.
>
> **Deliverable 1 — Current pricing table** for each capability, with the cheapest and
> best-quality option in each row, priced per relevant unit (per-minute audio, per-1M
> tokens, per-character, per-transaction):
> 1. **Real-time speech-to-speech** — OpenAI Realtime API (all tiers, incl. `gpt-realtime`
>    and any `mini` variant; note audio-input caching discounts), Google **Gemini Live
>    API**, and any credible open/self-hosted option (e.g. Ultravox, Moshi, or a
>    Whisper→LLM→TTS cascade). Give $/minute of active audio in *and* out.
> 2. **Director / structured-output LLM** — Claude Haiku 4.5 ($1/$5 per M in/out) vs.
>    Claude Sonnet 5 ($3/$15) vs. a GPT-class mini vs. Gemini Flash. Include
>    prompt-caching discounts.
> 3. **Speech-to-text** (cascade fallback) — Deepgram Nova, and cheaper/free alternatives
>    (on-device, Whisper).
> 4. **Text-to-speech** — ElevenLabs vs. OpenAI TTS vs. on-device (free) — per character;
>    note that curriculum audio is cache-once-replay-free.
> 5. **Pronunciation scoring** — Azure Pronunciation Assessment per transaction, and
>    alternatives.
> 6. **Infra** — Fly.io (shared-cpu-1x) + Supabase, at (a) 1 user, (b) 100 users,
>    (c) 1,000 users.
>
> **Deliverable 2 — Per-session and per-user-month COGS model.** Model a realtime roleplay
> session as ~10 min wall-clock with ~40% active speech each direction and ~15 director
> turns (~1.5K input / 200 output tokens each). Compute cost per session on (i) the SOTA
> realtime pipeline and (ii) the cheap cascade pipeline (on-device STT → cheap LLM →
> cached/cheap TTS). Then per-user-month at three engagement levels: light (2 sessions/wk),
> medium (1/day), heavy (3/day). Show the SOTA-vs-cascade cost delta.
>
> **Deliverable 3 — Profitability & break-even.** At $12.99/mo (subtract Apple's cut —
> 30%, or 15% under the Small Business Program / after year 1) and $79.99/yr: what monthly
> engagement level makes a paying user break even on each pipeline? Show gross margin at
> light/medium/heavy usage. Model the **free-tier subsidy** (cost of 1 cheap roleplay/day ×
> non-converting free users) and the conversion rate needed for it to pay off. Include rough
> LTV vs. CAC framing and note where heavy users go margin-negative (justifying the daily
> cost caps + no lifetime tier).
>
> **Deliverable 4 — The 80/90%-quality-at-lower-cost playbook.** For each capability in
> Deliverable 1, recommend the specific model/provider that delivers ~80–90% of SOTA quality
> at materially lower cost, with the quality/latency/cost tradeoff stated. Specifically
> assess: (a) can a self-hosted or cascade voice pipeline replace OpenAI Realtime for the
> *paid* tier without users noticing, and at what latency penalty? (b) is Claude Haiku 4.5
> sufficient for the director role vs. Sonnet 5? (c) which pieces should stay on-device
> (free) permanently?
>
> **Deliverable 5 — Recommendations:** a default per-day soft/hard cost cap per paying user;
> which providers to use for the free tier vs. the paid tier; and the 2–3 biggest levers to
> protect margin. Note Japanese-language-specific quality considerations (pitch accent,
> keigo/register) where they affect provider choice.
>
> Be concrete and numeric. State assumptions explicitly. Where pricing is volatile or
> unverifiable, say so rather than guessing.

## Ingested findings

_(partial — full report still pending; when it lands, update the cost-table
defaults in `server/src/pricing.ts`, the cap defaults in `server/src/costMeter.ts`
(`DAILY_SOFT_CAP_USD` / `DAILY_HARD_CAP_USD`) and `CostCaps.dogfoodDefault` in
`CoreModels/CostGovernor.swift`, and §3.4 / §4.3.6 of the spec.)_

### Fragment 1 (pasted by Joshua, 2026-07-18): the "$100 curriculum" — one-time TTS pre-generation

> The mechanic: TTS bills per character generated, once. Anything you synthesize
> ahead of time and store plays back forever at $0. So all predictable audio —
> vocabulary, example sentences, drill prompts, grammar pattern models, minimal
> pairs, pitch-accent demonstrations — converts from a metered cost into a
> one-time capital expense.
>
> What $100 buys, one-time:
> | Provider | Chars for $100 | ≈ Audio | ≈ Japanese sentences (~30 chars avg) |
> |---|---|---|---|
> | ElevenLabs v3 ($0.10/1K) | 1M | ~42 hrs | ~33,000 |
> | OpenAI mini-tts (~$15/M) | 6.7M | ~280 hrs | ~220,000 |
> | Azure Neural ($16/M) | 6.25M | ~260 hrs | ~210,000 |
> | Gemini Flash TTS batch ($5/M audio tokens, 50% off) | — | ~550 hrs | ~450,000 |

**Implications for us (recorded at ingest):**
- This kills the metered cost of the *reusable* voice surface (drills, curriculum
  audio, pattern models — the 60–80%). It does NOT apply to live conversation:
  realtime speech is generated per-session and stays metered — that's what the
  §4.3.6 caps govern.
- Scale check against today's content: the current seed curriculum (214 items,
  worst case a few thousand sentences of prompt/example audio) is **~$2–3 at
  ElevenLabs rates, under $1 at OpenAI/Azure rates** — the $100 figure is for a
  full multi-level curriculum (tens of thousands of sentences). Correct move:
  build the batch pre-gen pipeline now, run it for pocket change, and the same
  pipeline absorbs the $100-scale run when the curriculum grows.
- Pipeline shape: batch job (tools/) walks content items → synthesizes via the
  proxy's TTS provider adapters → stores in Supabase Storage keyed by content
  hash → client cache-first lookup (server request-time TTS cache already exists;
  this adds the *ahead-of-time* layer + client-side bundle/cache).
- `server/src/pricing.ts` note: our elevenlabs rate (0.0003/char) vs the
  fragment's v3 rate ($0.10/1K = 0.0001/char) disagree — reconcile when the full
  report + chosen plan land.
