# Tenpo — Build Progress (resumable status)

**This file is the single source of truth for build state.** A fresh session should
read this + `docs/ARCHITECTURE.md` (the spec) and can resume without reloading the
whole history. Update it whenever a chunk is verifiably complete.

Last updated: 2026-07-23 (batch 12 — teaching quality + omnicron v1)

## How to build & test (conventions)
- Xcode 26.6 installed but `xcode-select` points at CommandLineTools → prefix Swift
  commands: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
- Package tests (macOS): `cd ios/Packages/TenpoKit && DEVELOPER_DIR=... swift test`.
- App build: `cd ios && xcodegen generate && DEVELOPER_DIR=... xcodebuild -project Tenpo.xcodeproj -scheme Tenpo -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`.
- Regenerate the Xcode project (`xcodegen generate`) whenever you ADD a Swift file to `ios/App`.
- Server (Node 22+, runs .ts directly): `cd server && npm test`.
- Swift 6.3 gotchas: no `NSLock.lock()` inside `async` fns (use a `synced {}` helper);
  assigning `Task {}` to a stored property trips the region-isolation checker (make the
  type an `actor`); cross-module protocol-extension witnesses for `ExpressibleByStringLiteral`
  don't emit — keep `init(stringLiteral:)` concrete per struct.

## Current test counts
- Swift: **141** tests (`swift test`) — all green. Server: **17**.

## Batch 12 (2026-07-23) — teaching quality + the omnicron
- ✅ **Teaching-prompt upgrade**: LESSON_SYSTEM now instructs breakdowns
  (word-by-word), recasting (name the ONE fix, never "wrong"), recaps, natural
  transitions, name use, and varied wording. It also tells the tutor to READ THE
  LEARNER — acknowledge frustration and offer an easier win instead of drilling,
  answer meta/off-topic remarks like a person — the two things Pingo does worst.
  New `lesson.recap` beat fires at a natural seam after a run of taught phrases;
  `correct_retry` gets the attempt count and slows down on a second miss.
- ✅ **Omnicron v1** (`LearnerProfile`): level, tracked/due counts, streak,
  sessions, days-since, weak items, recurring error CATEGORIES, and concrete
  recent corrections — all from data already recorded. Sent at session open;
  the bridge folds it into session instructions under "Who you're teaching" with
  rules to adapt silently and never recite. Learner's first name comes from the
  account email. Guardrails tested: no fabricated history for new learners,
  one-off mistakes aren't "recurring", absences are gentle not scolding.
- Deployed to Fly (v12). NEXT for the omnicron: mid-session adaptivity
  (frustration/repetition detection), remembered preferences, profile-driven
  lesson choice.

## Batch 11 (2026-07-23) — Pingo teardown, minimal session UI, tappable transcript
Joshua sent a Pingo session recording + exported transcript (analysis in
`docs/PINGO_TEARDOWN.md`) and his parity/vision list.
- ✅ Session UI is now **full Pingo-minimal**: conversation screen = character +
  one hint line. Study cards/bubbles moved into a pull-up transcript. We keep a
  step-progress bar (Pingo gives no sense of place).
- ✅ **Celebration completion** (full-bleed, character in white-led celebrating
  mood) with our honest debrief kept below it.
- ✅ **Tappable transcript** (his items 4–7): `SentenceAnalyzer` (ContentKit)
  tokenizes with the shipped curriculum as its dictionary, annotating reading,
  romaji, glosses, item id, plus grammar notes for particles/polite endings and
  fixed greetings. `Romaji` (LanguagePackCore) does Hepburn incl. youon, sokuon,
  long vowels, n→m. TranscriptSheet renders per-word taps, a romaji line, and a
  kana⇄kanji toggle; WordExplanation shows reading/romaji/meaning/grammar and
  whether the word is in the review deck.
  Romanization follows PRONUNCIATION where it matters (は→wa, を→o,
  こんにちは→konnichiwa, です か→"desu ka") while the kana line keeps spelling.
- Engine decision: teaching stays **authored steps** (not a generative agent) so
  honest grading + SRS survive; richer teaching = better per-step prompts. NEXT.
- Dev harness: `TENPO_AUTOPLAY=1` runs a lesson hands-free; `TENPO_ROUTE=
  transcript|word` renders those screens directly for verification.

## Batch 10 (2026-07-19, later) — UX overhaul (Pingo-informed) + app icon
Joshua's verdict on the first build: "not good at all… everything poorly."
He sent a Pingo teardown video (narration + screens). The takeaway: the
SESSION is the app, not a screen buried under navigation. Rebuilt the shell:
- `HomeShell` — three vertically-swiped panes: Progress ↑ / Session home /
  Plan ↓. Corner chrome only (settings + streak chip). The tab/list nav is gone.
- `SessionHomePane` — horizontal mode carousel; each card is one swipe + one
  tap from speaking (lessons, free conversation, review/drills).
- `TenpoBlob` (DesignSystem) — a morphing-blob CHARACTER that is both the brand
  mark on the home cards and the voice-state indicator in session (moods:
  idle/listening/thinking/speaking/celebrating). `VoiceStateBlob` maps
  VoiceLoopState → mood; the gray orb is retired from both session views.
- `TenpoTheme` — shared palette (warm canvas, blue/pink/yellow) so shell,
  sessions, and character read as one product.
- `ProgressPane` pours the real FSRS dashboard into glanceable widget cards
  (mastery bands, weak-area heatmap, forgetting forecast, why-due tap-through) —
  substance Pingo lacks. `PlanPane` = today's queue + lesson roadmap. Streak
  computed from real session history (`AppContainer.streakDays`).
- Session screens restyled to the canvas: in-content top bar (× + segmented
  `StepProgressBar`), white study cards with shadows + spring transitions.
- **App icon**: the blob character on warm canvas (was blank — TestFlight gap),
  via CoreGraphics render, wired through the asset catalog.
- DEBUG lesson harness: `DevLessonRealtimeProvider` + `TENPO_MOCK_VOICE=1` +
  `TENPO_ROUTE=lesson` runs a full lesson on the sim with no proxy/auth/spend —
  session visuals now verifiable on every change. Old `HomeView` deleted.
- All three panes + the restyled lesson + the icon verified on the simulator.
- STILL OWED by Joshua: a screen-recording of an actual practice session
  (evidence for the chat-system rework — the "does everything poorly" half not
  yet addressed). Device verify of the live lesson also still owed.

## Batch 9 (2026-07-19, overnight) — flavors B/C, purge, pregen
- ✅ CI crash fixed: GuidedLessonSession ported from DispatchQueue+ivars to an
  **actor** (dynamic-exclusivity SIGBUS, reproducible once the suite ran
  serialized). Suite `.serialized` + per-test teardown. CI green again.
- ✅ **Flavor B** (Act 3B): `translate_to_jp` (English ask → Japanese production,
  graded like a repeat incl. honest-grader second opinion) and `translate_to_en`
  (Japanese phrase → English meaning via `englishAnswerMatches`, one no-reveal
  nudge retry `lesson.meaning_retry`, honest miss on recognition-listening).
  Classmate lesson carries one of each.
- ✅ **Flavor C** (Act 3C): `pattern` lesson step = rule + worked examples +
  generalization probes over untaught words; expands in `LessonScript` decode
  into `lesson.pattern_teach` + translate probes whose grades land on the
  PATTERN's item id (pattern-level SRS → weak patterns resurface). 4 authored
  N5 patterns (たい/すぎる/ください/ましょう) as `pattern` content rows; second
  lesson `lesson:cafe_want_v1` (teaches ください+たい → cafe roleplay).
- ✅ Seeding: `seedSync` upserts the whole authored seed every launch (replaces
  the kind-gap top-up) — new lessons/patterns/gloss fixes reach existing
  installs with no migration.
- ✅ §8.2 closed: `SupabaseSyncService.purgeRemote()` (all five tables,
  user-filtered DELETE) wired into the Settings deletion flow — remote purge
  first (session still valid), sign out, local wipe; failures reported honestly.
- ✅ `server/tools/pregen_tts.ts`: audio-capex batch fill of the TTS cache from
  the seed; idempotent; `--dry-run` manifests (~$0.04 at today's 133 lines).
  Account-gated to RUN (needs provider keys via .env or fly ssh).
- Server deployed (v10+). DEVICE VERIFY still owed by Joshua (batch 8 list).

## Batch 8 (2026-07-19) — the Lesson Conductor (plan: getting-close-ish-but-no-curried-pelican)
Field test showed the realtime AI self-driving (auto-response on every VAD
endpoint), no learner transcripts (transcription unconfigured), and Japanese
immersion instead of Joshua's English-first scaffolded teaching. Fix inverted
control: **the client mode is the conductor.**
- Server: `LESSON_SYSTEM` + 10 `lesson.*` step templates (`renderLessonStep`);
  bridge init gains `mode:"lesson"` → `create_response:false` + input
  transcription (`gpt-4o-mini-transcribe`), no auto response.create; post-init
  `{type:"lesson.step"}` control frames render server-side into
  `response.create{instructions}` (§7); ≥2KB frames skip parsing (audio).
- RealtimeKit: `RealtimeSession.send(step:)` (+commit/createResponse hatches),
  `VoiceLoop` conducted policy + `openMic()`, `VoiceAudioIO` pipe (hardware in
  the view, decisions in the mode → SessionRunner persistence/SRS restored),
  `WAV.encode` (also fixed headerless-wav in AppleSpeechRecognizer.writeTemp).
- Content: `ContentKind.lesson`, `LessonScript` tolerant decode,
  `lessons_n5.json` (classmate intro: explain → はじめまして/私は〜です repeats →
  name probe → よろしくお願いします → roleplay handoff → mini_roleplay(6) → wrap),
  importer + `seedMissingKinds` top-up (seedIfEmpty never fires on populated
  stores — required for existing installs).
- `GuidedLessonMode`: step driver (framing beats chain; learner beats open the
  mic; transcript-or-timeout, noise → reprompt, NEVER advances ungraded);
  grading = transcript fast-path → HonestGrader second opinion on captured
  turn PCM (R6) → ≤2 corrective retries → honest .again+error; weak-item
  weaving (Act 1); mini-roleplay via RoleplayEngine + live Director with the
  R4 help ladder mapped to lesson.roleplay_help; wrap praise code-gated (R15)
  with struggle callouts. 11-case headless suite.
- App: Lessons section in Roleplay tab (cheap mode → scenario text cascade),
  LessonSessionView (orb + study card + step counter + goal HUD + debrief +
  DEBUG typed path). Verified on sim: lesson + 8 scenarios render.
- DEVICE VERIFY (Joshua, increment 6): English open→waits; wrong repeat →
  corrective retry naming heard; silence/noise → reprompt, no advance;
  learner bubbles; session rows + reviews; tap-interrupt; roleplay reaches
  wrap with honest goals. Risks staged: create_response:false auto-commit
  assumption (fallback commitInput), instructions override-vs-append,
  transcription field name — all one-line server fixes if wrong.

## Batch 7 (2026-07-18, daytime) — the voice loop (SESSION_DESIGN.md §1)
- ✅ Backend LIVE: Supabase (schema run, RLS verified) + Fly `tenpo-proxy`
  (healthz ok, JWT-gated). `TenpoConfig.plist` carries all three real values.
- ✅ Renamed Kizuna→Tenpo everywhere (fc6456d); bundle id com.joshuadavid.tenpo.
- ✅ Realtime model bugfix: `openai:realtime` requested a nonexistent model
  literally named "realtime"; now `openai:gpt-realtime-mini` (≈¼ the cost).
- ✅ `VoiceLoop` (RealtimeKit): pure conversation state machine — listening →
  thinking (server VAD `speech_stopped`) → speaking (first audio delta) →
  listening; **barge-in** (speech_started during speaking/thinking → flush +
  cancel); soft-cap refusal → cascade fallback action. 9 headless tests incl.
  latency meter (R18: endpoint→first-audio, p50) and PCM16 round-trip.
- ✅ `RealtimeAudioEngine` (iOS): continuous ~100ms 24kHz mono PCM16 mic chunks
  via AVAudioConverter; gapless delta playback; `.voiceChat` echo cancellation
  (else the mic barge-ins on the AI's own voice). NB: AVFAudio's own
  `AudioBuffer` collides with CoreModels' — qualify as `CoreModels.AudioBuffer`.
- ✅ `VoiceSessionView` (app): orb UI (listening/thinking/speaking), ambient
  transcript, DEBUG latency chip, End; mic-permission + friendly failure copy.
  RoleplayListView routes full-budget → voice, cheap-mode → text cascade, and
  a mid-open soft-cap refusal into the same scenario's text session.
- App builds; on-device voice E2E still UNVERIFIED (needs OPENAI_API_KEY in
  Fly, which Joshua was setting up). First live talk = next session's opener.
- NOT yet done from SESSION_DESIGN: Director worker on the voice transcript
  (grading during voice sessions), session persistence for voice turns (R12),
  Acts 1–4 orchestration, flavors B/C, TTS pre-gen.
- Server: **8** tests (`npm test`) — all green.
- CI: `.github/workflows/ci.yml` runs both suites + an unsigned app build per push.

## Batch 6 (2026-07-18) — closed the audit gaps
- ✅ **Supabase schema + RLS** (`supabase/schema.sql`): the five synced tables as
  Postgres DDL, `user_id uuid default auth.uid()` on every row, composite PKs
  including user_id, per-table RLS (`user_id = auth.uid()` for all ops). Run it in
  the dashboard SQL Editor when the project exists.
- ✅ **SyncKit ISO-8601 dates** (`PostgRESTCoding`): sync traffic had been encoding
  `Date` as Foundation reference-date doubles, which Postgres `timestamptz` would
  reject — now ISO-8601 out, tolerant decode (fractional + plain) in. 2 new tests.
- ✅ **AuthKit** (new module): Supabase GoTrue email one-time-code sign-in
  (`/otp` → `/verify`), refresh-token rotation with 60s expiry leeway, Keychain
  session store (`KeychainSessionStore`; protocol is `AuthSessionStore` — plain
  `SessionStore` collides with ModeEngine's). Chosen over Sign in with Apple
  because SIWA requires the paid Apple program; email OTP works on a free-team
  sideload. 5 tests (URLProtocol stub).
- ✅ **ProxyChatProvider** (SpeechKit): the client-side `/chat` adapter (Director/
  Actor had only the mock). Structured calls decode the server's `structured`
  field; the schema stays server-side in the template (§7).
- ✅ **Live config wiring**: `ios/App/Config/TenpoConfig.plist` (committed, blank,
  public values only) → `TenpoConfig` loader → `AppContainer.live()` swaps in
  Proxy{STT,TTS,Pron,Chat,Usage,Realtime} + auth when URLs are present; blank keeps
  mocks so the app always boots. `DynamicSyncService` consults AuthManager per
  syncNow(), so sign-in/out flips sync without a restart.
- ✅ **Sign-in UI**: Settings → Account (email → 6-digit code → signed in/sign out),
  honest "Sync is off in this build" footer when unconfigured. Verified on sim.
- NB: **account deletion is local-only right now** — `DataManager` purges the local
  tables, but a signed-in user's Supabase rows must also be deleted (and §8.2
  requires it). Wire remote purge during live verification.

## Phase status (MVP = through Phase 4; Phase 5 is post-MVP)

### Phase 0 — Skeleton ✅ DONE
SPM workspace (§4.2), GRDB schema (§4.7), AppContainer DI + mock providers, Fastify
proxy with auth/routing/cost-meter/stubs. App boots.

### Phase 1 — Learner spine ✅ DONE (+ why-due inspector §3.1)
- ✅ FSRS "why is this due?" inspector: additive `dueExplanations(now:limit:)` query
  (retrievability + stability + reps/lapses + plain-English `reason()`), most-forgotten
  first; `WhyDueView` drills in from the dashboard "Due now" row with a recall meter.
  5 unit tests. NB: fixing this surfaced + fixed a latent data race in
  `MockLearnerModelService` — config vars were written unsynchronized but read under the
  lock (`@unchecked Sendable` race); now backed by locked storage. Made `seedWeakItems…`
  test deterministic (it had been passing by timing luck).
- ✅ Weak-area heatmap (§3.3/§4.7): additive `weakAreaGrid()` aggregates tracked
  skill_state into (JLPT sub-band × dimension) mastery buckets; `WeakAreaHeatmap` renders
  a tinted grid on the dashboard. 1 unit test.
- ✅ Forgetting forecast (§4.7): additive `dueForecast(now:days:)` buckets upcoming due
  dates per day (overdue folds into today); `ForgettingForecast` mini bar chart tile. 1
  unit test. §4.7 dashboard set now complete (bands + why-due + heatmap + forecast).

- `FSRS.swift` — FSRS-6 port (21 weights, recall/lapse, R(t)+interval), pure/Sendable.
- `LiveLearnerModelService` — report() schedules FSRS; §4.5 daily queue builder
  (due-by-retrievability + freq-ordered new, no-two-consecutive-kind, production bias),
  `dueCount`, `masteryCounts` (R17 bands), R8 error→SRS loop.
- `tools/import_content.py` + `tools/seed/*.json` — N5 curriculum (214 items:
  100 vocab, 45 kanji, 37 grammar, 12 sentence, 12 cloze, 8 scenario).
- `ContentSeed` loads bundled seed on first launch; `MasteryDashboardView`.

### Phase 2 — Drills + honest grading + voice ✅ DONE (MVP modes)
- `HonestGrader` (§4.3.4) — dual-threshold; R6 provable (a `.softFail` carries `opinions>=2`).
- `AppleSpeechRecognizer` (on-device), `Proxy{STT,TTS,Pron}` clients, `AudioRecorder` (AVAudioRecorder→wav).
- `SessionRunner` (actor) + `LiveSessionStore` (R12 per-turn persistence).
- `GenericDrillSession`/`DrillConfig` + 5 modes: VocabIntro, EchoDrill (pron-graded),
  Production (EN→JP), Comprehension (JP→EN), Cloze (particle). `DrillView` with text + mic.

### Phase 3 — Roleplay ✅ ENGINE + CHEAP-MODE CLIENT DONE / ⏳ LIVE-VOICE code-complete (needs proxy)
- `Director.swift` — §4.4 verdict types (tolerant decode→safeContinue), Scenario types,
  `LiveDirectorService` (structured call, retry-then-safe-continue §11).
- `RoleplayEngine` (actor) — code-enforced guardrails (D6): end_scene only when legal,
  min-turns floor→incomplete/no-praise (R1), confusion ladder in order (R4), code-gated
  praise (R15), errors→SRS (R8). **Adversarial suite (R1/R3/R4) passes.**
- `ActorService` + `LiveActorService`; `GuidedRoleplayMode` (cheap-mode text cascade);
  `RoleplayListView` + `GuidedRoleplayView` (goal HUD = honest scoring visible R1).
- Server: `providers/{chat,stt,tts,pron}.ts`, `prompts/` (director_turn + actor_turn + content_gen), TTS cache.
- ✅ `seed_weak_items` injection (moat loop); `actor_turn` server template.
- ✅ Live-voice plumbing CODE-COMPLETE: server `/realtime` WSS bridge (OpenAI Realtime,
  closes gracefully w/o key) + client realtime provider. LIVE-VERIFY needs deployed proxy + key.
- ✅ Server cost enforcement (§4.3.6): `/chat` hard-cap gate + pure `realtimeAdmission()`
  now gates the expensive `/realtime` bridge — refuses to OPEN past the soft cap
  (client → cheap cascade) or hard cap (drills only), never interrupting an active
  session (R13). `/usage` endpoint feeds the client meter. Unit-tested (server 8).

### Phase 4 — Sync / polish / compliance ⏳ PARTIAL
- ✅ Compliance screens: `ConsentView` (§8.1 5.1.2i gate), `LicensesView` (§8.3),
  `SettingsView`+`DataManager` (account deletion + JSON export §8.2).
- ✅ Persona/voice picker (R16) in Settings; `PrivacyInfo.xcprivacy` manifest bundled;
  local cost display on dashboard.
- ✅ `SupabaseSyncService` (account-gated, injectable config) — full-table upsert push +
  LWW/append-only merge pull per §4.7; drop-in `SyncService` (`.live` uses `NoopSyncService`
  until a Supabase config exists). `SessionRunner` already fires `syncNow()` post-session.
  NOW TESTED headlessly (URLProtocol stub, `SyncKitTests`): push injects `user_id`, LWW by
  `last_review`, append-only insert-ignore. Testing caught + fixed a real bug — the pull URL
  was building `skill_state?select=*` as a percent-encoded PATH (would 404 on live PostgREST);
  now uses `URLComponents` query items.
- ✅ Client cost caps (§4.3.6, R13): pure `CostGovernor` in CoreModels (soft $2.50→cheap
  mode, hard $5→drills only; manual toggle only tightens). `AppContainer.costPolicy()`
  reads metered spend; `RoleplayListView` gates STARTING (cheap-mode notice / drills-only
  pause) and passes the chosen `SessionPipeline` (recorded on the session). Never kills an
  active session (R13). 5 unit tests.
- ✅ Cheap-mode client switch: `Preferences.forceCheapMode` + "Save on voice costs" Settings
  toggle → governor forces cascade regardless of budget.
- ✅ R8 post-session error taxonomy UI: `ErrorTaxonomyView` in the roleplay finished screen
  renders `ModeResult.errors` grouped by category (vocab/grammar/particle/pronunciation/
  register/word-order) with surface→expected diffs, "queued for tomorrow's review" note. Data
  path (Director verdict → errors → ModeResult) is unit-proven; the *populated* visual needs
  the live Director (offline mocks emit no roleplay errors).
- ✅ Realtime error-frame contract fix: `RealtimeEvent.proxyRefused` + pure `mapEvent()`
  distinguishing the proxy's bare-string `error` codes (cost_cheap_mode, unauthorized…)
  from OpenAI's `{message}` object. Was mis-parsing every proxy refusal as generic error.
  `RealtimeKitTests` (5).
- ✅ Client reads the proxy's authoritative meter: `ServerUsage` + `UsageSource` +
  `CostGovernor.policy(serverUsage:)`; `ProxyUsageService` GETs `/usage`; `costPolicy()` and
  the dashboard "Spent today" prefer server truth, fall back to the local (~$0) meter offline.
  Closes a real gap — the client cost governance had been driven by local `cost_usd` that
  never moves. Wired via injectable `AppContainer.usage` (nil until the proxy URL exists).
  Unit-tested incl. the exact server JSON shape.
- **REMAINING (MVP):**
  1. Account-gated LIVE verification — create Supabase (run `supabase/schema.sql`) +
     deploy Fly + fill `TenpoConfig.plist`, then verify: sign-in, sync resume,
     realtime voice, live Director → error taxonomy, cost meter = real proxy spend.
  2. Remote purge on account deletion (see Batch 6 NB) — required by §8.2.
  3. Joshua's call on modes 6/7/10 (listening/rapid-fire/reading): spec §9 puts them
     in Phase 4, current builds treat them as Phase 5. Modes 6/7 have implementations
     registered; reading (10) has ReaderView. Decide + verify or formally defer.
  4. App icon / asset catalog (none exists) — needed by TestFlight, not by sideload.
  (Mode 11 PitchAccentDrill and mode 9 FreeRoleplay are Phase 5 per §9/§4.6. R18
  latency debug screen: build during live verification, its metrics only exist there.)

### Phase 5 — Post-MVP (NOT this push, per spec §9)
Pitch-accent drill (needs Kanjium data), FSRS weight optimization, scenario auto-gen UI,
2nd LanguagePack, Android, launch monetization (StoreKit 2). Modes 6/7/10/11 partial.

## Account-gated (needs Joshua) — code-ready, can't run/verify here
1. **Supabase** project (URL + anon key + JWT secret) → sync + auth. Put in server `.env`
   and app config. SyncKit is built against an injectable config.
2. **Fly.io** deploy of `server/` (`fly launch` + `fly secrets set` the provider keys) →
   real Director/STT/TTS/pron. Until then the app uses on-device STT + mocks.
3. **Provider API keys** (Anthropic, OpenAI, Deepgram, Azure, ElevenLabs) → Fly secrets.
4. **Apple**: age-rating questionnaire, privacy nutrition label, signing — at submission.

## Pushed to GitHub: `JoshuaDav10/tenpo-ai` (main). CI runs on every push.

## Definition of "100% for this push"
All Phase 0–4 code that does NOT require Joshua's accounts is complete, built, and
tested; account-gated integrations are code-complete with injectable config and clearly
marked here. Phase 5 is explicitly deferred.
