# omniroute-free-gateway

**The standard: one command turns a stock Hermes Agent box into a zero-billing,
forever-free LLM gateway** — "code without token fear."

```
Hermes installed (any LLM) → user downloads OmniRoute + creates ONE free OpenRouter key
(no card, no payment method) → runs:  bash install.sh  →  Hermes takes over:
OmniRoute's $0 free-only combo becomes the PRIMARY; the user's old LLM stays as
last-resort fallback so nothing ever dies.
```

## The design rule: focus only on OmniRoute

Hermes points at **one thing** — the local gateway (`http://127.0.0.1:20128/v1`).
OpenRouter's `:free` models live **inside OmniRoute's `free-only` combo** and are never
a direct dependency of Hermes: no direct-OpenRouter fallback layers, no
`OPENROUTER_API_KEY` managed by Hermes, no second point of failure. The combo's
~20-leg priority chain absorbs per-model 429s/cooldowns on its own.

What you get:

- **One OpenAI-compatible endpoint** that only ever routes to $0 free models.
- **Zero billing surface, structurally**: the OpenRouter account is unfunded — no
  credits, no card, no payment method. A stray paid-model request errors out; it can
  not be charged. A fail-closed guard blocks the whole stack if that invariant breaks.
- **Noauth bonus (opt-in)**: AI Horde — the volunteer mesh. No card, no billing
  surface (a free account key, not a payment method). Wired in only when you drop a
  key at `~/.config/omniroute/aihorde.key`.

## The one command

```bash
# prerequisites: Node >= 22, Hermes installed, one free OpenRouter key (sk-or-..., no card)
OMNIROUTE_OPENROUTER_KEY=sk-or-... bash install.sh
```

What it does, in order:
1. installs OmniRoute if missing and starts the server (detached — a dying PTY kills
   it via SIGHUP; run `omniroute autostart` once for systemd self-heal),
2. registers the OpenRouter key (secret via stdin, never argv),
3. **fail-closed billing check**: refuses if the account is funded (credits/payment),
4. rebuilds the `free-only` combo from the live `:free` catalog and proves a live $0 call,
5. **lets Hermes take over**: primary → `free-only` @ the gateway; old LLM → last-resort
   fallback. Config backed up first; existing fallbacks are never deleted.

Variants:

```bash
bash install.sh --keep-primary   # Hermes keeps its LLM; the gateway becomes fallback #1 (additive)
bash install.sh --no-hermes     # gateway only, don't touch Hermes config
OMNIROUTE_OPENROUTER_KEY=sk-or-... bash install.sh --yes   # non-interactive, full take-over
```

Key sourcing order: `OMNIROUTE_OPENROUTER_KEY` env → `~/.config/omniroute/openrouter.key`
→ `OPENROUTER_API_KEY` env → interactive prompt.

## Contents

| Path | Purpose |
|---|---|
| `install.sh` | THE STANDARD: one command, the 5 steps above, idempotent, never deletes |
| `scripts/guard-free-only.py` | Fail-closed money gate: blocks any script if the account is funded, a combo has a paid leg, or posture can't be verified. Read-only; touches no card/payment data. No override by design. |
| `scripts/build-free-combo.sh` | Enumerate OpenRouter `:free` models → create + activate the `free-only` combo (guard runs first) |
| `scripts/verify-free.sh` | Guard + 3-part proof: server health, provider test, live $0 call, cost ledger |
| `scripts/wire-hermes.sh` | Hermes take-over / additive wiring — gateway-only layers (never direct OpenRouter); only `hermes config set`, never hand-edits config.yaml; backs up before switching primary |
| `scripts/discover-free-sources.py` | Enumerate every reachable $0 source for this box: OpenRouter `:free` (the standard) + opt-in AI Horde noauth mesh; refuses funded accounts |
| `SKILL.md` | The full procedural skill: install, wiring, combo lock, gotchas, dead-end warnings |
| `examples/free_legs.example.json` | What the combo-leg JSON looks like |

## Why "noauth" is a bonus, not the standard

AI Horde is the volunteer mesh: **no card, no credits, no billing surface — but it is
kudos-gated, not truly keyless.** Verified 2026-09 against the live API:

- The classical `/model/list` URL never existed; the real endpoints are
  `/api/v2/status/models`, `/api/v2/stats/text/models`, `/api/v2/generate/text/*`.
- Anonymous keys (`4444444444`, `anonymous`, `anon`, `guest`, `public`) pass auth but
  **no job is ever created** — a free *account* key (aihorde.net/register, no card) is
  the minimum, and kudos buys queue priority.
- OmniRoute's built-in `aihorde` provider is **image-only**, so Horde is not an
  LLM-token source for this stack even with a key.

That's why the **standard** source is the OpenRouter free key (one 30-second signup,
$0 forever) and Horde stays an opt-in bonus you enable with `--with-aihorde` + a free
account key. Either way: no money, no card.

## Expectations on "free"

- Free tiers throttle: per-model cooldowns (~24s) and ~50 free req/day caps on
  OpenRouter. The combo's priority chain absorbs both.
- This repo does **not** guarantee capacity, only that the *billing surface is zero*.
- The OmniRoute dashboard's "hard policy" (restricted models + $0 budget) API is a
  known dead-end in current builds — the reliable locks are the combo + unfunded key
  (see SKILL.md).

## Termux / Android (platform-agnostic)

The installer detects Termux automatically (via `$PREFIX` + `pkg`) and adapts:
port check falls back to `curl` (no `ss`), the server starts without `setsid`
(no util-linux on stock Termux), and instead of systemd it tells you to use
`termux-wake-lock` + a `.termux/boot/` script, because Android reaps background
processes when the app is closed.

One-line prerequisites before `bash install.sh`:

```bash
pkg install -y nodejs python make clang curl git
```

- `clang`+`make` build the native `better-sqlite3` module inside OmniRoute.
- `python` runs the fail-closed billing guard.
- `curl` is the universal port check (used on every platform).

```bash
OMNIROUTE_OPENROUTER_KEY=sk-or-... bash install.sh   # same one command as desktop
termux-wake-lock                                      # keep the gateway alive in background
mkdir -p ~/.termux/boot && echo "omniroute serve" > ~/.termux/boot/omniroute.sh
```

If the server fails to start on Termux it is almost always the native module —
run `pkg install -y nodejs python make clang` and retry `npm i -g omniroute`.

## License
MIT
