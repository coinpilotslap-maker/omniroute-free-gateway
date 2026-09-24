---
name: omniroute-free-gateway
description: Use when building a zero-billing local LLM gateway: OmniRoute + free-only routing (OpenRouter :free models) so agents can "code without token fear" with $0 spend and no card on file.
---

# OmniRoute Free-Only Gateway (zero-billing LLM router)

Turn a local OmniRoute instance (port 20128, OpenAI-compatible `/v1`) into a **free-only** LLM
provider: an OpenRouter free-tier key drives `:free` models, an explicit `free-only` combo locks
routing to $0, and the unfunded account guarantees nothing can ever be billed.

Verified end-to-end 2026-09 (npm omniroute v3.8.5x, Node 22, Linux).

## Install & boot
- `npm i -g omniroute` → `omniroute serve` as a detached background process (NO pty — a PTY
  session ending sends SIGHUP and kills the server; relaunch via tracked background process,
  or `omniroute autostart` for a systemd user service).
- Verify: `ss -tln | grep 20128` (LISTEN), `omniroute health`.
- Dashboard `http://127.0.0.1:20128/login`; data path `/v1/chat/completions` is keyless client-side.

## The honest catch (never over-promise "free out of the box")
- Keyless free providers fail from most hosts: OpenCode free → 403 "only usable from within
  OpenCode", Felo → 400, AI Horde → API 404 / IP-restricted. So `auto` combo → "All models
  failed" 502. A working gateway needs ≥1 live upstream.
- The working free upstream that actually passes from a residential/host IP here:
  **OpenRouter `:free` models** behind a free-tier key.

## Wire OpenRouter free-tier (no card, never billed)
- Keep the key in a file, add it via stdin so the secret never lands in argv/process tables:
  `cat ~/.config/omniroute/openrouter.key | omniroute providers add openrouter --credential-stdin --yes`
- Confirm the billing posture (this is the "never charged" guarantee, check it once):
  `curl -H "Authorization: Bearer $KEY" https://openrouter.ai/api/v1/key` →
  `is_free_tier: true`, `limit: null`, `total_credits: null` (unfunded).
  Free models cost $0 by definition; with no funded credits or payment method, even a stray
  paid-model call returns **402**, not a charge.
- `omniroute providers test openrouter` → "provider test passed".

## Build the free-only combo (the routing lock)
- Enumerate free models: `curl -H "Authorization: Bearer $KEY" https://openrouter.ai/api/v1/models`
  filter `id` ending `:free` (≈20 available).
- Create a JSON array of leg objects `{"kind":"model","model":"<slug>:free","providerId":"openrouter","weight":0}`
  (optional `id` field), then:
  `omniroute combo create free-only --strategy priority --models "$(cat free_legs.json)"`
  `omniroute combo switch free-only`
- Verify legs actually landed: `sqlite3 ~/.omniroute/storage.sqlite
  "SELECT data FROM combos WHERE name='free-only'"` (column is `data`, NOT `json`).
- Call the gateway with the bare alias: `{"model":"north-mini-code:free"}` — the provider-prefixed
  form (`cohere/north-mini-code:free`) can hit provider-resolution errors; short alias works.

## Expectation-setting on free tiers (not bugs)
- Per-model cooldowns (~24s, `model_cooldown`) and ~50 free req/day caps are inherent to
  OpenRouter free tiers. A priority combo absorbs them: a cooling leg falls through to the next.
- "Stable" = works as-you-go; don't promise sustained high throughput.

## Clean up dashboard reds
- `omniroute providers list` shows per-connection health. Keyless providers (e.g. aihorde)
  get registered as `apikey` connections and fail health checks ("no API key configured")
  forever, and their live catalog may be empty/unreachable.
- To reach an all-green board: `omniroute providers remove <idOrName> --yes` for every
  dead/noauth placeholder; keep only providers that actually route. After removing a
  provider referenced by a combo, delete + recreate the combo with the surviving legs.

## The "hard policy lock" that does NOT work in this build (save yourself hours)
- `omniroute policy create --file <json>` → 400: POST `/api/policies` is a discriminated-union
  on `action` that the CLI can't express; per-key `omniroute keys policy set <id> --max-cost 0
  --allowed-models ...` → 404 (route absent in this build).
- The reliable lock is the combo itself (free-only routing) + the unfunded key (402 at source).
- If a global policy is ever needed (e.g. after funding the account), use the dashboard
  (Policies → New → Restricted models + $0 daily/weekly budget) — the GUI produces the valid body.

## Pairing with an agent (cost angle)
- Point the agent's coding/auxiliary model slots at `http://127.0.0.1:20128/v1` ONLY after a
  live free-model call through the gateway succeeds (3-part proof: `providers test` pass,
  live completion, `omniroute cost` ledger). Before that, an empty gateway just turns working
  inference into 502s.

## Billing guard (fail-closed, run before anything)
- `scripts/guard-free-only.py` is the money gate: it blocks (exit 1, no override by design) if
  ANY of — (1) the OpenRouter account is no longer unfunded (`total_credits` > 0,
  `is_free_tier` false, or a key credit `limit` set), (2) any combo in
  `~/.omniroute/storage.sqlite` contains a non-`:free`/non-keyless leg, or (3) the billing
  posture cannot be verified at all (network/parse failure → fail-closed).
  `build-free-combo.sh` and `verify-free.sh` both run it as step 0.
- The guard is strictly READ-ONLY: one `GET https://openrouter.ai/api/v1/key` plus a read-only
  open of the local sqlite. No script in this repo accepts, transmits, or stores card/payment
  data — the only secret involved is the OpenRouter key file, and it is never echoed, logged,
  or written anywhere new.
- Override-free on purpose: if the guard blocks, the correct move is to fix the condition
  (unfund / remove paid legs), never to bypass it.
