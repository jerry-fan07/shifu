// Shifu Cloud — the hosted LLM proxy (design.md §4.2, §8).
//
// Holds the DeepSeek API key server-side so users never handle one. The
// client (shifu-analyzer) speaks the same OpenAI-compatible protocol it
// speaks to DeepSeek directly; this Worker only authenticates, enforces
// limits, and forwards. Two hard rules:
//
//   1. The upstream response body is returned VERBATIM. DeepSeekBackend is
//      the only place in the app that ever sees the `usage` object, and all
//      local cost accounting dies if a proxy strips or rewraps it.
//   2. Nothing is trusted from the client: model allowlist, max_tokens
//      ceiling, body size cap, rate limit, and daily token budget are all
//      enforced here, not there.
//
// State lives in Workers KV. KV is eventually consistent, so the budget and
// rate counters are approximate — good enough to stop abuse, not billing-
// grade metering (see README for the Durable Objects upgrade path if that
// ever matters).

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (request.method !== "POST") {
      return json({ error: "POST only" }, 405);
    }
    if (url.pathname === "/v1/register") {
      return register(request, env);
    }
    if (url.pathname === "/v1/chat/completions" || url.pathname === "/chat/completions") {
      return complete(request, env);
    }
    return json({ error: "not found" }, 404);
  },
};

/** Mint a device token. Anonymous by design — the token identifies a device
 *  for rate limiting and revocation, never a person. */
async function register(request, env) {
  const ip = request.headers.get("cf-connecting-ip") ?? "unknown";
  const ipKey = `reg:${ip}:${today()}`;
  const registrations = parseInt((await env.TOKENS.get(ipKey)) ?? "0", 10);
  if (registrations >= parseInt(env.REGISTRATIONS_PER_IP_PER_DAY, 10)) {
    return json({ error: "registration limit reached, try tomorrow" }, 429);
  }
  await env.TOKENS.put(ipKey, String(registrations + 1), { expirationTtl: 86400 });

  let body = {};
  try {
    body = await request.json();
  } catch {
    // Registration body is informational only.
  }
  const token = "st_" + crypto.randomUUID().replaceAll("-", "") +
    crypto.randomUUID().replaceAll("-", "");
  await env.TOKENS.put(`token:${token}`, JSON.stringify({
    created: new Date().toISOString(),
    platform: body.platform ?? "unknown",
    app_version: body.app_version ?? "unknown",
  }));
  return json({ token });
}

async function complete(request, env) {
  const auth = request.headers.get("authorization") ?? "";
  const token = auth.startsWith("Bearer ") ? auth.slice(7) : "";
  if (!token || !(await env.TOKENS.get(`token:${token}`))) {
    return json({ error: "invalid or missing device token" }, 401);
  }

  const raw = await request.arrayBuffer();
  if (raw.byteLength > parseInt(env.MAX_BODY_BYTES, 10)) {
    return json({ error: "request too large" }, 413);
  }
  let body;
  try {
    body = JSON.parse(new TextDecoder().decode(raw));
  } catch {
    return json({ error: "body is not JSON" }, 400);
  }

  const allowed = env.ALLOWED_MODELS.split(",").map((name) => name.trim());
  if (!allowed.includes(body.model)) {
    return json({ error: `model not allowed: ${body.model}` }, 403);
  }
  const ceiling = parseInt(env.MAX_TOKENS_CEILING, 10);
  if (!Number.isInteger(body.max_tokens) || body.max_tokens > ceiling) {
    return json({ error: `max_tokens must be an integer ≤ ${ceiling}` }, 400);
  }
  if (body.stream) {
    return json({ error: "streaming is not supported" }, 400);
  }

  // Approximate per-device limits (KV is eventually consistent).
  const minuteKey = `rpm:${token}:${Math.floor(Date.now() / 60000)}`;
  const requestsThisMinute = parseInt((await env.TOKENS.get(minuteKey)) ?? "0", 10);
  if (requestsThisMinute >= parseInt(env.RATE_LIMIT_PER_MINUTE, 10)) {
    return json({ error: "rate limit exceeded" }, 429);
  }
  await env.TOKENS.put(minuteKey, String(requestsThisMinute + 1), { expirationTtl: 120 });

  const budgetKey = `budget:${token}:${today()}`;
  const spentToday = parseInt((await env.TOKENS.get(budgetKey)) ?? "0", 10);
  if (spentToday >= parseInt(env.DAILY_TOKEN_BUDGET, 10)) {
    return json({ error: "daily token budget exhausted, resets at UTC midnight" }, 429);
  }

  const upstream = await fetch(`${env.UPSTREAM}/chat/completions`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: `Bearer ${env.DEEPSEEK_API_KEY}`,
    },
    body: raw,
  });

  // Buffer (never rewrite) the response: metering reads usage from the same
  // bytes the client will parse, so what is billed here is what is recorded
  // there.
  const responseBody = await upstream.arrayBuffer();
  if (upstream.ok) {
    try {
      const usage = JSON.parse(new TextDecoder().decode(responseBody)).usage;
      const total = usage?.total_tokens ?? 0;
      if (total > 0) {
        await env.TOKENS.put(budgetKey, String(spentToday + total), { expirationTtl: 172800 });
      }
    } catch {
      // Unparseable body: pass it through anyway; the client logs it.
    }
  }
  return new Response(responseBody, {
    status: upstream.status,
    headers: { "content-type": upstream.headers.get("content-type") ?? "application/json" },
  });
}

function today() {
  return new Date().toISOString().slice(0, 10);
}

function json(payload, status = 200) {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { "content-type": "application/json" },
  });
}
