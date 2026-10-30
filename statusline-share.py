#!/usr/bin/env python3
"""Claude Code status line that shares the quota with claude-usage-tray.

Use it when Claude Code runs as a different Windows user than the tray: the
tray cannot read that user's profile, so this script writes the status line's
rate_limits (plus account email and plan, no secrets) to
<root>\\.claude-usage\\usage.json, root = first existing of SHARED_ROOTS (keep
in sync with claude-tray.ps1). In that user's ~/.claude/settings.json:

    "statusLine": {"type": "command", "command": "python C:/path/to/statusline-share.py"}

Use an absolute path: that user's HOME may not be its profile. To keep your own
status line, copy share_usage() into it and call it with the parsed stdin.
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


def share_usage(data):
    rl = data.get("rate_limits") or {}
    if not rl.get("five_hour") and not rl.get("seven_day"):
        return
    root = next((r for r in SHARED_ROOTS if os.path.isdir(r)), None)
    if not root:
        return
    home = os.path.expanduser("~")
    out = {
        "cached_at": int(time.time()),
        "five_hour": rl.get("five_hour"),
        "seven_day": rl.get("seven_day"),
        "email": _grab(os.path.join(home, ".claude.json"), "emailAddress"),
        "plan": _grab(os.path.join(home, ".claude", ".credentials.json"), "subscriptionType"),
    }
    folder = os.path.join(root, ".claude-usage")
    os.makedirs(folder, exist_ok=True)
    path = os.path.join(folder, "usage.json")
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(out, f)
    os.replace(tmp, path)  # atomic: the tray never sees a half-written file


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
