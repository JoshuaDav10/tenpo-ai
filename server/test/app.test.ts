import { test } from "node:test";
import assert from "node:assert/strict";
import { buildApp } from "../src/app.ts";

test("healthz responds ok without auth", async () => {
  const app = buildApp();
  const res = await app.inject({ method: "GET", url: "/healthz" });
  assert.equal(res.statusCode, 200);
  assert.equal(res.json().status, "ok");
  await app.close();
});

test("capability stubs report their route from the routing table", async () => {
  const app = buildApp();
  const res = await app.inject({ method: "POST", url: "/chat", payload: {} });
  assert.equal(res.statusCode, 501);
  const body = res.json();
  assert.equal(body.capability, "chat");
  assert.equal(body.route.primary, "anthropic:claude-sonnet-4-6");
  await app.close();
});

test("usage returns per-user meter with caps", async () => {
  const app = buildApp();
  const res = await app.inject({ method: "GET", url: "/usage" });
  assert.equal(res.statusCode, 200);
  const body = res.json();
  assert.equal(body.spentUSD, 0);
  assert.equal(body.overHardCap, false);
  assert.ok(body.softCapUSD > 0);
  await app.close();
});
