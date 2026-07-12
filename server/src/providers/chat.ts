// Chat capability (§4.3.2): Anthropic Claude primary, OpenAI fallback.
//
// Model id comes from the routing table (e.g. "anthropic:claude-sonnet-4-6"),
// so it is swappable without code changes (§4.3.3). Per the claude-api skill,
// claude-sonnet-4-6 is a current, active model (matches Decision D4); current-
// generation alternatives (claude-sonnet-5, claude-opus-4-8) are a one-line
// edit to config/providers.json. The Anthropic Messages API is
// POST /v1/messages with header anthropic-version (default 2023-06-01).
//
// Structured output uses forced tool-use (Claude tool_use JSON mode). We do NOT
// use output_config.format because it is not supported on claude-sonnet-4-6 —
// forced tool-use works across the Claude family and the OpenAI fallback alike.
//
// Data retention (§8.2): Anthropic and OpenAI do not train on API inputs/outputs
// by default. Request zero-data-retention where eligible; no logging changes here.

import {
  ProviderNotConfiguredError,
  ProviderError,
  type AdapterDeps,
  type ChatAdapter,
  type ChatRequest,
  type ChatResult,
  type ProviderSpec,
  type StructuredSpec,
} from "./types.ts";

const ANTHROPIC_URL = "https://api.anthropic.com/v1/messages";
const OPENAI_URL = "https://api.openai.com/v1/chat/completions";

function splitSystem(req: ChatRequest): { system?: string; msgs: { role: "user" | "assistant"; content: string }[] } {
  const sys = [req.system, ...req.messages.filter((m) => m.role === "system").map((m) => m.content)]
    .filter(Boolean)
    .join("\n\n");
  const msgs = req.messages
    .filter((m) => m.role !== "system")
    .map((m) => ({ role: m.role as "user" | "assistant", content: m.content }));
  return { system: sys || undefined, msgs };
}

// ---- Anthropic -----------------------------------------------------------

function anthropicChat(spec: ProviderSpec, deps: AdapterDeps): ChatAdapter {
  const key = deps.env.ANTHROPIC_API_KEY;
  if (!key) throw new ProviderNotConfiguredError("chat", "anthropic");
  const version = deps.env.ANTHROPIC_API_VERSION ?? "2023-06-01";
  const model = spec.model;

  async function call(body: Record<string, unknown>) {
    const res = await deps.fetchImpl(ANTHROPIC_URL, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-api-key": key,
        "anthropic-version": version,
      },
      body: JSON.stringify(body),
    });
    if (!res.ok) throw new ProviderError("anthropic", res.status, `anthropic chat failed: ${res.status}`);
    return (await res.json()) as {
      content: { type: string; text?: string; input?: unknown }[];
      usage: { input_tokens: number; output_tokens: number };
    };
  }

  return {
    provider: "anthropic",
    model,
    async complete(req) {
      const { system, msgs } = splitSystem(req);
      const data = await call({
        model,
        max_tokens: req.maxTokens ?? 1024,
        ...(system ? { system } : {}),
        messages: msgs,
      });
      const text = data.content.filter((b) => b.type === "text").map((b) => b.text ?? "").join("");
      return {
        text,
        provider: "anthropic",
        model,
        inputTokens: data.usage.input_tokens,
        outputTokens: data.usage.output_tokens,
      };
    },
    async completeStructured(req, structured: StructuredSpec): Promise<ChatResult> {
      const { system, msgs } = splitSystem(req);
      const data = await call({
        model,
        max_tokens: req.maxTokens ?? 1024,
        ...(system ? { system } : {}),
        messages: msgs,
        tools: [
          {
            name: structured.name,
            description: structured.description ?? "Emit the structured result as JSON.",
            input_schema: structured.schema,
          },
        ],
        tool_choice: { type: "tool", name: structured.name },
      });
      const toolUse = data.content.find((b) => b.type === "tool_use");
      const value = toolUse?.input;
      return {
        text: JSON.stringify(value ?? null),
        structured: value,
        provider: "anthropic",
        model,
        inputTokens: data.usage.input_tokens,
        outputTokens: data.usage.output_tokens,
      };
    },
  };
}

// ---- OpenAI (fallback) ---------------------------------------------------

function openaiChat(spec: ProviderSpec, deps: AdapterDeps): ChatAdapter {
  const key = deps.env.OPENAI_API_KEY;
  if (!key) throw new ProviderNotConfiguredError("chat", "openai");
  const model = spec.model;

  async function call(body: Record<string, unknown>) {
    const res = await deps.fetchImpl(OPENAI_URL, {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Bearer ${key}` },
      body: JSON.stringify(body),
    });
    if (!res.ok) throw new ProviderError("openai", res.status, `openai chat failed: ${res.status}`);
    return (await res.json()) as {
      choices: { message: { content: string | null; tool_calls?: { function: { arguments: string } }[] } }[];
      usage: { prompt_tokens: number; completion_tokens: number };
    };
  }

  function messages(req: ChatRequest) {
    const out: { role: string; content: string }[] = [];
    if (req.system) out.push({ role: "system", content: req.system });
    for (const m of req.messages) out.push({ role: m.role, content: m.content });
    return out;
  }

  return {
    provider: "openai",
    model,
    async complete(req) {
      const data = await call({ model, max_tokens: req.maxTokens ?? 1024, messages: messages(req) });
      return {
        text: data.choices[0]?.message?.content ?? "",
        provider: "openai",
        model,
        inputTokens: data.usage.prompt_tokens,
        outputTokens: data.usage.completion_tokens,
      };
    },
    async completeStructured(req, structured: StructuredSpec): Promise<ChatResult> {
      const data = await call({
        model,
        max_tokens: req.maxTokens ?? 1024,
        messages: messages(req),
        tools: [
          {
            type: "function",
            function: {
              name: structured.name,
              description: structured.description ?? "Emit the structured result as JSON.",
              parameters: structured.schema,
            },
          },
        ],
        tool_choice: { type: "function", function: { name: structured.name } },
      });
      const args = data.choices[0]?.message?.tool_calls?.[0]?.function?.arguments ?? "null";
      let value: unknown = null;
      try {
        value = JSON.parse(args);
      } catch {
        value = null;
      }
      return {
        text: args,
        structured: value,
        provider: "openai",
        model,
        inputTokens: data.usage.prompt_tokens,
        outputTokens: data.usage.completion_tokens,
      };
    },
  };
}

export function defaultChatAdapter(spec: ProviderSpec, deps: AdapterDeps): ChatAdapter {
  switch (spec.provider) {
    case "anthropic":
      return anthropicChat(spec, deps);
    case "openai":
      return openaiChat(spec, deps);
    default:
      throw new Error(`unknown chat provider: ${spec.provider}`);
  }
}
