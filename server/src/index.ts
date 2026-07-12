import { buildApp } from "./app.ts";

const app = buildApp();
const port = Number(process.env.PORT ?? "8787");
const host = process.env.HOST ?? "0.0.0.0";

app.listen({ port, host }).catch((err) => {
  app.log.error(err);
  process.exit(1);
});
