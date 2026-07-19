// One-time TTS pre-generation (docs/COSTING_RESEARCH.md "audio capex"): walk the
// authored seed, synthesize every predictable line ONCE through the provider
// adapters, and fill the server's cache-first TTS store. After a run, drill and
// lesson audio replays at $0 — only live conversation stays metered.
//
// Run WHERE THE PROVIDER KEYS LIVE:
//   locally:  cd server && node --env-file=.env tools/pregen_tts.ts --dry-run
//   on Fly:   fly ssh console -C "node tools/pregen_tts.ts"
// --dry-run prints the manifest + estimated character spend without synthesizing.
// Idempotent: cached keys are skipped, so re-runs only pay for NEW content.

import { promises as fs } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { ttsCacheKey, readTtsCache, writeTtsCache } from "../src/ttsCache.ts";

interface Line {
  text: string;
  source: string; // which seed surface produced it (for the report)
}

/** Every predictable Japanese line in the seed: vocab lemmas+kana, sentences,
 * lesson targets/questions/phrases, pattern examples+probe answers. Pure. */
export function collectLines(seed: {
  vocab?: unknown[];
  sentences?: unknown[];
  lessons?: unknown[];
  patterns?: unknown[];
}): Line[] {
  const lines: Line[] = [];
  const push = (text: unknown, source: string) => {
    if (typeof text === "string" && text.trim().length > 0) {
      lines.push({ text: text.trim(), source });
    }
  };

  for (const raw of seed.vocab ?? []) {
    const v = raw as Record<string, unknown>;
    push(v.lemma, "vocab");
  }
  for (const raw of seed.sentences ?? []) {
    const s = raw as Record<string, unknown>;
    push(s.ja ?? s.full, "sentence");
  }
  for (const raw of seed.lessons ?? []) {
    const lesson = raw as { steps?: Record<string, unknown>[] };
    for (const step of lesson.steps ?? []) {
      push(step.target, "lesson");
      push(step.question_jp, "lesson");
      push(step.phrase_jp, "lesson");
      for (const probe of (step.probes as Record<string, unknown>[] | undefined) ?? []) {
        push(probe.phrase_jp, "lesson");
        push((probe.accepted as string[] | undefined)?.[0], "lesson");
      }
      for (const ex of (step.examples as Record<string, unknown>[] | undefined) ?? []) {
        push(ex.jp, "lesson");
      }
    }
  }
  for (const raw of seed.patterns ?? []) {
    const p = raw as { examples?: Record<string, unknown>[]; probes?: Record<string, unknown>[] };
    for (const ex of p.examples ?? []) push(ex.jp, "pattern");
    for (const probe of p.probes ?? []) {
      push(probe.phrase_jp, "pattern");
      push((probe.accepted as string[] | undefined)?.[0], "pattern");
    }
  }

  // Dedupe by text — identical lines share one cache entry anyway.
  const seen = new Set<string>();
  return lines.filter((l) => (seen.has(l.text) ? false : (seen.add(l.text), true)));
}

async function loadSeed(seedDir: string) {
  const read = async (name: string): Promise<unknown[]> => {
    try {
      const parsed = JSON.parse(await fs.readFile(path.join(seedDir, name), "utf8")) as { items?: unknown[] };
      return parsed.items ?? [];
    } catch {
      return [];
    }
  };
  return {
    vocab: await read("vocab_n5.json"),
    sentences: await read("sentences_n5.json"),
    lessons: await read("lessons_n5.json"),
    patterns: await read("patterns_n5.json"),
  };
}

async function main() {
  const dryRun = process.argv.includes("--dry-run");
  const here = path.dirname(fileURLToPath(import.meta.url));
  const seedDir = path.resolve(here, "../../tools/seed");
  const cacheDir = path.resolve(here, "../.cache/tts");
  const voice = process.env.PREGEN_VOICE ?? "voice_map";
  const locale = "ja-JP";

  const lines = collectLines(await loadSeed(seedDir));
  const chars = lines.reduce((sum, l) => sum + l.text.length, 0);
  console.log(`pregen manifest: ${lines.length} unique lines, ${chars} chars`);
  console.log(`  (~$${((chars / 1000) * 0.1).toFixed(2)} at ElevenLabs rates, ~$${((chars / 1e6) * 15).toFixed(2)} at OpenAI rates)`);

  if (dryRun) {
    for (const line of lines.slice(0, 10)) console.log(`  ${line.source}: ${line.text}`);
    if (lines.length > 10) console.log(`  … and ${lines.length - 10} more`);
    return;
  }

  // Late imports so --dry-run needs no provider config.
  const { route } = await import("../src/providerRouter.ts");
  const { parseSpec } = await import("../src/providers/types.ts");
  const { defaultTtsAdapter } = await import("../src/providers/tts.ts");

  const deps = { env: process.env, fetchImpl: fetch };
  const ttsRoute = route("tts");
  const specs = [ttsRoute.primary, ttsRoute.fallback]
    .filter((s): s is string => Boolean(s))
    .map(parseSpec);
  let done = 0;
  let skipped = 0;
  let failed = 0;
  for (const line of lines) {
    const key = ttsCacheKey(line.text, voice, locale);
    if (await readTtsCache(cacheDir, key)) {
      skipped++;
      continue;
    }
    let ok = false;
    for (const spec of specs) {
      try {
        const adapter = defaultTtsAdapter(spec, deps);
        const result = await adapter.synthesize({ text: line.text, voice, locale });
        await writeTtsCache(cacheDir, key, result.audio, result.contentType);
        ok = true;
        break;
      } catch {
        continue;
      }
    }
    ok ? done++ : failed++;
    if ((done + failed) % 25 === 0) console.log(`  ${done} synthesized, ${skipped} cached, ${failed} failed`);
  }
  console.log(`pregen complete: ${done} synthesized, ${skipped} already cached, ${failed} failed`);
}

const isDirectRun = process.argv[1] && import.meta.url === new URL(`file://${path.resolve(process.argv[1])}`).href;
if (isDirectRun) {
  main().catch((err) => {
    console.error(err);
    process.exit(1);
  });
}
