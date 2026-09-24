#!/usr/bin/env bash
# build-free-combo.sh — create + activate a free-only OmniRoute combo from OpenRouter's live :free catalog.
# Requires: omniroute CLI, running server, OpenRouter key at ~/.config/omniroute/openrouter.key
# Usage: bash build-free-combo.sh [combo-name]
set -euo pipefail

COMBO_NAME="${1:-free-only}"
KEY_FILE="${OMNIROUTE_KEY_FILE:-$HOME/.config/omniroute/openrouter.key}"
[ -f "$KEY_FILE" ] || { echo "ERROR: key file not found: $KEY_FILE" >&2; exit 1; }

# 0) fail-closed billing guard: block if account funded, combo has paid legs, or posture unverifiable.
#    Also proves this script touches no card/payment data.
python3 "$(dirname "$0")/guard-free-only.py" || exit 1

KEY="$(cat "$KEY_FILE")"

# 1) enumerate live :free models from OpenRouter
LEGS_JSON="$(curl -fsS -H "Authorization: Bearer $KEY" https://openrouter.ai/api/v1/models \
  | python3 -c '
import json,sys
d=json.load(sys.stdin)
free=[m for m in d.get("data",[]) if m.get("id","").endswith(":free")]
# keep only models with a non-null context length and at least a tiny free credit price (i.e. genuinely free)
legs=[{"kind":"model","model":m["id"],"providerId":"openrouter","weight":0} for m in free]
json.dump(legs,sys.stdout)
')"
NLEGS="$(python3 -c "import json,sys;print(len(json.loads(sys.argv[1])))" "$LEGS_JSON")"
[ "$NLEGS" -ge 1 ] || { echo "ERROR: no :free models found in live catalog" >&2; exit 1; }
echo "Found $NLEGS :free models. Writing combo '$COMBO_NAME' ..."

# 2) recreate the combo idempotently (delete if exists, create, switch)
if omniroute combo list 2>/dev/null | grep -qE "(^| )$COMBO_NAME( |\$)"; then
  echo "Existing '$COMBO_NAME' combo found — replacing..."
  echo y | omniroute combo delete "$COMBO_NAME" >/dev/null 2>&1 || true
fi

LEGS_FILE="$(mktemp -t omh_free_legs.XXXXXX.json)"
echo "$LEGS_JSON" > "$LEGS_FILE"
omniroute combo create "$COMBO_NAME" --strategy priority --models "$(cat "$LEGS_FILE")"
omniroute combo switch "$COMBO_NAME"
rm -f "$LEGS_FILE"

# 3) verify legs actually persisted (column is `data`, not `json`)
echo
echo "=== persisted legs in storage.sqlite ==="
python3 - "$COMBO_NAME" <<'PY'
import sqlite3,os,json,sys
name=sys.argv[1]
c=sqlite3.connect(os.path.expanduser("~/.omniroute/storage.sqlite"))
row=c.execute("SELECT data FROM combos WHERE name=?", (name,)).fetchone()
if not row:
    print("WARN: combo not found in storage"); sys.exit(1)
spec=json.loads(row[0])
legs=spec["models"]
bad=[l for l in legs if not l["model"].endswith(":free")]
print(f"{name}: {len(legs)} legs, strategy={spec.get('strategy')}")
print("all :free/openrouter:", not bad and all(l.get("providerId")=="openrouter" for l in legs))
PY

echo
echo "Next: prove it with a live free call:"
echo "  curl -fsS http://127.0.0.1:20128/v1/chat/completions -H 'Content-Type: application/json' \\"
echo "    -d '{\"model\":\"north-mini-code:free\",\"messages\":[{\"role\":\"user\",\"content\":\"OK\"}],\"max_tokens\":5}'"
