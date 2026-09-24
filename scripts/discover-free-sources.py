#!/usr/bin/env python3
"""discover-free-sources.py — enumerate every reachable $0 free-token source OmniRoute can route.

Priority (the "forever-free" standard):
  1. OpenRouter `:free` — THE STANDARD: one free key, no card, no credits.
     Fail-closed: a FUNDED OpenRouter account (credits / payment method) is REFUSED —
     a card balance must never become a billing surface for this stack.
  2. AI Horde — the noauth volunteer mesh (opt-in via --with-aihorde).
     Reachability is checked against its live, verified endpoints (/api/v2/stats/text/models).
     NOTE (tested 2026-09): text generation now requires a free Horde `apikey` header —
     fully-anonymous submit is flaky server-side. So Horde legs are emitted only when a
     key is present (OMNIROUTE_AIHORDE_KEY or ~/.config/omniroute/aihorde.key).
     Still $0 and card-free; the key is a free account, not a payment method.

Output: JSON array of combo legs (stdout) in OmniRoute combo-spec shape, e.g.
  [{"kind":"model","model":"cohere/north-mini-code:free","providerId":"openrouter","weight":0}, ...]

OpenRouter legs use BARE model ids (the `:free` suffix, no provider prefix) — that is the
shape build-free-combo.sh / `omniroute combo create --models` expects.
Horde legs use `aihorde/<name>` under providerId `aihorde` (a registered keyless-ish provider).

Read-only + tiny probes. Exits 0 with [] when nothing usable (callers must refuse to
build an empty combo). Per-source detail goes to stderr.
"""
import json
import os
import sys
import urllib.request
import urllib.error

HDRS = {"User-Agent": "omni-route-free-gateway/1.0"}
# Real, verified AI Horde endpoints (the classic /model/list never existed — that 404
# is why Horde looked "dead" for months; /api/v2/stats/text/models is live):
AHORDE_TEXT_STATS = "https://aihorde.net/api/v2/stats/text/models"
MAX_LEGS_PER_SOURCE = 30


def http_json(url, method="GET", key=None, timeout=30):
    headers = dict(HDRS)
    if key:
        if "aihorde.net" in url:
            headers["apikey"] = key            # Horde uses the `apikey` header, not Bearer
        else:
            headers["Authorization"] = f"Bearer {key}"
    req = urllib.request.Request(url, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"HTTP {e.code} for {url}")


def find_file_key(path):
    p = os.path.expanduser(path)
    if os.path.isfile(p):
        v = open(p).read().strip()
        if v:
            return v
    return ""


def discover_openrouter() -> list:
    """THE STANDARD source: OpenRouter :free behind an EXISTING unfunded key.
    Fail-closed: funded accounts are refused — no billing surface."""
    key = (os.environ.get("OMNIROUTE_OPENROUTER_KEY", "")
           or find_file_key("~/.config/omniroute/openrouter.key")
           or os.environ.get("OPENROUTER_API_KEY", ""))
    if not key:
        print("  openrouter: no key on this box — skipped (standard journey = create one free key, no card)",
              file=sys.stderr)
        return []
    try:
        k = http_json("https://openrouter.ai/api/v1/key", key=key).get("data", {})
    except Exception as e:
        print(f"  openrouter: could not verify key posture ({e}) — fail-closed, skipped",
              file=sys.stderr)
        return []
    funded = (k.get("is_free_tier") is False or k.get("total_credits") not in (None, 0))
    if funded:
        print(f"  openrouter: REFUSED — funded account (credits={k.get('total_credits')}). "
              f"A card/credit balance would become a billing surface. Unfund and retry.",
              file=sys.stderr)
        return []
    try:
        models = http_json("https://openrouter.ai/api/v1/models", key=key)
    except Exception as e:
        print(f"  openrouter: could not fetch catalog ({e}) — skipped", file=sys.stderr)
        return []
    free = [m["id"] for m in models.get("data", []) if m.get("id", "").endswith(":free")]
    legs = [{"kind": "model", "model": mid, "providerId": "openrouter", "weight": 0}
            for mid in free]
    print(f"  openrouter: unfunded free-tier key — {len(legs)} :free legs, $0, no card",
          file=sys.stderr)
    return legs


def discover_aihorde(with_key: bool) -> list:
    """Optional bonus source: the AI Horde volunteer mesh ($0, no card, no billing).
    Reachability via the live text-model stats endpoint; legs only when a free Horde key
    is present, because text submit now requires an `apikey` header."""
    if not with_key:
        print("  aihorde: skipped (pass --with-aihorde to include the noauth mesh)", file=sys.stderr)
        return []
    try:
        stats = http_json(AHORDE_TEXT_STATS)
        day = stats.get("day", {})
        top = [k for k, v in sorted(day.items(), key=lambda x: -x[1]) if v > 0]
    except Exception as e:
        print(f"  aihorde: unreachable from this host ({e}) — skipped", file=sys.stderr)
        return []
    key = (os.environ.get("OMNIROUTE_AIHORDE_KEY", "")
           or find_file_key("~/.config/omniroute/aihorde.key"))
    if not key:
        print(f"  aihorde: reachable ({len(top)} text models live) but no free Horde key — "
              f"skipped (text gen needs an `apikey` header; free account at aihorde.net/register, no card).",
              file=sys.stderr)
        return []
    legs = [{"kind": "model", "model": f"aihorde/{n}", "providerId": "aihorde", "weight": 0}
            for n in top[:MAX_LEGS_PER_SOURCE]]
    print(f"  aihorde: {len(legs)} noauth-mesh legs (bonus, $0, no card, no credits)", file=sys.stderr)
    return legs


def main():
    args = sys.argv[1:]
    with_ah = "--with-aihorde" in args
    print("discovering reachable $0 free-token sources…", file=sys.stderr)
    legs = discover_openrouter() + discover_aihorde(with_ah)
    json.dump(legs, sys.stdout)
    print(f"\n→ {len(legs)} legs total", file=sys.stderr)


if __name__ == "__main__":
    main()
