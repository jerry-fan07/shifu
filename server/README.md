# Shifu Cloud — hosted LLM proxy

A Cloudflare Worker that holds the DeepSeek API key so Shifu users never paste
one. `shifu-analyzer` speaks the identical OpenAI-compatible protocol to this
proxy that it speaks to DeepSeek directly; the only client-side differences are
the base URL and a device token instead of an API key.

## Endpoints

| Route | What it does |
|---|---|
| `POST /v1/register` | Mints an anonymous device token (`{"token": "st_…"}`). The analyzer calls this once, on the first run after the user opts in. Per-IP daily cap. |
| `POST /v1/chat/completions` | Authenticated passthrough to DeepSeek. Enforces the model allowlist, `max_tokens` ceiling, body size cap, per-device rate limit, and per-device daily token budget. **Returns the upstream body verbatim** — the client's cost ledger reads the `usage` object from it. |

## Deploy

```sh
cd server
npm install -g wrangler       # or use npx
wrangler login
wrangler kv namespace create TOKENS   # paste the printed id into wrangler.toml
wrangler secret put DEEPSEEK_API_KEY  # the real key, held only here
wrangler deploy
```

Then point the app at the deployed URL. Until the placeholder in
`ShifuCloudDefaults.baseURL` (Sources/ShifuCore/ShifuCore.swift) is updated to
the real domain and released, any build can be pointed at it via the
"Cloud endpoint" field in Settings (`shifu_cloud.base_url`).

A custom domain (Workers → Settings → Domains & Routes) is worth doing before
shipping: the default `*.workers.dev` host is fine for testing, but the base
URL is baked into released builds.

## Limits (wrangler.toml `[vars]`)

- `ALLOWED_MODELS` — exactly the two slots the analyzer uses.
- `MAX_TOKENS_CEILING=60000` — matches the client's whole context window
  (`DeepSeekBackend.contextWindowTokens`), so the thinking-slot escalation
  retry still fits.
- `DAILY_TOKEN_BUDGET=4000000` per device — a heavy dogfood day measured in
  2026-07 runs well under 2M.
- `RATE_LIMIT_PER_MINUTE=60`, `REGISTRATIONS_PER_IP_PER_DAY=10`,
  `MAX_BODY_BYTES=262144`.

Counters live in Workers KV, which is eventually consistent: limits are
abuse-stoppers, not billing-grade metering. If per-user billing ever matters,
move the budget counter to a Durable Object and keep everything else as is.

## Revoking a device

```sh
wrangler kv key delete --binding TOKENS "token:st_<token>"
```

The client gets 401s, its stages skip (never fatal — design.md §10), and a
fresh `/v1/register` on the next analyzer run mints a new token unless the IP
cap stops it.
