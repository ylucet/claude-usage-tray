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
import urllib.request
from datetime import datetime

SHARED_ROOTS = [r"D:\AI", r"C:\AI-local"]
API_EVERY = 300          # seconds between official usage checks, per account
USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
WINDOW_SEC = {"five_hour": 5 * 3600, "seven_day": 7 * 86400}


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


def fetch_usage(home, timeout=2.5):
    """Official usage of the logged-in account, in status-line form, or None.

    Claude Code's status-line rate_limits can lag: after a limit reset it kept
    reporting the previous window's 100%. Uses the access token read-only and
    never refreshes it (refresh tokens rotate; Claude Code owns that). The token
    is never written anywhere.
    """
    try:
        with open(os.path.join(home, ".claude", ".credentials.json"), encoding="utf-8") as f:
            c = json.load(f).get("claudeAiOauth") or {}
        tok = c.get("accessToken")
        if not tok or (c.get("expiresAt") or 0) < (time.time() + 60) * 1000:
            return None
        req = urllib.request.Request(USAGE_URL, headers={
            "Authorization": "Bearer " + tok,
            "anthropic-beta": "oauth-2025-04-20",
            "User-Agent": "claude-code/2.1.78"})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            d = json.load(r)
    except Exception:
        return None
    out = {}
    for k in WINDOW_SEC:
        w = d.get(k)
        if isinstance(w, dict):
            ra = w.get("resets_at")
            out[k] = {"used_percentage": w.get("utilization") or 0,
                      "resets_at": int(datetime.fromisoformat(ra).timestamp()) if ra else None}
    return out or None


def merge_windows(rl, api):
    """Per window, keep the source describing the later window.

    A window not started yet (API resets_at None) ends at the earliest
    api["at"] + its length, after any window that ended before the check.
    Same window (resets within 60 s): usage only grows, take the max.
    """
    res = {}
    for k, length in WINDOW_SEC.items():
        s = rl.get(k) if rl else None
        a = api.get(k) if api else None
        if not a:
            res[k] = s
            continue
        if not s:
            res[k] = a
            continue
        a_end = a.get("resets_at") or (api["at"] + length)
        s_end = s.get("resets_at") or 0
        if abs(a_end - s_end) <= 60:
            res[k] = {"used_percentage": max(s.get("used_percentage") or 0, a.get("used_percentage") or 0),
                      "resets_at": a.get("resets_at") or s.get("resets_at")}
        else:
            res[k] = a if a_end > s_end else s
    return res


def _read(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def share_usage(data, root=None, home=None, fetch=fetch_usage, now=None):
    rl = data.get("rate_limits") or {}
    if not rl.get("five_hour") and not rl.get("seven_day"):
        return
    root = root or next((r for r in SHARED_ROOTS if os.path.isdir(r)), None)
    if not root:
        return
    home = home or os.path.expanduser("~")
    now = int(now if now is not None else time.time())
    email = _grab(os.path.join(home, ".claude.json"), "emailAddress")
    out = {
        "cached_at": now,
        "five_hour": rl.get("five_hour"),
        "seven_day": rl.get("seven_day"),
        "email": email,
        "plan": _grab(os.path.join(home, ".claude", ".credentials.json"), "subscriptionType"),
    }
    folder = os.path.join(root, ".claude-usage")
    if email:
        accounts = os.path.join(folder, "accounts")
        os.makedirs(accounts, exist_ok=True)
        mine = os.path.join(accounts, account_file_name(email))
        # Right after /login the status line may still carry the previous
        # account's limits: both reset instants equal to another account's.
        # Drop them; only the official check can then say anything.
        key = _resets(out)
        if key:
            for name in os.listdir(accounts):
                if name == os.path.basename(mine) or not name.endswith(".json"):
                    continue
                if _resets(_read(os.path.join(accounts, name)) or {}) == key:
                    rl = {}
                    break
        prev = _read(mine) or {}
        api = prev.get("api")
        if not api or now - (api.get("at") or 0) >= API_EVERY:
            got = fetch(home)
            if got:
                api = dict(got, at=now)
        merged = merge_windows(rl, api)
        if not merged.get("five_hour") and not merged.get("seven_day"):
            return
        out.update(merged)
        if api:
            out["api"] = api
        _write(mine, out)
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
