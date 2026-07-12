import Fastify, { type FastifyInstance, type FastifyReply } from "fastify";
import { fileURLToPath } from "node:url";
import { authenticate } from "./auth.ts";
import { route as routeFor, type Route } from "./providerRouter.ts";
import { recordCost, usage } from "./costMeter.ts";
import { getTemplate } from "./prompts/index.ts";
import { chatCostUSD, sttCostUSD, ttsCostUSD, pronCostUSD, estimateAudioSeconds } from "./pricing.ts";
import { ttsCacheKey, readTtsCache, writeTtsCache } from "./ttsCache.ts";
import { defaultFactories, type ProviderFactories } from "./providers/index.ts";
import {
  ProviderNotConfiguredError,
  parseSpec,
  type AdapterDeps,
  type ChatMessage,
} from "./providers/types.ts";

// Real provider integrations (§4.3/§4.4/§7). Routes preserve auth + cost
// metering. Providers are injectable so tests are hermetic (no network/keys).

export interface AppOptions {
  logger?: boolean;
  env?: Record<string, string | undefined>;
  fetchImpl?: typeof fetch;
  providers?: Partial<ProviderFactories>;
  ttsCacheDir?: string;
}

const DEFAULT_TTS_CACHE_DIR = fileURLToPath(new URL("../.cache/tts", import.meta.url));

export function buildApp(opts: AppOptions = {}): FastifyInstance {
  const app = Fastify({ logger: opts.logger ?? true, bodyLimit: 25 * 1024 * 1024 });

  const factories: ProviderFactories = { ...defaultFactories(), ...opts.providers };
  const deps: AdapterDeps = { env: opts.env ?? process.env, fetchImpl: opts.fetchImpl ?? fetch };
  const ttsCacheDir = opts.ttsCacheDir ?? DEFAULT_TTS_CACHE_DIR;

  // Try primary, then fallback (§4.3.3). A missing key (ProviderNotConfigured)
  // skips to the fallback; a runtime provider error also falls back. The first
  // not-configured error is kept so a total miss reports the PRIMARY provider.
  // NEVER interrupt/kill work mid-request (R13).
  async function runWithFallback<T>(
    cap: string,
    r: Route,
    make: (spec: ReturnType<typeof parseSpec>) => T,
    invoke: (adapter: T, provider: string) => Promise<unknown>,
  ): Promise<unknown> {
    const raws = [r.primary, r.fallback].filter((x): x is string => Boolean(x));
    let firstConfigErr: ProviderNotConfiguredError | undefined;
    for (let i = 0; i < raws.length; i++) {
      const spec = parseSpec(raws[i]);
      let adapter: T;
      try {
        adapter = make(spec);
      } catch (err) {
        if (err instanceof ProviderNotConfiguredError) {
          if (!firstConfigErr) firstConfigErr = err;
          continue;
        }
        throw err;
      }
      try {
        const result = await invoke(adapter, spec.provider);
        if (i > 0) app.log.warn({ capability: cap, provider: spec.provider }, "used fallback provider");
        return result;
      } catch (err) {
        if (i < raws.length - 1) {
          app.log.warn({ capability: cap, provider: spec.provider }, "primary provider failed, trying fallback");
          continue;
        }
        throw err;
      }
    }
    throw firstConfigErr ?? new Error(`no route for capability: ${cap}`);
  }

  function handleProviderError(err: unknown, reply: FastifyReply, cap: string) {
    if (err instanceof ProviderNotConfiguredError) {
      return reply.code(503).send({ error: "provider_not_configured", capability: cap, provider: err.provider });
    }
    // Never log secrets — ProviderError messages carry only status codes.
    app.log.error({ capability: cap, err: String(err) }, "provider call failed");
    return reply.code(502).send({ error: "provider_error", capability: cap });
  }

  app.get("/healthz", async () => ({ status: "ok", service: "kizuna-proxy", version: "0.1.0" }));

  app.register(async (authed) => {
    authed.addHook("preHandler", authenticate);

    // POST /chat — Director + content gen (§4.4). Server-side prompt templates
    // by id; the client never sees prompt text (§7).
    authed.post("/chat", async (req, reply) => {
      const body = (req.body ?? {}) as { template_id?: string; variables?: Record<string, unknown>; messages?: ChatMessage[] };
      if (!body.template_id) return reply.code(400).send({ error: "missing_template_id" });
      const template = getTemplate(body.template_id);
      if (!template) return reply.code(404).send({ error: "unknown_template", template_id: body.template_id });

      // Cost caps (§4.3.6): the hard cap blocks new non-drill work; active
      // sessions are never interrupted (R13).
      const u = usage(req.userId);
      if (u.overHardCap && template.kind !== "drill") {
        return reply.code(429).send({
          error: "cost_hard_cap",
          note: "Daily hard cap reached; only drill work permitted. Active sessions are never interrupted (R13).",
        });
      }
      // TODO(§4.3.6 cheap-mode): when u.overSoftCap, roleplay should switch to
      // Pipeline B cheap mode (STT→Claude→cached-voice TTS). The /chat text path
      // does not yet need cheap-mode switching — hook lands with RealtimeKit.

      let rendered;
      try {
        rendered = template.render(body.variables ?? {}, body.messages ?? []);
      } catch (err) {
        return reply.code(400).send({ error: "template_render_failed", detail: String(err) });
      }

      try {
        const result = (await runWithFallback(
          "chat",
          routeFor("chat"),
          (spec) => factories.chat(spec, deps),
          (adapter) =>
            rendered.structured
              ? adapter.completeStructured(
                  { system: rendered.system, messages: rendered.messages, maxTokens: rendered.maxTokens },
                  rendered.structured,
                )
              : adapter.complete({ system: rendered.system, messages: rendered.messages, maxTokens: rendered.maxTokens }),
        )) as import("./providers/types.ts").ChatResult;

        recordCost(req.userId, chatCostUSD(result.model, result.inputTokens, result.outputTokens));
        return {
          text: result.text,
          provider: result.provider,
          inputTokens: result.inputTokens,
          outputTokens: result.outputTokens,
          ...(result.structured !== undefined ? { structured: result.structured } : {}),
        };
      } catch (err) {
        return handleProviderError(err, reply, "chat");
      }
    });

    // POST /stt — server pass of the grading cascade (§4.3.4). Body:
    // {audio: base64, locale?, hints?}. Returns {text, confidence, alternatives, provider}.
    authed.post("/stt", async (req, reply) => {
      const body = (req.body ?? {}) as { audio?: string; locale?: string; hints?: string[] };
      if (!body.audio) return reply.code(400).send({ error: "missing_audio" });
      const audio = Buffer.from(body.audio, "base64");
      try {
        const result = (await runWithFallback(
          "stt",
          routeFor("stt"),
          (spec) => factories.stt(spec, deps),
          (adapter) => adapter.transcribe({ audio, locale: body.locale ?? "ja-JP", hints: body.hints ?? [] }),
        )) as import("./providers/types.ts").SttResult;

        const seconds = result.durationSeconds ?? estimateAudioSeconds(audio.byteLength);
        recordCost(req.userId, sttCostUSD(result.provider, seconds));
        return {
          text: result.text,
          confidence: result.confidence,
          alternatives: result.alternatives,
          provider: result.provider,
        };
      } catch (err) {
        return handleProviderError(err, reply, "stt");
      }
    });

    // POST /tts — cache-first curriculum audio (§4.3.1). Body: {text, voice, locale?}.
    // Returns binary audio; X-Cache: hit|miss, X-Provider header. Cached replays are free.
    authed.post("/tts", async (req, reply) => {
      const body = (req.body ?? {}) as { text?: string; voice?: string; locale?: string };
      if (!body.text || !body.voice) return reply.code(400).send({ error: "missing_text_or_voice" });
      const locale = body.locale ?? "ja-JP";
      const key = ttsCacheKey(body.text, body.voice, locale);

      const cached = await readTtsCache(ttsCacheDir, key);
      if (cached) {
        reply.header("X-Cache", "hit").header("X-Provider", "cache");
        return reply.type(cached.contentType).send(cached.audio);
      }

      try {
        const result = (await runWithFallback(
          "tts",
          routeFor("tts"),
          (spec) => factories.tts(spec, deps),
          (adapter) => adapter.synthesize({ text: body.text!, voice: body.voice!, locale }),
        )) as import("./providers/types.ts").TtsResult;

        await writeTtsCache(ttsCacheDir, key, result.audio, result.contentType);
        recordCost(req.userId, ttsCostUSD(result.provider, body.text.length));
        reply.header("X-Cache", "miss").header("X-Provider", result.provider);
        return reply.type(result.contentType).send(Buffer.from(result.audio));
      } catch (err) {
        return handleProviderError(err, reply, "tts");
      }
    });

    // POST /pron — Azure Pronunciation Assessment (§4.3.2). Body:
    // {audio: base64, referenceText, locale?}.
    authed.post("/pron", async (req, reply) => {
      const body = (req.body ?? {}) as { audio?: string; referenceText?: string; locale?: string };
      if (!body.audio || !body.referenceText) return reply.code(400).send({ error: "missing_audio_or_reference" });
      const audio = Buffer.from(body.audio, "base64");
      try {
        const result = (await runWithFallback(
          "pron",
          routeFor("pron"),
          (spec) => factories.pron(spec, deps),
          (adapter) => adapter.assess({ audio, referenceText: body.referenceText!, locale: body.locale ?? "ja-JP" }),
        )) as import("./providers/types.ts").PronResult;

        const seconds = result.durationSeconds ?? estimateAudioSeconds(audio.byteLength);
        recordCost(req.userId, pronCostUSD(result.provider, seconds));
        return {
          overall: result.overall,
          fluency: result.fluency,
          prosody: result.prosody,
          phonemes: result.phonemes,
          provider: result.provider,
        };
      } catch (err) {
        return handleProviderError(err, reply, "pron");
      }
    });

    // Cost meter (§4.3.6) — the dashboard's dogfood cost display reads this.
    authed.get("/usage", async (req) => usage(req.userId));
  });

  return app;
}
