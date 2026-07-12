import type { FastifyInstance } from "fastify";
import websocket from "@fastify/websocket";
import WebSocket from "ws";
import { jwtVerify, createRemoteJWKSet } from "jose";
import { route } from "./providerRouter.ts";
import { getRealtimeInstructions } from "./prompts/index.ts";

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

    const key = process.env.OPENAI_API_KEY;
    if (!key) {
      send({ type: "error", error: "provider_not_configured", provider: "openai:realtime" });
      clientSock.close();
      return;
    }

    const realtimeModel = route("realtime").primary.split(":")[1] ?? "gpt-realtime";
    const upstream = new WebSocket(`${OPENAI_REALTIME_URL}?model=${encodeURIComponent(realtimeModel)}`, {
      headers: { Authorization: `Bearer ${key}`, "OpenAI-Beta": "realtime=v1" },
    });

    // The first client message carries the scenario/persona; we turn it into the
    // Actor instructions and open the realtime session.
    let opened = false;
    clientSock.on("message", (raw: WebSocket.RawData) => {
      const text = raw.toString();
      if (!opened) {
        opened = true;
        try {
          const init = JSON.parse(text) as { variables?: Record<string, unknown> };
          const instructions = getRealtimeInstructions(init.variables ?? {});
          upstream.once("open", () => {
            upstream.send(JSON.stringify({
              type: "session.update",
              session: { instructions, modalities: ["audio", "text"], voice: "alloy" },
            }));
          });
        } catch {
          send({ type: "error", error: "bad_init" });
        }
        return;
      }
      // Subsequent frames (audio append / commit / systemUpdate) pass through.
      if (upstream.readyState === WebSocket.OPEN) upstream.send(text);
    });

    upstream.on("message", (raw) => clientSock.send(raw.toString()));
    upstream.on("error", () => send({ type: "error", error: "upstream_error" }));
    upstream.on("close", () => clientSock.close());
    clientSock.on("close", () => { try { upstream.close(); } catch { /* already closed */ } });
  });
}
