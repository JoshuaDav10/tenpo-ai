import type { FastifyInstance } from "fastify";
import websocket from "@fastify/websocket";
import WebSocket from "ws";
import { jwtVerify, createRemoteJWKSet } from "jose";
import { route } from "./providerRouter.ts";
import { getRealtimeInstructions, getLessonSessionInstructions, renderLessonStep } from "./prompts/index.ts";
import { usage, realtimeAdmission } from "./costMeter.ts";

// WS /realtime (§4.3.1 Pipeline A, §7): bridges client <-> OpenAI Realtime.
// The proxy injects the Actor system prompt (never on the client), streams audio
// both ways, and forwards transcript deltas the client hands to the Director
// worker (§4.4, Director runs OUT OF BAND).
//
// LIVE-VERIFY: needs OPENAI_API_KEY on the proxy + a deployed host. Without the
// key the socket sends one error frame and closes — it never crashes the server.

const OPENAI_REALTIME_URL = "wss://api.openai.com/v1/realtime";

// WS can't use Authorization headers from browsers, so the client passes the
// Supabase JWT as a query param. Verify it the same way as the HTTP routes.
const JWKS_URL = process.env.SUPABASE_JWKS_URL;
const JWT_SECRET = process.env.SUPABASE_JWT_SECRET;
const jwks = JWKS_URL ? createRemoteJWKSet(new URL(JWKS_URL)) : null;
const secretKey = JWT_SECRET ? new TextEncoder().encode(JWT_SECRET) : null;
const wsDevBypass = !jwks && !secretKey;

async function verifyToken(token: string | undefined): Promise<string | null> {
  if (wsDevBypass) return "dev";
  if (!token) return null;
  try {
    const { payload } = jwks ? await jwtVerify(token, jwks) : await jwtVerify(token, secretKey!);
    return (payload.sub as string) ?? null;
  } catch {
    return null;
  }
}

export interface RealtimeInit {
  mode?: string;
  variables?: Record<string, unknown>;
}

/** Session config per mode. Legacy (no mode) keeps the roleplay-actor shape;
 * "lesson" hands turn authority to the client conductor: no auto-response on
 * VAD endpoints, and input transcription on so learner transcripts flow. */
export function buildSessionConfig(init: RealtimeInit): Record<string, unknown> {
  if (init.mode === "lesson") {
    return {
      type: "realtime",
      instructions: getLessonSessionInstructions(init.variables ?? {}),
      output_modalities: ["audio"],
      audio: {
        input: {
          transcription: { model: "gpt-4o-mini-transcribe" }, // no language pin — lessons are bilingual
          turn_detection: {
            type: "semantic_vad",
            eagerness: "low",
            create_response: false, // the conductor decides when the AI speaks
            interrupt_response: false,
          },
        },
        output: { voice: "alloy" },
      },
    };
  }
  return {
    type: "realtime",
    instructions: getRealtimeInstructions(init.variables ?? {}),
    output_modalities: ["audio"],
    audio: {
      input: {
        turn_detection: { type: "semantic_vad", eagerness: "low", interrupt_response: false },
      },
      output: { voice: "alloy" },
    },
  };
}

/** Post-init frame router. `lesson.step` control frames become server-rendered
 * response.create instructions (§7 — prompt text never leaves the server);
 * everything else forwards verbatim. Audio appends (≥6KB base64 per 100ms chunk)
 * skip parsing entirely via the size gate. */
export function interceptFrame(text: string): { forward: string } | { upstream: Record<string, unknown> } {
  if (text.length < 2048) {
    try {
      const obj = JSON.parse(text) as { type?: string; step?: { kind?: string; variables?: Record<string, unknown> } };
      if (obj?.type === "lesson.step" && obj.step?.kind) {
        return {
          upstream: {
            type: "response.create",
            response: { instructions: renderLessonStep(obj.step.kind, obj.step.variables ?? {}) },
          },
        };
      }
    } catch {
      // not JSON we understand — forward untouched
    }
  }
  return { forward: text };
}

export async function registerRealtime(app: FastifyInstance): Promise<void> {
  await app.register(websocket);

  app.get("/realtime", { websocket: true }, async (clientSock, req) => {
    const send = (obj: unknown) => {
      try { clientSock.send(JSON.stringify(obj)); } catch { /* client gone */ }
    };

    const url = new URL(req.url, "http://localhost");
    const userId = await verifyToken(url.searchParams.get("token") ?? undefined);
    if (!userId) {
      send({ type: "error", error: "unauthorized" });
      clientSock.close();
      return;
    }

    // Cost caps (§4.3.6): realtime is the expensive Pipeline A. Past the soft cap
    // the client must fall back to the cheap cascade; past the hard cap only drills
    // remain. Refuse to OPEN — active sessions are never interrupted (R13).
    const admission = realtimeAdmission(usage(userId));
    if (!admission.allow) {
      send({
        type: "error",
        error: admission.reason,
        note: admission.reason === "cost_hard_cap"
          ? "Daily hard cap reached; roleplays are paused. Drills remain available (R13)."
          : "Daily voice budget used up; continue this roleplay in cheap text mode (R13).",
      });
      clientSock.close();
      return;
    }

    const key = process.env.OPENAI_API_KEY;
    if (!key) {
      send({ type: "error", error: "provider_not_configured", provider: "openai:realtime" });
      clientSock.close();
      return;
    }

    const realtimeModel = route("realtime").primary.split(":")[1] ?? "gpt-realtime";
    const upstream = new WebSocket(`${OPENAI_REALTIME_URL}?model=${encodeURIComponent(realtimeModel)}`, {
      // GA realtime API: no OpenAI-Beta header (the beta protocol is retired).
      headers: { Authorization: `Bearer ${key}` },
    });

    // The first client message is the init frame ({type:"init", mode?, variables});
    // it selects the session shape. Lesson mode hands turn authority to the client
    // conductor, so no opening response.create is sent — the first lesson.step is
    // the English intro (SESSION_DESIGN Act 1).
    let opened = false;
    clientSock.on("message", (raw: WebSocket.RawData) => {
      const text = raw.toString();
      if (!opened) {
        opened = true;
        try {
          const init = JSON.parse(text) as RealtimeInit;
          const session = buildSessionConfig(init);
          const isLesson = init.mode === "lesson";
          upstream.once("open", () => {
            upstream.send(JSON.stringify({ type: "session.update", session }));
            if (!isLesson) {
              // Legacy roleplay: the Actor opens the scene unprompted.
              upstream.send(JSON.stringify({ type: "response.create" }));
            }
          });
        } catch {
          send({ type: "error", error: "bad_init" });
        }
        return;
      }
      // Subsequent frames: lesson.step control frames render server-side (§7);
      // audio appends and everything else pass through verbatim.
      if (upstream.readyState !== WebSocket.OPEN) return;
      const routed = interceptFrame(text);
      if ("upstream" in routed) {
        upstream.send(JSON.stringify(routed.upstream));
      } else {
        upstream.send(routed.forward);
      }
    });

    upstream.on("message", (raw) => clientSock.send(raw.toString()));
    upstream.on("error", () => send({ type: "error", error: "upstream_error" }));
    upstream.on("close", () => clientSock.close());
    clientSock.on("close", () => { try { upstream.close(); } catch { /* already closed */ } });
  });
}
