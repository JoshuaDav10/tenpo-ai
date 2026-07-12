// Cost price table (§4.3.6) — SINGLE source of truth for the cost meter.
//
// ⚠️ VERIFY AT BUILD TIME (§12): provider catalogs and prices change quarterly.
// These are placeholder rates as of authoring; confirm current pricing before
// relying on the caps. All rates in USD.

// Chat: USD per token (input / output). Keyed by model id (routing tail).
const CHAT_PRICES: Record<string, { input: number; output: number }> = {
  // Anthropic (per 1M tokens): sonnet 4.6 $3/$15, sonnet 5 $3/$15, opus 4.8 $5/$25
  "claude-sonnet-4-6": { input: 3 / 1e6, output: 15 / 1e6 },
  "claude-sonnet-5": { input: 3 / 1e6, output: 15 / 1e6 },
  "claude-opus-4-8": { input: 5 / 1e6, output: 25 / 1e6 },
  // OpenAI fallback (per 1M tokens): gpt-4.1-mini ~ $0.40/$1.60
  "gpt-4.1-mini": { input: 0.4 / 1e6, output: 1.6 / 1e6 },
};
const DEFAULT_CHAT_PRICE = { input: 3 / 1e6, output: 15 / 1e6 };

export function chatCostUSD(model: string, inputTokens: number, outputTokens: number): number {
  const p = CHAT_PRICES[model] ?? DEFAULT_CHAT_PRICE;
  return inputTokens * p.input + outputTokens * p.output;
}

// STT: USD per audio-second, by provider.
const STT_PRICE_PER_SEC: Record<string, number> = {
  deepgram: 0.0043 / 60, // ~$0.0043 / minute (Nova)
  openai: 0.006 / 60, // whisper-1 $0.006 / minute
};
export function sttCostUSD(provider: string, seconds: number): number {
  return (STT_PRICE_PER_SEC[provider] ?? 0.005 / 60) * seconds;
}

// TTS: USD per character, by provider. Cache hits cost 0 (metered in the route).
const TTS_PRICE_PER_CHAR: Record<string, number> = {
  elevenlabs: 0.0003, // ~$0.30 / 1k chars (plan-dependent)
  openai: 15 / 1e6, // tts-1 $15 / 1M chars
};
export function ttsCostUSD(provider: string, chars: number): number {
  return (TTS_PRICE_PER_CHAR[provider] ?? 0.0003) * chars;
}

// Pron: USD per audio-second (Azure Speech ~ $1 / audio-hour).
const PRON_PRICE_PER_SEC = 1 / 3600;
export function pronCostUSD(_provider: string, seconds: number): number {
  return PRON_PRICE_PER_SEC * seconds;
}

// Rough audio-seconds estimate when a provider doesn't report duration.
// Assumes 16 kHz, 16-bit mono PCM (~32 kB/s). Metering only — not exact.
export function estimateAudioSeconds(byteLength: number): number {
  return byteLength / 32000;
}
