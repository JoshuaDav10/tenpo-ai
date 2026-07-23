# Pingo teardown — the base experience to emulate + improve

From Joshua's screen recording (2026-07-23, ~8.5 min shopping/counting lesson) +
exported transcript. "The base experience, pretty much the same every round."

## The session UI (3 states)

1. **Voice screen (99% of the time):** near-empty. The 4-pill character mark
   (blue/yellow/pink/blue) animating with the voice, centered. One hint line:
   **"Tap to interrupt, hold to pause."** `?` (help) top-left, `✕` (end)
   top-right. A **"Transcript ^"** pull-up tab at the bottom. NO bubbles, no
   study cards, no status clutter during the conversation — pure voice.
2. **Transcript sheet (pull up):** chat bubbles — Pingo gray/left, You pink/right.
   Each Pingo bubble has three controls: **translate (文A)**, **font size (A)**,
   **replay audio (🔊)**. User bubbles show the Japanese **plus romaji reading**
   underneath, and when corrected, show what you said vs the target. **Export**
   button up top.
3. **Completion screen:** full-bleed color (blue), the character mark bursts into
   a ring of orbiting dots (celebration), **"Congrats Joshua"** + **"[topic]
   complete!"** (e.g. "Count and confirm amounts complete!").

## The round structure (this IS our four-act arc — we already have it)

1. **Warm-up on known material** (= our weak-item weaving, but framed as review):
   "Let's warm up with something you know / you've already practiced. How would
   you ask '…' in Japanese?" → attempt → recast if wrong → repeat until right.
2. **Transition:** "Now we're ready to dive into today's new phrases about …"
3. **Teach new phrases, one at a time, with breakdowns:** models the phrase, then
   decomposes it — "これは (kore wa) = 'this is', 千円 (sen en) = '1000 yen', です
   makes it polite" — then "repeat after me." Patient recasting across multiple
   attempts, never blocks.
4. **Teach a pattern/concept:** counters ひとつ/ふたつ, each modeled + repeated.
5. **Build into a request:** combine into これをふたつください, correcting specific
   errors ("use を instead of は, say ふたつ instead of 二つ").
6. **Recap:** "Now you know how to say one item ひとつ and two items ふたつ."
7. **Roleplay finale:** "Let's head into a roleplay. Imagine you're at a shop…
   I'll play the shopkeeper." Uses the taught phrases in context; the AI plays a
   character in Japanese (店員: 合計は2000円です) and prompts reactions.

## What Pingo does WELL (match these)

- **Granular breakdowns** of every new phrase (word-by-word gloss + role).
- **Patient recasting**: "Good try / Good effort / That's getting closer / Let's
  slow it down" then re-model. Never "wrong", never blocks, many attempts.
- **Targeted error correction**: names the exact fix (particle, counter form).
- **Recaps** after each concept; **natural transitions** between acts.
- **Personalization** by name ("Joshua").
- **Voice-first, zero-clutter UI**; transcript + per-line replay/translate on demand.
- **Celebratory completion** tied to the lesson topic.

## Pingo's WEAKNESSES (visible in the transcript — our opportunities)

- **Rigid / repetitive**: "the same every round." Relentless drilling of the same
  phrases; when Joshua got frustrated ("二つください。二つください。二つください…") and
  even went META ("take note you can click these elements"), Pingo **ignored the
  human signal** and robotically continued its correction script. No adaptation
  to a bored/frustrated/disengaged learner.
- **Over-correction / pedantry**: corrected 二つ→ふたつ and は→を even when the
  learner was communicating fine — can feel nitpicky rather than encouraging flow.
- **STT mangling**: the recognizer badly mis-heard the learner ("金子ぎみみ",
  "Питация", "東京はいくらですか") and sometimes corrected against the mis-hear.
- **No sense of place**: no visible lesson length / progress / "where am I."
- **Grading inconsistency**: accepted 二つ (kanji) sometimes, rejected it others.

## MISSING from Pingo (Joshua says there are several — TBD, to capture from him)

_(Joshua to enumerate: what he hates + what's absent. Placeholder for his list.)_

## How our current build compares

- ✅ We already have the four-act arc (warm-up weave → teach/repeat → build →
  roleplay → debrief) in the conductor. Structurally we match.
- ✅ We have honest grading, weak-item weaving, pattern extrapolation (a moat
  Pingo lacks — Pingo teaches phrases, we teach generalizable patterns).
- ⚠️ Our session UI is more cluttered (study card + transcript bubbles + status
  all on-screen). Pingo's voice screen is empty except the character. **Decide:
  hide the bubbles/cards behind a pull-up transcript like Pingo?**
- ⚠️ Our steps are authored JSON templates rendered discretely. Pingo feels more
  fluid (breakdowns, recaps, natural recasting). **Decide: richer step templates
  vs. a more generative teaching-agent given a lesson plan.**
- ❌ We don't yet: adapt to a frustrated/meta learner, offer per-line
  replay/translate, show romaji readings in transcript, or export.
