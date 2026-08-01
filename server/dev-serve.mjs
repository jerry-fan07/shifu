// Serve the Worker locally without wrangler: in-memory KV, env from
// wrangler.toml's defaults. For pointing a dev build's shifu_cloud.base_url
// at http://127.0.0.1:8787 (registration and limits work; completions only
// reach a real model if DEEPSEEK_API_KEY and UPSTREAM are exported).
//   node server/dev-serve.mjs
import { createServer } from "node:http";
import worker from "./src/index.js";

const store = new Map();
const env = {
  TOKENS: {
    async get(key) { return store.get(key) ?? null; },
    async put(key, value) { store.set(key, value); },
  },
  ALLOWED_MODELS: "deepseek-v4-flash,deepseek-v4-pro",
  MAX_TOKENS_CEILING: "60000",
  MAX_BODY_BYTES: "262144",
  DAILY_TOKEN_BUDGET: "4000000",
  RATE_LIMIT_PER_MINUTE: "60",
  REGISTRATIONS_PER_IP_PER_DAY: "10",
  UPSTREAM: process.env.UPSTREAM ?? "https://api.deepseek.com",
  DEEPSEEK_API_KEY: process.env.DEEPSEEK_API_KEY ?? "unset",
};

const port = parseInt(process.env.PORT ?? "8787", 10);
createServer(async (incoming, outgoing) => {
  const chunks = [];
  for await (const chunk of incoming) chunks.push(chunk);
  const request = new Request(`http://127.0.0.1:${port}${incoming.url}`, {
    method: incoming.method,
    headers: { ...incoming.headers, "cf-connecting-ip": "127.0.0.1" },
    body: chunks.length > 0 ? Buffer.concat(chunks) : undefined,
  });
  const response = await worker.fetch(request, env);
  outgoing.writeHead(response.status, Object.fromEntries(response.headers));
  outgoing.end(Buffer.from(await response.arrayBuffer()));
}).listen(port, () => console.log(`shifu-cloud dev proxy on http://127.0.0.1:${port}`));
