// Provider adapter layer (§4.3.2). One small typed interface per capability.
// Adapters are selected by the routing table's provider:model strings
// (e.g. "anthropic:claude-sonnet-4-6", "deepgram:nova-ja") and read their key
// from env. A missing key throws ProviderNotConfiguredError → the route returns
// HTTP 503 without crashing the process. Secrets are NEVER logged or echoed.
//
// NOTE (type stripping): this file must stay erasable-syntax only — no enums,
// no `namespace`, no parameter properties. Node runs the .ts directly.

export type Capability = "chat" | "stt" | "tts" | "pron";

/** Thrown at adapter construction when the required env key is absent. */
export class ProviderNotConfiguredError extends Error {
  capability: string;
  provider: string;
  constructor(capability: string, provider: string) {
    super(`provider_not_configured:${provider}`);
    this.name = "ProviderNotConfiguredError";
    this.capability = capability;
    this.provider = provider;
  }
}

/** Thrown when an upstream provider returns a non-2xx (never carries secrets). */
export class ProviderError extends Error {
  provider: string;
  status: number;
  constructor(provider: string, status: number, message: string) {
    super(message);
    this.name = "ProviderError";
    this.provider = provider;
    this.status = status;
  }
}

export interface ProviderSpec {
  provider: string; // "anthropic", "openai", "deepgram", "elevenlabs", "azure"
  model: string; // tail of the routing string; adapter-interpreted
  raw: string; // original "provider:model" string
}

/** Parse a routing-table entry ("anthropic:claude-sonnet-4-6") into its parts. */
export function parseSpec(raw: string): ProviderSpec {
  const i = raw.indexOf(":");
  if (i < 0) return { provider: raw, model: "", raw };
  return { provider: raw.slice(0, i), model: raw.slice(i + 1), raw };
}

export interface AdapterDeps {
  env: Record<string, string | undefined>;
  fetchImpl: typeof fetch;
}

// ---- chat ----------------------------------------------------------------

export interface ChatMessage {
  role: "user" | "assistant" | "system";
  content: string;
}

export interface ChatRequest {
  system?: string;
  messages: ChatMessage[];
  maxTokens?: number;
}

/** JSON-schema constraint for the structured (tool-use / JSON-mode) path. */
export interface StructuredSpec {
  name: string;
  description?: string;
  schema: Record<string, unknown>;
}

export interface ChatResult {
  text: string;
  structured?: unknown;
  provider: string;
  model: string;
  inputTokens: number;
  outputTokens: number;
}

export interface ChatAdapter {
  provider: string;
  model: string;
  complete(req: ChatRequest): Promise<ChatResult>;
  completeStructured(req: ChatRequest, spec: StructuredSpec): Promise<ChatResult>;
}

// ---- stt ------------------------------------------------------------------

export interface SttRequest {
  audio: Uint8Array;
  locale: string;
  hints: string[]; // expected answer(s) — bias recognition (R5/R6)
}

export interface SttResult {
  text: string;
  confidence: number;
  alternatives: string[];
  provider: string;
  durationSeconds?: number; // for audio-seconds cost metering when known
}

export interface SttAdapter {
  provider: string;
  transcribe(req: SttRequest): Promise<SttResult>;
}

// ---- tts ------------------------------------------------------------------

export interface TtsRequest {
  text: string;
  voice: string;
  locale: string;
}

export interface TtsResult {
  audio: Uint8Array;
  contentType: string;
  provider: string;
}

export interface TtsAdapter {
  provider: string;
  synthesize(req: TtsRequest): Promise<TtsResult>;
}

// ---- pron -----------------------------------------------------------------

export interface PronPhoneme {
  phoneme: string;
  score: number;
}

export interface PronRequest {
  audio: Uint8Array;
  referenceText: string;
  locale: string;
}

export interface PronResult {
  overall: number;
  fluency?: number;
  prosody?: number;
  phonemes: PronPhoneme[];
  provider: string;
  durationSeconds?: number;
}

export interface PronAdapter {
  provider: string;
  assess(req: PronRequest): Promise<PronResult>;
}
