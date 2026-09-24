#!/usr/bin/env bash
# install.sh — THE STANDARD: one command turns a stock Hermes box into a
# zero-billing, "forever-free tokens" setup via a local OmniRoute gateway.
#
# The journey this automates:
#   1. user installed Hermes Agent (with whatever free LLM it ships with — OAuth etc.)
#   2. user downloads OmniRoute, creates ONE free OpenRouter API key (no card, no payment)
#   3. user runs:  bash install.sh
#      -> this script: installs OmniRoute, starts the server, registers the key,
#         builds the free-only combo from the live :free catalog, proves $0, and
#         LETS HERMES TAKE OVER: OmniRoute becomes the primary ($0); the user's
#         old LLM is kept as last-resort fallback so nothing ever dies.
#
# Guarantees:
#   - NEVER bills: fail-closed billing guard blocks funded accounts; only :free legs
#   - NEVER asks for / touches a card or credit balance (unfunded free-tier key only)
#   - idempotent: re-runs are safe; config.yaml is backed up before take-over
#   - additive fallbacks: existing entries are kept, never deleted
#
# Usage:
#   bash install.sh                    # the journey: take over (confirm unless --yes)
#   OMNIROUTE_OPENROUTER_KEY=sk-or-... bash install.sh --yes   # non-interactive
#   bash install.sh --keep-primary     # same, but Hermes keeps its old LLM primary;
#                                      # OmniRoute is just fallback #1 (additive only)
#   bash install.sh --no-hermes       # gateway only, don't touch Hermes config
#
# Exit codes: 0 = success/no-op, 1 = blocked (guard or missing prerequisite), 2 = start failure.
set -uo pipefail

WIRE_HERMES=1
MAKE_PRIMARY=1
ASSUME_YES=0
START_SERVER=1
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

while [ $# -gt 0 ]; do
  case "$1" in
    --wire-hermes) WIRE_HERMES=1; MAKE_PRIMARY=1 ;;
    --primary) MAKE_PRIMARY=1; WIRE_HERMES=1 ;;
    --keep-primary) MAKE_PRIMARY=0; WIRE_HERMES=1 ;;
    --no-hermes) WIRE_HERMES=0; MAKE_PRIMARY=0 ;;
    --yes) ASSUME_YES=1 ;;
    --no-start) START_SERVER=0 ;;
    -h|--help) grep '^#' "$0" | head -26; exit 0 ;;
    *) echo "unknown flag: $1 (see --help)" >&2; exit 1 ;;
  esac
  shift
done

ok()   { echo "  ✓ $*"; }
warn() { echo "  ! $*"; }
fail() { echo "  ✗ $*" >&2; exit 1; }
step() { echo; echo "== $*"; }

# ---------------------------------------------------------------- step 1: omniroute
step "1/5 OmniRoute installed"
if command -v omniroute >/dev/null 2>&1; then
  ok "omniroute on PATH ($(omniroute --version 2>/dev/null | head -1 || echo 'version unknown'))"
elif [ -x "$HOME/.local/bin/omniroute" ] && [ -d "$HOME/.local/lib/node_modules/omniroute" ]; then
  export PATH="$HOME/.local/lib/node_modules/.bin:$HOME/.local/bin:$PATH"
  ok "found under ~/.local (added to PATH)"
else
  if command -v npm >/dev/null 2>&1; then
    echo "  … not found — installing via npm (global)"
    npm i -g omniroute >/dev/null 2>&1 || npm i -g omniroute || fail "npm install failed"
    command -v omniroute >/dev/null 2>&1 || export PATH="$(npm prefix -g)/bin:$HOME/.local/lib/node_modules/.bin:$PATH"
    ok "installed"
  else
    fail "omniroute not installed and no npm available (needs Node >= 22; then: npm i -g omniroute)"
  fi
fi

# ---------------------------------------------------------------- step 2: server
step "2/5 OmniRoute server on :20128"
server_up() {
  ss -tln 2>/dev/null | grep -q ":20128" || return 1
  # port bound AND actually serving (not a half-dead listener)
  [ "$(curl -s -o /dev/null -w '%{http_code}' -m 5 http://127.0.0.1:20128/ 2>/dev/null)" != "000" ]
}
if [ "$START_SERVER" = "1" ]; then
  if server_up; then
    ok "already listening"
  else
    echo "  … starting detached (no PTY — a PTY session ending kills it via SIGHUP)"
    nohup setsid omniroute serve >/dev/null 2>&1 &
    for i in $(seq 1 30); do
      sleep 1; server_up && break
    done
    server_up || {
      warn "port not up yet — 'omniroute autostart' (systemd) recommended for reboot survival:"
      warn "the server DIES when a PTY that started it is closed; check ~/.omniroute/logs/"
      exit 2
    }
    ok "started"
    warn "run 'omniroute autostart' once for systemd auto-start + self-heal"
  fi
fi

# ---------------------------------------------------------------- step 3: openrouter key
step "3/5 OpenRouter key + billing posture"
KEY_FILE="$HOME/.config/omniroute/openrouter.key"
OR_KEY=""
if [ -n "${OMNIROUTE_OPENROUTER_KEY:-}" ]; then OR_KEY="$OMNIROUTE_OPENROUTER_KEY"; fi
if [ -z "$OR_KEY" ] && [ -f "$KEY_FILE" ]; then OR_KEY="$(cat "$KEY_FILE")"; fi
if [ -z "$OR_KEY" ] && [ -n "${OPENROUTER_API_KEY:-}" ]; then OR_KEY="$OPENROUTER_API_KEY"; fi
if [ -z "$OR_KEY" ]; then
  if [ -t 0 ]; then
    printf 'Paste your OpenRouter free-tier key (sk-or-...): '
    read -r OR_KEY
  else
    fail "no key found. Provide via OMNIROUTE_OPENROUTER_KEY env, OPENROUTER_API_KEY, or $KEY_FILE"
  fi
fi
[ -n "$OR_KEY" ] || fail "empty key"
if [ ! -f "$KEY_FILE" ]; then
  mkdir -p "$(dirname "$KEY_FILE")"; echo "$OR_KEY" > "$KEY_FILE"; chmod 600 "$KEY_FILE"
  ok "key written to $KEY_FILE (chmod 600)"
else
  ok "key present at $KEY_FILE"
fi

# provider connection (idempotent)
if omniroute providers list 2>/dev/null | grep -q "^.*openrouter"; then
  ok "openrouter provider connection exists"
else
  echo "  … adding openrouter connection (credential via stdin)"
  ( printf '%s' "$OR_KEY"; omniroute providers add openrouter --credential-stdin --yes ) \
    || fail "could not add openrouter provider"
  ok "openrouter provider connection added"
fi

# billing posture: unfunded free-tier only (fail-closed). Key read from the key FILE,
# never passed on the command line.
python3 - "$KEY_FILE" <<'PY'
import json, sys, urllib.request
key = open(sys.argv[1]).read().strip()
try:
    req = urllib.request.Request("https://openrouter.ai/api/v1/key",
                                 headers={"Authorization": f"Bearer {key}"})
    d = json.loads(urllib.request.urlopen(req, timeout=30).read()).get("data", {})
except Exception as e:
    print(f"  ✗ could not verify billing posture ({e}); fail-closed"); sys.exit(1)
bad = []
if d.get("is_free_tier") is False: bad.append("not free-tier")
if d.get("total_credits") not in (None, 0): bad.append(f"funded credits ({d.get('total_credits')})")
if d.get("limit") is not None: bad.append(f"key limit set ({d.get('limit')})")
if bad:
    print(f"  ✗ BILLING RISK — account is {', '.join(bad)}. "
          f"Unfund OpenRouter (https://openrouter.ai/credits) before continuing.")
    sys.exit(1)
print("  ✓ unfunded free-tier key — no billing surface")
PY
[ $? -eq 0 ] || exit 1

# ---------------------------------------------------------------- step 4: free combo + guard + proof
step "4/5 free-only combo (rebuilt from live catalog)"
bash "$SCRIPT_DIR/scripts/build-free-combo.sh" || fail "combo build blocked by guard — see output above"

step "   live \$0 proof"
bash "$SCRIPT_DIR/scripts/verify-free.sh" || warn "verify reported issues — check the gateway before wiring Hermes"

# ---------------------------------------------------------------- step 5: hermes wiring
if [ "$WIRE_HERMES" = "1" ]; then
  step "5/5 Hermes takes over: OmniRoute \$0 primary, old LLM last-resort"
  if [ "$MAKE_PRIMARY" = "1" ]; then
    [ "$ASSUME_YES" = "1" ] || {
      echo "  ⚠  Hermes's MAIN model becomes OmniRoute's free-only \$0 combo."
      echo "     Your current LLM stays as last-resort fallback — nothing ever dies."
      echo "     Free models are weaker for heavy coding tasks. Continue? [y/N] "
      read -r ans; [ "$ans" = "y" ] || exit 1
    }
  fi
  # wire-hermes.sh accepts: --primary (take over) / plain (additive) / --yes (no prompt)
  if [ "$MAKE_PRIMARY" = "1" ]; then
    FLAGS="--primary"
  else
    FLAGS=""
  fi
  [ "$ASSUME_YES" = "1" ] && FLAGS="$FLAGS --yes"
  bash "$SCRIPT_DIR/scripts/wire-hermes.sh" $FLAGS || exit 1
else
  step "5/5 Hermes wiring skipped (pass --no-hermes to intentionally skip)"
fi

echo
echo "Done. One-command result:"
omniroute combo list 2>/dev/null | grep -i free-only || true
[ "$WIRE_HERMES" = "1" ] && hermes fallback list 2>/dev/null | head -12 || true
echo
echo "Restore anytime: the installer never deletes. Backups: ~/.hermes/config.yaml.bak-*"
echo "New Hermes sessions pick up the \$0 primary on config reload (run /new)."
