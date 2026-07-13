import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { buildApp } from "../src/app.ts";
import { recordCost, usage, realtimeAdmission } from "../src/costMeter.ts";
import type { ProviderFactories, ProviderSpec, AdapterDeps } from "../src/providers/index.ts";

// All tests are hermetic: providers are injected, so no network and no real keys.

function fakeChat(): ProviderFactories["chat"] {
  return (spec: ProviderSpec) => ({
    provider: spec.provider,
    model: spec.model,
    async complete() {
      return { text: "こんにちは", provider: spec.provider, model: spec.model, inputTokens: 10, outputTokens: 5 };
    },
    async completeStructured() {
      return {
        text: "{}",
        structured: { scene_control: "continue" },
        provider: spec.provider,
        model: spec.model,
        inputTokens: 10,
        outputTokens: 5,
      };
    },
  });
}

test("healthz responds ok without auth", async () => {
  const app = buildApp({ logger: false });
  const res = await app.inject({ method: "GET", url: "/healthz" });
  assert.equal(res.statusCode, 200);
  assert.equal(res.json().status, "ok");
  await app.close();
});

test("/chat: missing template_id → 400, unknown template → 404", async () => {
  const app = buildApp({ logger: false, providers: { chat: fakeChat() } });
  assert.equal((await app.inject({ method: "POST", url: "/chat", payload: {} })).statusCode, 400);
  const unknown = await app.inject({ method: "POST", url: "/chat", payload: { template_id: "nope" } });
  assert.equal(unknown.statusCode, 404);
  await app.close();
});

test("/chat: content_gen renders server-side prompt and returns provider text", async () => {
  const app = buildApp({ logger: false, providers: { chat: fakeChat() } });
  const res = await app.inject({
    method: "POST",
    url: "/chat",
    payload: { template_id: "content_gen", variables: { item_type: "vocab", band: "N5", count: 3 } },
  });
  assert.equal(res.statusCode, 200);
  assert.equal(res.json().text, "こんにちは");
  await app.close();
});

test("/chat: director_turn uses the structured path", async () => {
  const app = buildApp({ logger: false, providers: { chat: fakeChat() } });
  const res = await app.inject({
    method: "POST",
    url: "/chat",
    payload: { template_id: "director_turn", variables: {}, messages: [{ role: "user", content: "はい" }] },
  });
  assert.equal(res.statusCode, 200);
  assert.deepEqual(res.json().structured, { scene_control: "continue" });
  await app.close();
});

test("missing provider key → 503 provider_not_configured (primary named)", async () => {
  // Default factories + empty env: the anthropic key is absent, so does openai's.
  const app = buildApp({ logger: false, env: {} });
  const res = await app.inject({
    method: "POST",
    url: "/chat",
    payload: { template_id: "content_gen", variables: { item_type: "vocab", band: "N5", count: 1 } },
  });
  assert.equal(res.statusCode, 503);
  assert.equal(res.json().error, "provider_not_configured");
  await app.close();
});

test("/tts is cache-first: identical requests hit the provider once", async () => {
  let calls = 0;
  const cacheDir = mkdtempSync(join(tmpdir(), "kizuna-tts-"));
  const tts: ProviderFactories["tts"] = (spec: ProviderSpec) => ({
    provider: spec.provider,
    async synthesize() {
      calls += 1;
      return { audio: new Uint8Array([1, 2, 3, 4]), contentType: "audio/mpeg", provider: spec.provider };
    },
  });
  const app = buildApp({ logger: false, providers: { tts }, ttsCacheDir: cacheDir });
  const payload = { text: "みず", voice: "ja-warm-tutor", locale: "ja-JP" };

  const first = await app.inject({ method: "POST", url: "/tts", payload });
  assert.equal(first.statusCode, 200);
  assert.equal(first.headers["x-cache"], "miss");

  const second = await app.inject({ method: "POST", url: "/tts", payload });
  assert.equal(second.statusCode, 200);
  assert.equal(second.headers["x-cache"], "hit");

  assert.equal(calls, 1, "provider should be called once; the replay is served from cache");
  await app.close();
});

test("usage returns per-user meter with caps", async () => {
  const app = buildApp({ logger: false });
  const res = await app.inject({ method: "GET", url: "/usage" });
  assert.equal(res.statusCode, 200);
  const body = res.json();
  // The meter is process-global; other tests may have spent for user "dev", so
  // assert structure/caps rather than an exact spend.
  assert.equal(typeof body.spentUSD, "number");
  assert.ok(body.spentUSD >= 0);
  assert.equal(body.overHardCap, false);
  assert.ok(body.softCapUSD > 0);
  await app.close();
});

test("realtimeAdmission gates the expensive Pipeline A by daily spend (§4.3.6)", () => {
  // Unique users so the process-global meter doesn't collide with other tests.
  const fresh = `rt-fresh-${Math.random()}`;
  const soft = `rt-soft-${Math.random()}`;
  const hard = `rt-hard-${Math.random()}`;

  // Below the soft cap: realtime voice is allowed.
  assert.deepEqual(realtimeAdmission(usage(fresh)), { allow: true });

  // At/over the soft cap (default $2.50): refuse realtime → client uses cheap cascade.
  recordCost(soft, 3.0);
  assert.deepEqual(realtimeAdmission(usage(soft)), { allow: false, reason: "cost_cheap_mode" });

  // At/over the hard cap (default $5.00): refuse with the drills-only reason.
  recordCost(hard, 6.0);
  assert.deepEqual(realtimeAdmission(usage(hard)), { allow: false, reason: "cost_hard_cap" });
});
