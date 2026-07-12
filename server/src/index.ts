import { buildApp } from "./app.ts";
import { registerRealtime } from "./realtime.ts";

const app = buildApp();
// The realtime WSS bridge (§4.3.1 Pipeline A) is registered on the running server
// only — kept out of buildApp so the hermetic HTTP tests need no ws dependency.
await registerRealtime(app);

const port = Number(process.env.PORT ?? "8787");
const host = process.env.HOST ?? "0.0.0.0";

app.listen({ port, host }).catch((err) => {
  app.log.error(err);
  process.exit(1);
});
