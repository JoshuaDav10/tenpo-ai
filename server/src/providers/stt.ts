// STT capability (§4.3.2): Deepgram Nova (ja) primary, OpenAI whisper fallback.
// Grading code consults `confidence` (R5/R6) — always populated, honestly.
//
// Data retention (§8.2): Deepgram — set project data-logging OFF (default may
// retain for model improvement); OpenAI API — no training on API data by default.
//
// The routing tail is the provider's model id. Deepgram's Japanese is served by
// a Nova model with `language=ja`; the spec's "nova-ja" is illustrative — set a
// real Deepgram model id (e.g. "nova-2") in config/providers.json to go live.

import {
  ProviderNotConfiguredError,
  ProviderError,
  type AdapterDeps,
  type ProviderSpec,
  type SttAdapter,
  type SttRequest,
  type SttResult,
} from "./types.ts";

function deepgramStt(spec: ProviderSpec, deps: AdapterDeps): SttAdapter {
  const key = deps.env.DEEPGRAM_API_KEY;
  if (!key) throw new ProviderNotConfiguredError("stt", "deepgram");
  const model = spec.model || "nova-2";

  return {
    provider: "deepgram",
    async transcribe(req: SttRequest): Promise<SttResult> {
      const params = new URLSearchParams({ model, language: req.locale.slice(0, 2), smart_format: "true" });
      for (const h of req.hints) params.append("keyterm", h);
      const res = await deps.fetchImpl(`https://api.deepgram.com/v1/listen?${params.toString()}`, {
        method: "POST",
        headers: { authorization: `Token ${key}`, "content-type": "application/octet-stream" },
        body: req.audio,
      });
      if (!res.ok) throw new ProviderError("deepgram", res.status, `deepgram stt failed: ${res.status}`);
      const data = (await res.json()) as {
        metadata?: { duration?: number };
        results?: { channels?: { alternatives?: { transcript?: string; confidence?: number }[] }[] };
      };
      const alts = data.results?.channels?.[0]?.alternatives ?? [];
      const best = alts[0];
      return {
        text: best?.transcript ?? "",
        confidence: best?.confidence ?? 0,
        alternatives: alts.map((a) => a.transcript ?? "").filter(Boolean),
        provider: "deepgram",
        durationSeconds: data.metadata?.duration,
      };
    },
  };
}

function openaiWhisperStt(spec: ProviderSpec, deps: AdapterDeps): SttAdapter {
  const key = deps.env.OPENAI_API_KEY;
  if (!key) throw new ProviderNotConfiguredError("stt", "openai");
  const model = spec.model || "whisper-1";

  return {
    provider: "openai",
    async transcribe(req: SttRequest): Promise<SttResult> {
      const form = new FormData();
      form.append("file", new Blob([req.audio]), "audio.wav");
      form.append("model", model);
      form.append("language", req.locale.slice(0, 2));
      if (req.hints.length) form.append("prompt", req.hints.join(", "));
      const res = await deps.fetchImpl("https://api.openai.com/v1/audio/transcriptions", {
        method: "POST",
        headers: { authorization: `Bearer ${key}` },
        body: form,
      });
      if (!res.ok) throw new ProviderError("openai", res.status, `openai whisper failed: ${res.status}`);
      const data = (await res.json()) as { text?: string };
      const text = data.text ?? "";
      // whisper-1 does not return a confidence score. Report a conservative
      // fixed value so grading (R6) requires a second ASR opinion before failing.
      return { text, confidence: 0.9, alternatives: text ? [text] : [], provider: "openai" };
    },
  };
}

export function defaultSttAdapter(spec: ProviderSpec, deps: AdapterDeps): SttAdapter {
  switch (spec.provider) {
    case "deepgram":
      return deepgramStt(spec, deps);
    case "openai":
      return openaiWhisperStt(spec, deps);
    default:
      throw new Error(`unknown stt provider: ${spec.provider}`);
  }
}
