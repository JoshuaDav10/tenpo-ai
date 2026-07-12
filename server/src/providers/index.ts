// Provider registry (§4.3.3). Each capability maps a parsed provider:model spec
// to a typed adapter. Factories are overridable for hermetic tests (inject fakes
// so no network / no real keys are needed).

import { defaultChatAdapter } from "./chat.ts";
import { defaultSttAdapter } from "./stt.ts";
import { defaultTtsAdapter } from "./tts.ts";
import { defaultPronAdapter } from "./pron.ts";
import type {
  AdapterDeps,
  ChatAdapter,
  PronAdapter,
  ProviderSpec,
  SttAdapter,
  TtsAdapter,
} from "./types.ts";

export interface ProviderFactories {
  chat: (spec: ProviderSpec, deps: AdapterDeps) => ChatAdapter;
  stt: (spec: ProviderSpec, deps: AdapterDeps) => SttAdapter;
  tts: (spec: ProviderSpec, deps: AdapterDeps) => TtsAdapter;
  pron: (spec: ProviderSpec, deps: AdapterDeps) => PronAdapter;
}

export function defaultFactories(): ProviderFactories {
  return {
    chat: defaultChatAdapter,
    stt: defaultSttAdapter,
    tts: defaultTtsAdapter,
    pron: defaultPronAdapter,
  };
}

export * from "./types.ts";
