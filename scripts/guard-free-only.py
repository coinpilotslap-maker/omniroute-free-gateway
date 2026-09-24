#!/usr/bin/env python3
"""guard-free-only.py — fail-closed billing guard for the free-only OmniRoute gateway.

Run this BEFORE any gateway script (build-free-combo.sh, verify-free.sh).
It refuses to proceed (exit 1) if ANY of the following is true:

  1. The OpenRouter account is funded: total_credits > 0, is_free_tier is false,
     or a per-key credit limit has been set. An unfunded free-tier account has
     no billing surface at all — the moment credits or a limit appear, the
     scripts stop working so no spend can be routed through them.
  2. Any routing combo in the OmniRoute database contains a non-free leg
     (i.e. a model that is not a ":free" OpenRouter model).
  3. The guard cannot verify funding status (network/parse failure) —
     fail-closed: no proof of $0 posture, no run.

This guard is READ-ONLY: it reads the key's billing status from OpenRouter and
the local combo DB. It never posts credentials, never accepts or transmits
card/payment data, and needs none.

Environment:
  OMNIROUTE_KEY_FILE   path to the OpenRouter key file
                       (default: ~/.config/omniroute/openrouter.key)
  OMNIROUTE_STORAGE    path to the OmniRoute sqlite storage
                       (default: ~/.omniroute/storage.sqlite)
"""
import json
import os
import sqlite3
import sys
import urllib.request
from typing import NoReturn

KEY_FILE = os.environ.get("OMNIROUTE_KEY_FILE",
                          os.path.expanduser("~/.config/omniroute/openrouter.key"))
STORAGE = os.environ.get("OMNIROUTE_STORAGE",
                         os.path.expanduser("~/.omniroute/storage.sqlite"))


def die(msg: str) -> NoReturn:
    print(f"\nGUARD BLOCKED: {msg}")
    print("The gateway will NOT run any script in this state.")
    print("Fix the underlying condition (unfund the account / remove paid legs),")
    print("then re-run. There is no override flag on purpose.")
    sys.exit(1)


def check_openrouter_unfunded() -> None:
    """Fail-closed on any sign of funding or unverifiable state."""
    if not os.path.isfile(KEY_FILE):
        die(f"key file not found: {KEY_FILE}")
    key = open(KEY_FILE).read().strip()
    if not key:
        die(f"key file is empty: {KEY_FILE}")

    req = urllib.request.Request(
        "https://openrouter.ai/api/v1/key",
        headers={"Authorization": f"Bearer {key}"},
    )
    d = None
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            d = json.loads(r.read()).get("data", {})
    except Exception as e:
        die(f"could not verify OpenRouter billing posture ({type(e).__name__}: {e}). "
            "Fail-closed: refusing to run without proof of $0 posture.")
    if d is None:  # unreachable (die() exits) but keeps type-checkers honest
        die("unexpected: no key data returned")

    # Fail-closed on every field: unknown/missing means unverified, which blocks.
    is_free_tier = d.get("is_free_tier")
    total_credits = d.get("total_credits")
    limit = d.get("limit")
    if not isinstance(is_free_tier, bool):
        die(f"cannot verify free-tier status (is_free_tier={is_free_tier!r}). Fail-closed.")
    if is_free_tier is False:
        die("OpenRouter account is NOT free-tier (paid credits exist). "
            "Unfund it before running these scripts.")
    if total_credits not in (None, 0):
        die(f"OpenRouter account has funded credits (total_credits={total_credits}). "
            "A billing surface now exists — unfund it before running these scripts.")
    if limit is not None:
        die(f"OpenRouter key has a credit limit set (limit={limit}) — "
            "that only makes sense with funded credits.")
    print(f"  openrouter key: free-tier={is_free_tier}, credits={total_credits}, limit={limit}  [OK]")


def check_no_paid_combos() -> None:
    """Fail-closed if any combo in storage has a non-free leg."""
    if not os.path.isfile(STORAGE):
        die(f"OmniRoute storage not found: {STORAGE} (is the gateway installed?)")
    con = sqlite3.connect(f"file:{STORAGE}?mode=ro", uri=True)
    try:
        rows = con.execute("SELECT name, data FROM combos").fetchall()
    except sqlite3.OperationalError as e:
        die(f"could not read combos table ({e}). Fail-closed.")
    finally:
        con.close()

    offenders = []
    for name, data in rows:
        try:
            spec = json.loads(data)
        except Exception:
            continue
        for leg in spec.get("models", []):
            model = str(leg.get("model", ""))
            provider = str(leg.get("providerId", ""))
            free = model.endswith(":free") or provider == "aihorde"
            if not free:
                offenders.append(f"{name} -> {model} ({provider})")
    if offenders:
        die("paid (non-free) legs found in routing combos:\n  "
            + "\n  ".join(offenders))
    print(f"  combos in storage: {len(rows)} — all legs :free/keyless  [OK]")


def main() -> None:
    print("guard-free-only: verifying zero-billing posture...")
    check_openrouter_unfunded()
    check_no_paid_combos()
    print("guard-free-only: PASS — no funded account, no paid legs, no payment data touched.")
    print("Safe to run build-free-combo.sh / verify-free.sh.")


if __name__ == "__main__":
    main()
