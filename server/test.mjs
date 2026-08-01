// Offline exercise of the Worker: stub KV, stub upstream, real handler.
//   node server/test.mjs
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
  REGISTRATIONS_PER_IP_PER_DAY: "2",
  UPSTREAM: "https://upstream.test",
  DEEPSEEK_API_KEY: "sk-server-side",
};

const upstreamReply = {
  choices: [{ message: { content: "{\"ok\":true}" }, finish_reason: "stop" }],
  usage: { prompt_tokens: 100, completion_tokens: 50, total_tokens: 150 },
};
let upstreamSawAuth = null;
globalThis.fetch = async (url, options) => {
  upstreamSawAuth = options.headers.authorization;
  return new Response(JSON.stringify(upstreamReply), {
    status: 200, headers: { "content-type": "application/json" },
  });
};

function post(path, body, headers = {}) {
  return worker.fetch(new Request(`https://proxy.test${path}`, {
    method: "POST", body: JSON.stringify(body),
    headers: { "cf-connecting-ip": "1.2.3.4", ...headers },
  }), env);
}
let failures = 0;
function check(name, condition) {
  if (!condition) failures += 1;
  console.log(`${condition ? "ok" : "FAIL"} - ${name}`);
}

// Register twice (cap is 2), third refused.
const first = await post("/v1/register", { platform: "macos", app_version: "0.1.0" });
const { token } = await first.json();
check("register mints an st_ token", first.status === 200 && token.startsWith("st_"));
await post("/v1/register", {});
const third = await post("/v1/register", {});
check("per-IP registration cap", third.status === 429);

const good = {
  model: "deepseek-v4-flash", max_tokens: 400, temperature: 0.2,
  thinking: { type: "disabled" }, messages: [{ role: "user", content: "hi" }],
};
const bearer = { authorization: `Bearer ${token}` };

check("no token → 401", (await post("/v1/chat/completions", good)).status === 401);
check("bad token → 401", (await post("/v1/chat/completions", good,
  { authorization: "Bearer st_forged" })).status === 401);
check("model not allowlisted → 403", (await post("/v1/chat/completions",
  { ...good, model: "gpt-4o" }, bearer)).status === 403);
check("max_tokens over ceiling → 400", (await post("/v1/chat/completions",
  { ...good, max_tokens: 60001 }, bearer)).status === 400);
check("streaming refused", (await post("/v1/chat/completions",
  { ...good, stream: true }, bearer)).status === 400);

const success = await post("/v1/chat/completions", good, bearer);
const echoed = await success.json();
check("passthrough succeeds", success.status === 200);
check("usage object returned verbatim", echoed.usage.total_tokens === 150
  && echoed.choices[0].message.content === "{\"ok\":true}");
check("upstream saw the server-side key, not the device token",
  upstreamSawAuth === "Bearer sk-server-side");
const day = new Date().toISOString().slice(0, 10);
check("budget metered from usage", store.get(`budget:${token}:${day}`) === "150");

store.set(`budget:${token}:${day}`, "4000000");
check("exhausted budget → 429",
  (await post("/v1/chat/completions", good, bearer)).status === 429);

process.exit(failures === 0 ? 0 : 1);
