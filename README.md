# omniroute-free-gateway

A Hermes/agent skill (with copy-paste helpers) for turning a local
[OmniRoute](https://github.com/diegosouzapw/OmniRoute) gateway into a
**zero-billing LLM provider** — "code without token fear."

## What you get

- **One local OpenAI-compatible endpoint** (`http://127.0.0.1:20128/v1`) that only ever
  routes to **free** models: OpenRouter `:free` catalog (≈20 models) behind a free-tier key.
- **No billing surface**: the OpenRouter account is unfunded (no credits, no card). Free
  models cost $0 by definition; even a stray paid-model request returns `402` — not a charge.
- **An explicit `free-only` routing combo** (priority fallback chain), so a cooling/rate-limited
  free model just falls through to the next leg instead of failing.
- **Cleanup recipes** for the dead "free providers" that are red on the dashboard (OpenCode,
  Felo, AI Horde are IP/client-restricted and don't work from a normal host — remove them).

## Quickstart (terminal)

```bash
# 0) prerequisites: Node >= 22, an OpenRouter free-tier key (no card)
npm i -g omniroute

# 1) start the server (detached, survives the session)
omniroute serve &          # or: omniroute autostart   (systemd user service)

# 2) add your OpenRouter key (secret stays out of argv)
mkdir -p ~/.config/omniroute
# put your sk-or-... key into ~/.config/omniroute/openrouter.key (chmod 600)
cat ~/.config/omniroute/openrouter.key | omniroute providers add openrouter --credential-stdin --yes

# 3) confirm the "never billed" posture
curl -sH "Authorization: Bearer $(cat ~/.config/omniroute/openrouter.key)" \
     https://openrouter.ai/api/v1/key | python3 -m json.tool | grep -E 'is_free_tier|limit|total_credits'

# 4) build the free-only combo (runs the fail-closed billing guard first)
bash scripts/build-free-combo.sh          # guard → fetch :free models → create+activate combo

# 5) prove it: live $0 call through the gateway
curl -fsS http://127.0.0.1:20128/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"north-mini-code:free","messages":[{"role":"user","content":"reply OK"}],"max_tokens":5}'
```

Then point your agent (Hermes, Codex, any OpenAI-compatible client) at
`http://127.0.0.1:20128/v1` and use the gateway's model names.

## Install the skill

- **Hermes Agent:** copy `SKILL.md` into your skills dir
  (`~/.hermes/skills/omniroute-free-gateway/SKILL.md`), or install this repo as a
  plugin/skill source per your agent's docs.
- **Any other agent:** `SKILL.md` is plain markdown with YAML frontmatter — load it on demand.

## Contents

| Path | Purpose |
|---|---|
| `SKILL.md` | The full procedural skill: install, wiring, combo lock, gotchas, dead-end warnings |
| `scripts/build-free-combo.sh` | Enumerate OpenRouter `:free` models → create + activate the `free-only` combo (guard runs first) |
| `scripts/verify-free.sh` | Billing guard + 3-part proof: server health, provider test, live $0 call, cost ledger |
| `scripts/guard-free-only.py` | Fail-closed money gate: blocks any script if the account is funded, a combo has a paid leg, or posture can't be verified. Read-only; touches no card/payment data. No override by design. |
| `examples/free_legs.example.json` | What the combo-leg JSON looks like |
| `README.md` | This file |

## Expectations on "free"

- Free tiers throttle: per-model cooldowns (~24s) and ~50 free req/day caps on OpenRouter.
  The priority chain absorbs both.
- This repo does **not** guarantee capacity, only that the *billing surface is zero*.
- The OmniRoute dashboard's "hard policy" (restricted models + $0 budget) API is a known
  dead-end in current builds — the reliable locks are the combo + unfunded key (see SKILL.md).

## License

MIT
