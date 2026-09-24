#!/usr/bin/env bash
# wire-hermes.sh — wire the local OmniRoute gateway into Hermes.
#
#   bash wire-hermes.sh                 # additive: gateway becomes fallback #1;
#                                       # your primary and existing fallbacks untouched
#   bash wire-hermes.sh --primary       # THE STANDARD: gateway's `free-only` $0 combo
#                                       # becomes Hermes's PRIMARY; your old LLM becomes
#                                       # the last-resort fallback; config backed up first
#   bash wire-hermes.sh --primary --yes # skip the interactive confirmation
#
# Design ("focus only on OmniRoute"):
#   - Hermes points ONLY at the OmniRoute gateway — never at OpenRouter directly.
#     OpenRouter `:free` models live INSIDE the gateway's free-only combo; the combo's
#     ~20-leg priority chain absorbs per-model 429s/cooldowns, so a direct-OpenRouter
#     fallback layer in Hermes is redundant.
#   - The only NEW entry this script adds is the gateway itself:
#     {provider: custom, model: free-only, base_url: http://127.0.0.1:20128/v1}
#   - NEVER hand-edits config.yaml — only `hermes config set` (the documented path).
#   - NEVER removes your existing fallback entries (stale gateway entries pointing at
#     the same base_url are canonically replaced by the free-only entry).
#   - Backs up config.yaml to <HERMES_HOME>/config.yaml.bak-wire-hermes-<ts> before --primary.
#
# Requires: a running OmniRoute server on :20128 (install.sh does this; or `omniroute serve`).
set -uo pipefail

MAKE_PRIMARY=0
ASSUME_YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --primary) MAKE_PRIMARY=1 ;;
    --yes) ASSUME_YES=1 ;;
    -h|--help) grep '^#' "$0" | head -16; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
  shift
done

HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
CFG="$HERMES_HOME/config.yaml"
GATEWAY="http://127.0.0.1:20128/v1"

[ -x "$(command -v hermes)" ] || { echo "✗ hermes CLI not found — install Hermes first" >&2; exit 1; }
[ -f "$CFG" ] || { echo "✗ $CFG not found" >&2; exit 1; }

ok() { echo "  ✓ $*"; }
warn() { echo "  ! $*"; }
fail() { echo "✗ $*" >&2; exit 1; }

# ------------------------------------------------------------------ 1. gateway reachable
echo "== gateway reachability"
CODE=$(curl -s -o /dev/null -w '%{http_code}' -m 5 "$GATEWAY/models" 2>/dev/null || true)
# any HTTP response (even 401/404) proves the server is up; 000 = no listener
[ "$CODE" = "000" ] && fail "gateway not reachable at $GATEWAY — start it first (omniroute serve / omniroute autostart)"
ok "gateway answering at $GATEWAY (HTTP $CODE)"

# ------------------------------------------------------------------ 2. build desired fallback chain
echo "== building fallback chain"
python3 - "$CFG" "$GATEWAY" "$MAKE_PRIMARY" <<'PY' > /tmp/fb_new_chain.json
import json, sys, re, yaml
# argv layout (argv[0] is '-'): [CFG, GATEWAY, MAKE_PRIMARY]
cfg_path, gateway_url = sys.argv[1], sys.argv[2]
make_primary = sys.argv[3] == "1"   # argv arrives as "0"/"1" — a non-empty string is truthy, must compare

d = yaml.safe_load(open(cfg_path)) or {}
existing = d.get("fallback_providers") or []
def norm(e):
    if not isinstance(e, dict): return None
    p = str(e.get("provider") or "").strip()
    m = str(e.get("model") or "").strip()
    b = str(e.get("base_url") or "").strip().rstrip("/")
    if not p or not m: return None
    return (p, m, b)

# THE ONLY entry this script adds: the $0 gateway combo.
GATEWAY_CANON = {"provider": "custom", "model": "free-only",
                 "base_url": gateway_url, "api_key": "omni-route-local"}
canon = ("custom", "free-only", gateway_url.rstrip("/").lower())

def is_gateway_entry(n):
    # any existing fallback entry pointing at this gateway (stale auto/other names)
    return n is not None and (n[2] or "").lower() == gateway_url.rstrip("/").lower()

model_cfg = d.get("model") or {}
current_is_gateway = (
    str(model_cfg.get("base_url") or "").rstrip("/").lower() == gateway_url.rstrip("/").lower()
    and str(model_cfg.get("provider") or "").lower() == "custom"
)

# old primary becomes a last-resort fallback entry when taking over
old_primary_entry = None
if make_primary:
    pm = str(model_cfg.get("default") or model_cfg.get("model") or "").strip()
    pp = str(model_cfg.get("provider") or "").strip()
    pb = str(model_cfg.get("base_url") or "").strip()
    pk = str(model_cfg.get("api_key") or "").strip()
    if pp and pm and not current_is_gateway:
        entry = {"provider": pp, "model": pm}
        if pb:
            entry["base_url"] = pb.rstrip("/")
        envref = re.match(r"^\$\{([A-Z0-9_]+)\}$", pk)
        if envref:
            entry["key_env"] = envref.group(1)
        elif pk:
            entry["api_key"] = pk  # only when it was already inline in the model section
        old_primary_entry = entry

desired = []
seen = set()
# 0) the gateway entry — unless the primary already is (or, in --primary mode, is about
#    to become) this gateway; a gateway inside its own fallback chain is a no-op loop.
if not make_primary and not current_is_gateway:
    desired.append(dict(GATEWAY_CANON))
    seen.add(canon)

# 1) keep every existing entry — EXCEPT stale gateway entries (canonically replaced)
for e in existing:
    n = norm(e)
    if not n: continue
    if is_gateway_entry(n):
        continue
    if n in seen: continue
    desired.append(e)
    seen.add(n)

# 2) old primary last (only in --primary mode)
if old_primary_entry:
    n = norm(old_primary_entry)
    if n and n not in seen:
        desired.append(old_primary_entry)
json.dump(desired, sys.stdout)
PY
[ -s /tmp/fb_new_chain.json ] || fail "failed to build chain JSON"

# ------------------------------------------------------------------ 3. apply
echo "== applying to Hermes config"
if [ "$MAKE_PRIMARY" = "1" ]; then
  if [ "$ASSUME_YES" != "1" ]; then
    echo "  ⚠  This sets Hermes's PRIMARY model to OmniRoute 'free-only' ($GATEWAY) — the \$0 combo."
    echo "     Free models are weaker for heavy coding; your old LLM becomes last-resort fallback."
    printf '     Continue? [y/N] '; read -r ans; [ "$ans" = "y" ] || { echo "aborted"; exit 1; }
  fi
  TS="$(date +%Y%m%d-%H%M%S)"
  cp "$CFG" "$CFG.bak-wire-hermes-$TS" && ok "config backed up: $CFG.bak-wire-hermes-$TS"
  hermes config set model.provider custom | head -1
  hermes config set model.base_url "$GATEWAY" | head -1
  hermes config set model.default free-only | head -1
  hermes config set model.api_key omni-route-local | head -1
fi

CHAIN_JSON="$(cat /tmp/fb_new_chain.json)"
hermes config set fallback_providers "$CHAIN_JSON" | head -1
ok "fallback chain written ($(python3 -c "import json;print(len(json.load(open('/tmp/fb_new_chain.json'))))" ) entries)"

# ------------------------------------------------------------------ 4. report
echo
echo "== resulting chain (new sessions pick it up on config reload / /new):"
hermes fallback list 2>/dev/null | head -14
[ "$MAKE_PRIMARY" = "0" ] && echo "   (additive mode — your primary model was not touched)" \
                          || echo "   (primary switched to OmniRoute free-only; old LLM is now last-resort)"
echo "   Hermes points ONLY at the gateway — OpenRouter lives inside OmniRoute's combo, never directly."
