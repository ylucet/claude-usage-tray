#!/usr/bin/env python3
"""Claude Code status line that shares the quota with claude-usage-tray.

Use it when Claude Code runs as a different Windows user than the tray: the
tray cannot read that user's profile, so this script writes the status line's
rate_limits (plus account email and plan, no secrets) under
<root>\\.claude-usage\\, root = first existing of SHARED_ROOTS (keep in sync
with claude-tray.ps1):

    accounts\\<email>.json   one file per account, so an account you switched
                            away from (/login) keeps its last known quota
    usage.json              the account in use (read by older trays)

In that user's ~/.claude/settings.json:

    "statusLine": {"type": "command", "command": "python C:/path/to/statusline-share.py"}

Use an absolute path: that user's HOME may not be its profile. To keep your own
status line, copy share_usage() and its helpers into it and call it with the
parsed stdin.
"""
import json
import os
import re
import sys
import time

SHARED_ROOTS = [r"D:\AI", r"C:\AI-local"]


def _grab(path, key):
    # Regex, not json.load: ~/.claude.json may hold case-duplicate keys, and
    # only this one non-secret field is needed.
    try:
        with open(path, encoding="utf-8") as f:
            m = re.search(r'"%s"\s*:\s*"([^"]*)"' % key, f.read())
        return m.group(1) if m else None
    except OSError:
        return None


def _write(path, obj):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f)
    os.replace(tmp, path)  # atomic: the tray never sees a half-written file


def _resets(snap):
    try:
        return (snap["five_hour"]["resets_at"], snap["seven_day"]["resets_at"])
    except (KeyError, TypeError):
        return None


def account_file_name(email):
    return re.sub(r"[^A-Za-z0-9@._+-]", "_", email.lower()) + ".json"


def share_usage(data, root=None, home=None):
    rl = data.get("rate_limits") or {}
    if not rl.get("five_hour") and not rl.get("seven_day"):
        return
    root = root or next((r for r in SHARED_ROOTS if os.path.isdir(r)), None)
    if not root:
        return
    home = home or os.path.expanduser("~")
    out = {
        "cached_at": int(time.time()),
        "five_hour": rl.get("five_hour"),
        "seven_day": rl.get("seven_day"),
        "email": _grab(os.path.join(home, ".claude.json"), "emailAddress"),
        "plan": _grab(os.path.join(home, ".claude", ".credentials.json"), "subscriptionType"),
    }
    folder = os.path.join(root, ".claude-usage")
    if out["email"]:
        accounts = os.path.join(folder, "accounts")
        os.makedirs(accounts, exist_ok=True)
        mine = account_file_name(out["email"])
        # Right after /login the status line may still carry the previous
        # account's limits. Both reset instants equal to another account's
        # means they are that account's limits: write nothing.
        key = _resets(out)
        if key:
            for name in os.listdir(accounts):
                if name == mine or not name.endswith(".json"):
                    continue
                try:
                    with open(os.path.join(accounts, name), encoding="utf-8") as f:
                        other = json.load(f)
                except (OSError, ValueError):
                    continue
                if _resets(other) == key:
                    return
        _write(os.path.join(accounts, mine), out)
    os.makedirs(folder, exist_ok=True)
    _write(os.path.join(folder, "usage.json"), out)


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    data = json.load(sys.stdin)
    try:
        share_usage(data)
    except Exception:
        pass  # never break the status line
    ctx = (data.get("context_window") or {}).get("used_percentage") or 0
    rl = data.get("rate_limits") or {}
    parts = [f"ctx {ctx:.0f}%"]
    for key, label in (("five_hour", "5h"), ("seven_day", "7d")):
        if rl.get(key):
            parts.append(f"{label} {rl[key].get('used_percentage', 0):.0f}%")
    print(" | ".join(parts))
