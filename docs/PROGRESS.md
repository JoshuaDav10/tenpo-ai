# Kizuna — Build Progress (resumable status)

**This file is the single source of truth for build state.** A fresh session should
read this + `docs/ARCHITECTURE.md` (the spec) and can resume without reloading the
whole history. Update it whenever a chunk is verifiably complete.

Last updated: 2026-07-12 (batch 5)

## How to build & test (conventions)
- Xcode 26.6 installed but `xcode-select` points at CommandLineTools → prefix Swift
  commands: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
- Package tests (macOS): `cd ios/Packages/KizunaKit && DEVELOPER_DIR=... swift test`.
- App build: `cd ios && xcodegen generate && DEVELOPER_DIR=... xcodebuild -project Kizuna.xcodeproj -scheme Kizuna -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`.
- Regenerate the Xcode project (`xcodegen generate`) whenever you ADD a Swift file to `ios/App`.
- Server (Node 22+, runs .ts directly): `cd server && npm test`.
- Swift 6.3 gotchas: no `NSLock.lock()` inside `async` fns (use a `synced {}` helper);
  assigning `Task {}` to a stored property trips the region-isolation checker (make the
  type an `actor`); cross-module protocol-extension witnesses for `ExpressibleByStringLiteral`
  don't emit — keep `init(stringLiteral:)` concrete per struct.

## Current test counts
- Swift: **68** tests (`swift test`) — all green.
- Server: **7** tests (`npm test`) — all green.

## Phase status (MVP = through Phase 4; Phase 5 is post-MVP)

### Phase 0 — Skeleton ✅ DONE
SPM workspace (§4.2), GRDB schema (§4.7), AppContainer DI + mock providers, Fastify
proxy with auth/routing/cost-meter/stubs. App boots.

### Phase 1 — Learner spine ✅ DONE
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
- **REMAINING (MVP, all account-gated verification):** stand up Supabase + Fly.io, then
  live-verify sync resume + realtime voice. No un-blocked client code remains for Phase 0–4.
  (Mode 11 PitchAccentDrill and mode 9 FreeRoleplay are Phase 5 per §9/§4.6 — deferred.)

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

## Not yet pushed to GitHub (remote `JoshuaDav10/tenpo-ai` exists, empty). Local `main` has all commits.

## Definition of "100% for this push"
All Phase 0–4 code that does NOT require Joshua's accounts is complete, built, and
tested; account-gated integrations are code-complete with injectable config and clearly
marked here. Phase 5 is explicitly deferred.
