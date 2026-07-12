# COMPLIANCE.md

Record of privacy, App Store, and licensing decisions per ARCHITECTURE.md §8.
Update this file whenever a provider is wired up or a data-handling setting is chosen.

## Provider data-handling settings (§8.2)

| Provider | Purpose | Trains on API data? | Retention setting chosen | Terms version / date |
|---|---|---|---|---|
| Anthropic (Claude) | Director, evaluation, content gen | No (API default) | Default no-training; request ZDR when eligible. Messages API `anthropic-version` 2023-06-01; structured output via forced tool-use (not output_config.format, unsupported on sonnet-4-6). Model id from routing table. | 2023-06-01 |
| OpenAI (Chat/TTS fallback) | Fallback chat + TTS | No (API default) | Default no-training; structured output via forced function tool_choice | — |
| Deepgram (Nova ja) | Server STT | TBD — review at wiring | TBD | — |
| Azure Speech | Pronunciation assessment | TBD — review at wiring | TBD | — |
| ElevenLabs | Curriculum TTS | TBD — verify output storage/redistribution license | TBD | — |

## Data minimization (D10)

- Raw audio clips are transient by default: transcript + grades retained, audio deleted after grading.
- User opt-in required to retain recordings.

## App Store checklist (§8.1) — complete before TestFlight

- [x] Third-party AI consent screen (Guideline 5.1.2(i)) naming all providers; consent record stored — `App/Compliance/ConsentView.swift`, blocking gate in `KizunaApp.swift`, re-prompts if provider set changes (`ComplianceStore`)
- [ ] Age rating questionnaire — target 13+, declare AI chatbot functionality (done at submission in App Store Connect)
- [ ] `PrivacyInfo.xcprivacy` manifest (audio, user content, identifiers) + dependency audit
- [ ] Privacy nutrition label matches reality (done at submission)
- [x] Mic + speech recognition permission strings (in project.yml)
- [x] In-app account deletion + data export — `App/Compliance/SettingsView.swift` + `DataManager.swift` (JSON export via share sheet; deletion purges learner tables + revokes consent)
- [x] Licenses & Sources dedicated screen (§8.3) — `App/Compliance/LicensesView.swift`

## Content licensing (§8.3) — attribution screen required before shipping content

- [ ] JMdict/EDICT & KANJIDIC2 — EDRDG licence (CC BY-SA 4.0 framework); dedicated Licenses & Sources screen; keep dictionary data in separate tables
- [ ] KRADFILE — EDRDG licence
- [ ] Kanjium — attribute per README (pitch data by Uros O.) + upstream EDRDG attributions
- [ ] Tatoeba — CC-BY, attribute Tatoeba.org
- [ ] Sudachi + SudachiDict — Apache-2.0 notice
- [ ] TTS-generated audio — record provider terms version here when caching begins
