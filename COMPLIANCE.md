# COMPLIANCE.md

Record of privacy, App Store, and licensing decisions per ARCHITECTURE.md §8.
Update this file whenever a provider is wired up or a data-handling setting is chosen.

## Provider data-handling settings (§8.2)

| Provider | Purpose | Trains on API data? | Retention setting chosen | Terms version / date |
|---|---|---|---|---|
| Anthropic (Claude) | Director, evaluation, content gen | No (API default) | TBD at wiring | — |
| OpenAI (Realtime, TTS fallback) | Roleplay voice | No (API default) | TBD at wiring | — |
| Deepgram (Nova ja) | Server STT | TBD — review at wiring | TBD | — |
| Azure Speech | Pronunciation assessment | TBD — review at wiring | TBD | — |
| ElevenLabs | Curriculum TTS | TBD — verify output storage/redistribution license | TBD | — |

## Data minimization (D10)

- Raw audio clips are transient by default: transcript + grades retained, audio deleted after grading.
- User opt-in required to retain recordings.

## App Store checklist (§8.1) — complete before TestFlight

- [ ] Third-party AI consent screen (Guideline 5.1.2(i)) naming all providers; consent record stored
- [ ] Age rating questionnaire — target 13+, declare AI chatbot functionality
- [ ] `PrivacyInfo.xcprivacy` manifest (audio, user content, identifiers) + dependency audit
- [ ] Privacy nutrition label matches reality
- [ ] Mic + speech recognition permission strings (already in project.yml)
- [ ] In-app account deletion + data export

## Content licensing (§8.3) — attribution screen required before shipping content

- [ ] JMdict/EDICT & KANJIDIC2 — EDRDG licence (CC BY-SA 4.0 framework); dedicated Licenses & Sources screen; keep dictionary data in separate tables
- [ ] KRADFILE — EDRDG licence
- [ ] Kanjium — attribute per README (pitch data by Uros O.) + upstream EDRDG attributions
- [ ] Tatoeba — CC-BY, attribute Tatoeba.org
- [ ] Sudachi + SudachiDict — Apache-2.0 notice
- [ ] TTS-generated audio — record provider terms version here when caching begins
