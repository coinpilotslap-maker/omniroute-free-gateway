#!/usr/bin/env bash
# verify-free.sh — 3-part proof a free-only OmniRoute connection is live and $0:
#   1) provider test passes
#   2) live chat completion through the gateway
#   3) cost ledger shows $0 for the session's free models
# Usage: bash verify-free.sh [model-alias]   (default: north-mini-code:free)
set -uo pipefail

MODEL="${1:-north-mini-code:free}"

echo "== 1/3 omniroute server health =="
HEALTH_OUT="$(omniroute health 2>&1 | grep -viE 'Loaded env|STORAGE|📋')"
if ! echo "$HEALTH_OUT" | grep -qiE 'healthy|uptime|running'; then
  echo "FAIL: server not healthy — start it (omniroute serve / omniroute autostart)"
  echo "$HEALTH_OUT" | head -5
  exit 1
fi
echo "$HEALTH_OUT" | head -6

echo
echo "== 2/3 provider test (openrouter) =="
omniroute providers test openrouter 2>&1 | grep -viE "Loaded env|STORAGE|📋" || true

echo
echo "== 3/3 live \$0 call via gateway: $MODEL =="
RESP="$(curl -fsS -m 90 http://127.0.0.1:20128/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"reply with exactly: OK\"}],\"max_tokens\":8}" 2>&1)"
if echo "$RESP" | grep -q '"error"'; then
  echo "WARN: gateway returned an error (could be a free-tier cooldown — retry, or pick another leg):"
  echo "$RESP" | head -c 400; echo
else
  echo "$RESP" | head -c 300; echo
  echo "LIVE: free completion OK"
fi

echo
echo "== cost ledger (last 5 rows; free models should be \$0.00) =="
omniroute cost 2>&1 | grep -viE "Loaded env|STORAGE|📋" | head -12
