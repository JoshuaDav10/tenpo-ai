// Per-user daily cost accounting (§4.3.6). In-memory for dogfooding — the
// proxy is a single VM, and losing a partial day's meter on restart only
// under-counts in the user's favor. Persisted metering can move to Supabase later.
//
// Caps gate STARTING sessions, never terminate active ones (R13).

export interface UsageSummary {
  userId: string;
  day: string;
  spentUSD: number;
  softCapUSD: number;
  hardCapUSD: number;
  overSoftCap: boolean;
  overHardCap: boolean;
}

const SOFT_CAP = Number(process.env.DAILY_SOFT_CAP_USD ?? "2.50");
const HARD_CAP = Number(process.env.DAILY_HARD_CAP_USD ?? "5.00");

const spent = new Map<string, number>(); // `${userId}:${day}` → USD

function today(): string {
  return new Date().toISOString().slice(0, 10);
}

export function recordCost(userId: string, usd: number): void {
  const key = `${userId}:${today()}`;
  spent.set(key, (spent.get(key) ?? 0) + usd);
}

export function usage(userId: string): UsageSummary {
  const day = today();
  const spentUSD = spent.get(`${userId}:${day}`) ?? 0;
  return {
    userId,
    day,
    spentUSD,
    softCapUSD: SOFT_CAP,
    hardCapUSD: HARD_CAP,
    overSoftCap: spentUSD >= SOFT_CAP,
    overHardCap: spentUSD >= HARD_CAP,
  };
}

// Whether a NEW realtime-voice (Pipeline A) session may open (§4.3.6). Realtime is
// the expensive path, so it is allowed only below the soft cap: past the soft cap
// roleplays drop to the cheap cascade (client falls back), past the hard cap only
// drills remain. Refusal never touches an active session (R13) — it only gates open.
export type RealtimeDecision =
  | { allow: true }
  | { allow: false; reason: "cost_cheap_mode" | "cost_hard_cap" };

export function realtimeAdmission(u: UsageSummary): RealtimeDecision {
  if (u.overHardCap) return { allow: false, reason: "cost_hard_cap" };
  if (u.overSoftCap) return { allow: false, reason: "cost_cheap_mode" };
  return { allow: true };
}
