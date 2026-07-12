import type { FastifyRequest, FastifyReply } from "fastify";
import { createRemoteJWKSet, jwtVerify } from "jose";

// Supabase JWT verification (§7: all endpoints authed via Supabase JWT).
// Local dev without either env var bypasses auth with a loud warning —
// never deploy in that state.

const JWKS_URL = process.env.SUPABASE_JWKS_URL;
const JWT_SECRET = process.env.SUPABASE_JWT_SECRET;

const jwks = JWKS_URL ? createRemoteJWKSet(new URL(JWKS_URL)) : null;
const secretKey = JWT_SECRET ? new TextEncoder().encode(JWT_SECRET) : null;

export const devBypass = !jwks && !secretKey;

if (devBypass) {
  console.warn("⚠️  AUTH DISABLED: no SUPABASE_JWKS_URL / SUPABASE_JWT_SECRET set. Dev only.");
}

declare module "fastify" {
  interface FastifyRequest {
    userId: string;
  }
}

export async function authenticate(req: FastifyRequest, reply: FastifyReply): Promise<void> {
  if (devBypass) {
    req.userId = "dev";
    return;
  }
  const header = req.headers.authorization ?? "";
  const token = header.startsWith("Bearer ") ? header.slice(7) : null;
  if (!token) {
    await reply.code(401).send({ error: "missing_bearer_token" });
    return;
  }
  try {
    const { payload } = jwks
      ? await jwtVerify(token, jwks)
      : await jwtVerify(token, secretKey!);
    if (!payload.sub) throw new Error("no sub claim");
    req.userId = payload.sub;
  } catch {
    await reply.code(401).send({ error: "invalid_token" });
  }
}
