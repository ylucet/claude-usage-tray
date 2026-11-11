# Claude Code Usage Tray

A lightweight **Windows system tray monitor** for [Claude Code](https://claude.ai/code) — shows your 5h session quota and 7-day quota at a glance, with a full usage dashboard, all without leaving your desktop.

> This is a clone of [edi19863/claude-usage-tray](https://github.com/edi19863/claude-usage-tray) with a few extra features (pinnable menu, configurable refresh rate, account email in the header, and a pace projection for your current session — see below).

![Platform](https://img.shields.io/badge/platform-Windows%2010%2F11-0078d4?logo=windows)
![PowerShell](https://img.shields.io/badge/requires-PowerShell%205.1-5391FE?logo=powershell)
![License](https://img.shields.io/badge/license-MIT-22c55e)

---

## Features

- **Color-coded tray icon** that changes based on quota level (green → orange → red → dark red → grey at 100%)
- **Right-click menu** with instant summary: current %, exact reset time, extra-usage status, and the account email in the header
- **Pace projection** for the current session — estimates when you'll hit 100% (or how much headroom you'll have left at reset); falls back to a guess based on the previous session's speed when the current one doesn't have enough data yet
- **Pin the menu** open so it keeps live-updating while you work, instead of closing on click-away
- **Configurable refresh rate** (1/2/5/10/15/30/60 min), persisted across restarts
- **Full HTML dashboard** with 4 tabs — Today / This Week / This Month / All Time
- **Reads your local `~/.claude/projects/*.jsonl` files** directly — no Node.js, no ccusage, no external tools
- **Calls the Anthropic OAuth API** at your configured interval for official quota %; prefers Claude Code's local status-line cache when available (zero extra OAuth calls), and falls back to cached values on rate limit
- **Desktop notification** at 85% and 90% usage

## Icon colors

| Color | Usage |
|-------|-------|
| Green | 0 – 50% |
| Orange | 50 – 80% |
| Red | 80 – 95% |
| Dark red | 95 – 99% |
| Dark grey | 100% |

---

## Dashboard

Click **"Usage history..."** from the right-click menu to open the dashboard in your browser.

### Today
Tokens processed today vs yesterday, sessions active today, and an **hourly bar chart** showing activity across the day.

### This Week / This Month
Total tokens, active days, peak day, daily average, per-day bar chart, day table.

### All Time
Quota trend chart (line, with 80%/95% thresholds), range selector (24h / 7d / all), top sessions by token usage, full statistics summary.

---

## Requirements

- Windows 10 or 11
- PowerShell 5.1 (built into Windows — no install needed)
- Claude Code installed and logged in (`~/.claude/.credentials.json` must exist)

---

## Installation

### Option A — Quick start

1. [Download the ZIP](https://github.com/edi19863/claude-code-usage-tray/archive/refs/heads/main.zip) and extract it anywhere
2. Double-click **`start.vbs`** — the tray icon appears immediately, no console window

### Option B — Auto-start at every login

1. Extract the folder
2. Double-click **`setup-autostart.bat`** — creates a shortcut in your Windows Startup folder (no admin rights needed)

### Option C — Git clone

```
git clone https://github.com/ylucet/claude-usage-tray.git
```

Then run `start.vbs`.

---

## Files

| File | Description |
|------|-------------|
| `claude-tray.ps1` | Main script — tray icon, menu, dashboard, API polling, JSONL parsing |
| `start.vbs` | Silent launcher — starts PowerShell without showing a console window |
| `setup-autostart.bat` | Creates a Windows Startup shortcut for auto-launch at login |
| `statusline-share.py` | Claude Code status line that shares the quota with a tray running as another Windows user |
| `add-bom-restart.ps1` | Dev utility — adds UTF-8 BOM to the script and restarts the tray |

---

## Notes

- **Cost columns are intentionally hidden** — Claude Pro/Max users always have `$0` in their JSONL files.
- Token counts come from local files only. No data leaves your machine except the API quota call.
- If the quota API returns a rate limit (429), the last cached values are used silently.
- **Claude Code running as another Windows user.** The tray cannot read that user's profile, so that user's status-line script shares the quota instead: on each refresh it writes `rate_limits` (plus account email and plan, no secrets) to `<root>\.claude-usage\accounts\<email>.json` and `<root>\.claude-usage\usage.json`, where `<root>` is the first existing of `D:\AI`, `C:\AI-local`. Set that user's `statusLine` command to `statusline-share.py` (absolute path; that user's `HOME` may not be its profile), or copy its `share_usage` function and helpers into an existing status-line script.
- **Several accounts.** When Claude Code switches accounts with `/login`, each account keeps its own shared file, and the menu shows one tab per account. The account Claude Code used most recently is marked `●`; the icon, tooltip alerts and session events follow it. An account not in use shows its last known values as cached; a window whose reset time has passed since then shows 0% ("reset since last seen") — usage outside Claude Code (e.g. claude.ai) is not seen. The tray user's own login, if any, is polled through the OAuth API and used for its account when fresher than the shared file. Pace history and the dashboard's quota chart are per account (the selected tab).
- **Tests:** `python -m unittest discover -s tests` and `powershell -File tests\test-tray-accounts.ps1` (both fast, no network).
- The script uses PowerShell 5.1 and requires UTF-8 BOM encoding. If you edit the `.ps1` file manually, run `add-bom-restart.ps1` afterward.

---

## License

MIT — do whatever you want with it.
