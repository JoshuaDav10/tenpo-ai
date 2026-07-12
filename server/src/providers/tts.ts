// TTS capability (§4.3.2): ElevenLabs primary, OpenAI TTS fallback.
// The /tts route is cache-first (§4.3.1): curriculum audio is generated once and
// replayed free — these adapters only run on a cache miss.
//
// Data retention (§8.2): verify each provider's terms permit STORING and
// REDISTRIBUTING generated audio inside the app (ElevenLabs and OpenAI generally
// permit use of outputs). Record the terms version in COMPLIANCE.md when caching
// begins. `voice` is the provider voice id resolved client-side from the persona.

import {
  ProviderNotConfiguredError,
  ProviderError,
  type AdapterDeps,
  type ProviderSpec,
  type TtsAdapter,
  type TtsRequest,
  type TtsResult,
} from "./types.ts";

function elevenLabsTts(spec: ProviderSpec, deps: AdapterDeps): TtsAdapter {
  const key = deps.env.ELEVENLABS_API_KEY;
  if (!key) throw new ProviderNotConfiguredError("tts", "elevenlabs");
  // spec.model may be a default model id; "voice_map" in the routing table means
  // the voice is supplied per-request. Allow an explicit model id override.
  const modelId = spec.model && spec.model !== "voice_map" ? spec.model : "eleven_multilingual_v2";

  return {
    provider: "elevenlabs",
    async synthesize(req: TtsRequest): Promise<TtsResult> {
      const res = await deps.fetchImpl(
        `https://api.elevenlabs.io/v1/text-to-speech/${encodeURIComponent(req.voice)}`,
        {
          method: "POST",
          headers: { "xi-api-key": key, "content-type": "application/json", accept: "audio/mpeg" },
          body: JSON.stringify({ text: req.text, model_id: modelId }),
        },
      );
      if (!res.ok) throw new ProviderError("elevenlabs", res.status, `elevenlabs tts failed: ${res.status}`);
      const audio = new Uint8Array(await res.arrayBuffer());
      return { audio, contentType: "audio/mpeg", provider: "elevenlabs" };
    },
  };
}

function openaiTts(spec: ProviderSpec, deps: AdapterDeps): TtsAdapter {
  const key = deps.env.OPENAI_API_KEY;
  if (!key) throw new ProviderNotConfiguredError("tts", "openai");
  const model = spec.model || "tts-1";

  return {
    provider: "openai",
    async synthesize(req: TtsRequest): Promise<TtsResult> {
      const res = await deps.fetchImpl("https://api.openai.com/v1/audio/speech", {
        method: "POST",
        headers: { authorization: `Bearer ${key}`, "content-type": "application/json" },
        body: JSON.stringify({ model, voice: req.voice, input: req.text, response_format: "mp3" }),
      });
      if (!res.ok) throw new ProviderError("openai", res.status, `openai tts failed: ${res.status}`);
      const audio = new Uint8Array(await res.arrayBuffer());
      return { audio, contentType: "audio/mpeg", provider: "openai" };
    },
  };
}

export function defaultTtsAdapter(spec: ProviderSpec, deps: AdapterDeps): TtsAdapter {
  switch (spec.provider) {
    case "elevenlabs":
      return elevenLabsTts(spec, deps);
    case "openai":
      return openaiTts(spec, deps);
    default:
      throw new Error(`unknown tts provider: ${spec.provider}`);
  }
}
