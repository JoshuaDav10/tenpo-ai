import { readFileSync, watchFile } from "node:fs";
import { fileURLToPath } from "node:url";

// Routing table (§4.3.3): the client names capabilities, this file names
// providers. Hot-reloadable — edit providers.json, no restart needed.

export type Capability = "chat" | "stt" | "tts" | "pron" | "realtime";

export interface Route {
  primary: string;
  fallback?: string;
}

const CONFIG_PATH = fileURLToPath(new URL("./config/providers.json", import.meta.url));

let table: Record<Capability, Route> = load();

function load(): Record<Capability, Route> {
  return JSON.parse(readFileSync(CONFIG_PATH, "utf8"));
}

// unref: the watcher must not keep the process alive (tests, graceful shutdown)
watchFile(CONFIG_PATH, { interval: 2000 }, () => {
  try {
    table = load();
    console.log("provider routing table reloaded");
  } catch (err) {
    console.error("provider routing table reload failed, keeping previous", err);
  }
}).unref();

export function route(capability: Capability): Route {
  const r = table[capability];
  if (!r) throw new Error(`no route for capability: ${capability}`);
  return r;
}
