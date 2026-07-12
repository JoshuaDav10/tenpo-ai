import Fastify, { type FastifyInstance } from "fastify";
import { authenticate } from "./auth.ts";
import { route } from "./providerRouter.ts";
import { usage } from "./costMeter.ts";

// Endpoints per §7. Phase 0 ships auth, routing, cost meter, and stubs;
// each capability goes live when its phase arrives (chat/stt/tts/pron in
// Phase 2–3, /realtime WSS bridge in Phase 3).

export function buildApp(): FastifyInstance {
  const app = Fastify({ logger: true });

  app.get("/healthz", async () => ({
    status: "ok",
    service: "kizuna-proxy",
    version: "0.1.0",
  }));

  // Everything below requires a Supabase JWT (dev bypass logs a warning).
  app.register(async (authed) => {
    authed.addHook("preHandler", authenticate);

    // Director + content gen (§4.4). Client sends {template_id, variables} —
    // prompt templates live server-side only.
    authed.post("/chat", async (req, reply) => {
      const r = route("chat");
      return reply.code(501).send({
        error: "not_implemented",
        capability: "chat",
        route: r,
        note: "Live in Phase 3 (Director) — request shape: { template_id, variables, messages? }",
      });
    });

    authed.post("/stt", async (req, reply) => {
      return reply.code(501).send({
        error: "not_implemented",
        capability: "stt",
        route: route("stt"),
        note: "Live in Phase 2 — server pass of the grading cascade (§4.3.4)",
      });
    });

    authed.post("/tts", async (req, reply) => {
      return reply.code(501).send({
        error: "not_implemented",
        capability: "tts",
        route: route("tts"),
        note: "Live in Phase 2 — cache-first curriculum audio (§4.3.1)",
      });
    });

    authed.post("/pron", async (req, reply) => {
      return reply.code(501).send({
        error: "not_implemented",
        capability: "pron",
        route: route("pron"),
        note: "Live in Phase 2 — Azure Pronunciation Assessment (§4.3.2)",
      });
    });

    // Cost meter (§4.3.6) — the dashboard's dogfood cost display reads this.
    authed.get("/usage", async (req) => usage(req.userId));
  });

  return app;
}
