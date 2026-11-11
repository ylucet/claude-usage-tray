# Fast tests for the multi-account logic of claude-tray.ps1 (bucket: fast, a few s).
# Loads only the script's top-level functions (no tray, no network, no profile).
# Run: powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-tray-accounts.ps1
# Exit code = number of failures.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:fail = 0; $script:pass = 0
function Assert($cond, [string]$what) {
    if ($cond) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $what" -ForegroundColor Red }
}

# --- load functions ---------------------------------------------------------
$src = Join-Path $PSScriptRoot "..\claude-tray.ps1"
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $src), [ref]$null, [ref]$null)
$defs = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
    Where-Object { $p = $_.Parent; $nested = $false
                   while ($p) { if ($p -is [System.Management.Automation.Language.FunctionDefinitionAst]) { $nested = $true; break }; $p = $p.Parent }
                   -not $nested }
foreach ($d in $defs) { . ([scriptblock]::Create($d.Extent.Text)) }

# --- sandbox ----------------------------------------------------------------
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("tray-test-" + [guid]::NewGuid())
New-Item -ItemType Directory $tmp | Out-Null
$SharedUsageFile    = Join-Path $tmp ".claude-usage\usage.json"
$SharedAccountsDir  = Join-Path $tmp ".claude-usage\accounts"
$CredFile           = Join-Path $tmp "no-login\.credentials.json"   # no own login
$ClaudeConfigFile   = Join-Path $tmp "no-login\.claude.json"
$RateLimitCacheFile = Join-Path $tmp "no-login\rate-limits-cache.json"
$HistoryFile        = Join-Path $tmp "history.json"
$LogFile            = Join-Path $tmp "log.txt"
$HistoryMaxDays = 30; $CooldownSec = 30; $RefreshRatePresets = @(1,5)
$script:ptZone = [System.TimeZoneInfo]::FindSystemTimeZoneById("Pacific Standard Time")
$script:menuPinned = $false; $script:refreshIntervalMinutes = 5
$script:LastGoodStats = $null; $script:LastCallTime = [datetime]::MinValue

$now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
function Snap($email, [long]$at, $p5, [long]$r5, $p7, [long]$r7) {
    [pscustomobject]@{ cached_at = $at; email = $email; plan = "team"
        five_hour = [pscustomobject]@{ used_percentage = $p5; resets_at = $r5 }
        seven_day = [pscustomobject]@{ used_percentage = $p7; resets_at = $r7 } }
}
function Put($path, $obj) {
    New-Item -ItemType Directory -Force (Split-Path $path) | Out-Null
    [System.IO.File]::WriteAllText($path, ($obj | ConvertTo-Json -Depth 5))
}
function Reset-Shared { Remove-Item -Recurse -Force (Join-Path $tmp ".claude-usage") -ErrorAction SilentlyContinue }

try {
# --- ConvertFrom-Snapshot ---------------------------------------------------
$r = ConvertFrom-Snapshot (Snap "a@x.ca" ($now - 5) 26 ($now + 3600) 22 ($now + 86400))
Assert ($r.Source -eq "live" -and -not $r.Cached) "fresh snapshot is live"
Assert ($r.Session.Utilization -eq 26 -and $r.Week.Utilization -eq 22) "fresh snapshot keeps percentages"
Assert ([math]::Abs(($r.Session.ResetsAt - (Get-Date).AddHours(1)).TotalSeconds) -lt 30) "session reset time converted to local"
Assert ($r.Email -eq "a@x.ca" -and $r.Plan -eq "team") "email and plan carried"

$r = ConvertFrom-Snapshot (Snap "a@x.ca" ($now - 3600) 90 ($now + 600) 40 ($now + 86400))
Assert ($r.Cached -and $r.Source -ne "live") "snapshot older than 10 min is cached"
Assert ($r.Session.Utilization -eq 90) "cached snapshot still within window keeps its value"

$r = ConvertFrom-Snapshot (Snap "a@x.ca" ($now - 7200) 95 ($now - 60) 40 ($now + 86400))
Assert ($r.Session.Utilization -eq 0 -and $r.Session.ResetSince -and $null -eq $r.Session.ResetsAt) "window reset since snapshot -> 0%, marked"
Assert ($r.Week.Utilization -eq 40 -and -not $r.Week.ResetSince) "other window unaffected"

# --- Get-SharedSnapshots: newest per email, case-insensitive ----------------
Reset-Shared
Put (Join-Path $SharedAccountsDir "a@x.ca.json") (Snap "a@x.ca" 100 10 ($now+60) 10 ($now+60))
Put (Join-Path $SharedAccountsDir "b@y.ca.json") (Snap "b@y.ca" 200 20 ($now+60) 20 ($now+60))
Put $SharedUsageFile (Snap "A@X.ca" 300 30 ($now+60) 30 ($now+60))
Put (Join-Path $SharedAccountsDir "c@z.ca.json.tmp") (Snap "c@z.ca" 400 1 1 1 1)
$s = Get-SharedSnapshots
Assert ($s.Count -eq 2) "two accounts (usage.json merged, .tmp ignored): got $($s.Count)"
Assert ([long]$s["a@x.ca"].cached_at -eq 300) "newest snapshot per email wins across files"

# --- Get-AllAccountStats ----------------------------------------------------
Reset-Shared
Put (Join-Path $SharedAccountsDir "zed@x.ca.json") (Snap "zed@x.ca" ($now - 20) 26 ($now+3600) 22 ($now+86400))
Put (Join-Path $SharedAccountsDir "amy@y.ca.json") (Snap "amy@y.ca" ($now - 9000) 99 ($now-100) 70 ($now+86400))
$all = Get-AllAccountStats
Assert ((@($all.Accounts.Keys) -join ",") -eq "amy@y.ca,zed@x.ca") "accounts sorted by email"
Assert ($all.Active -eq "zed@x.ca") "active = most recently shared"
Assert ($all.Accounts["amy@y.ca"].Session.Utilization -eq 0) "inactive account past its reset shows 0"

Reset-Shared
$all = Get-AllAccountStats
Assert ($all.Accounts.Count -eq 1 -and $all.Accounts[""].Error) "no data at all -> one error entry"

# --- history: tagged, no duplicates, per-account rate -----------------------
Remove-Item $HistoryFile -ErrorAction SilentlyContinue
$sa = ConvertFrom-Snapshot (Snap "a@x.ca" ($now - 5) 10 ($now+3600) 5 ($now+86400))
$sb = ConvertFrom-Snapshot (Snap "b@y.ca" ($now - 5) 50 ($now+3600) 5 ($now+86400))
Save-HistoryEntry $sa; Save-HistoryEntry $sa; Save-HistoryEntry $sb
# PS 5.1: ConvertFrom-Json emits an array as ONE object; assign before @() (as the tray does).
$h = Read-JsonFile $HistoryFile; $h = @($h)
Assert ($h.Count -eq 2) "same snapshot saved once per account: got $($h.Count)"
Assert (@($h | Where-Object { $_.email -eq "b@y.ca" -and $_.sess -eq 50 }).Count -eq 1) "entry tagged with its account"

$t0 = (Get-Date).AddMinutes(-60)
$rows = @()
for ($i = 0; $i -le 10; $i++) {
    $rows += [ordered]@{ ts = $t0.AddMinutes($i).ToString("o"); email = "a@x.ca"; sess = [double]$i;     week = 1 }
    $rows += [ordered]@{ ts = $t0.AddMinutes($i).ToString("o"); email = "b@y.ca"; sess = [double](5*$i); week = 1 }
}
Write-JsonFile $HistoryFile $rows
$ra = Get-PreviousSessionRate (Get-Date) "a@x.ca"
$rb = Get-PreviousSessionRate (Get-Date) "b@y.ca"
Assert ($ra -and [math]::Abs($ra - 1) -lt 1e-9) "rate of a = 1 %/min from its own entries: got $ra"
Assert ($rb -and [math]::Abs($rb - 5) -lt 1e-9) "rate of b = 5 %/min from its own entries: got $rb"

# --- tooltip ---------------------------------------------------------------
$acc = [ordered]@{
    "verylongname.forsure@department.example.ca" = $sa
    "another.verylongname@mail.example.ca"       = $sb }
$tt = Get-TrayTooltip $acc "another.verylongname@mail.example.ca" $true
Assert ($tt.Length -le 63) "tooltip fits NotifyIcon's 63 chars: $($tt.Length)"
Assert ($tt.Contains([string][char]0x25CF + "another.verylongname")) "active account marked in tooltip"
$tt1 = Get-TrayTooltip ([ordered]@{ "a@x.ca" = $sa }) "a@x.ca" $false
Assert ($tt1 -eq "Claude  Sess:10% | Week:5% | off-peak") "single-account tooltip unchanged in form: $tt1"
$bt = Get-BalloonText ([ordered]@{ "a@x.ca" = $sa; "b@y.ca" = $sb }) "b@y.ca"
Assert ($bt -match "b@y.ca \(in use\)" -and $bt -match "Session: 10%" -and $bt -match "Session: 50%") "balloon lists both accounts"

# --- menu with tabs ---------------------------------------------------------
$sOld = ConvertFrom-Snapshot (Snap "a@x.ca" ($now - 7200) 80 ($now+600) 30 ($now+86400))
$script:accounts = [ordered]@{ "a@x.ca" = $sOld; "b@y.ca" = $sb }
$script:selectedEmail = $null
$mo = Build-Menu $script:accounts "b@y.ca"
$script:menuObj = $mo
$m = $mo.Menu
$tabHost = $m.Items["TabsHost"]
Assert ($null -ne $tabHost) "two accounts -> tab strip"
Assert ($tabHost.Control.TabPages.Count -eq 2) "one tab per account"
Assert ($tabHost.Control.SelectedTab.Name -eq "b@y.ca") "tab of the account in use selected"
$texts = { param($email) @($m.Items | Where-Object { "$($_.Tag)" -eq "acct:$email" -and $_.Available } | ForEach-Object { $_.Text }) }
$visA = & $texts "a@x.ca"; $visB = & $texts "b@y.ca"
Assert ($visA.Count -eq 0 -and $visB.Count -gt 5) "only the selected account's items shown"
Assert (($visB -join "`n") -match "Claude Team: b@y.ca" -and ($visB -join "`n") -match "In use by Claude Code") "header of selected account"
Assert ($m.Items["PinMenuItem"].Available) "common items always shown"

# A TabControl raises SelectedIndexChanged only once its window exists (as it
# does in the shown menu); create it here, off screen.
$null = $tabHost.Control.Handle
$tabHost.Control.SelectedIndex = 0      # click tab a
$visA = & $texts "a@x.ca"; $visB = & $texts "b@y.ca"
Assert ($visB.Count -eq 0 -and $visA.Count -gt 5) "switching tab shows the other account"
Assert ($script:selectedEmail -eq "a@x.ca" -and $script:stats.Email -eq "a@x.ca") "dashboard follows selected tab"
$ja = $visA -join "`n"
Assert ($ja -match "Not in use - last seen 2h 0min ago" -and $ja -match "\(cached\)") "stale account says so: $ja"
Assert (-not ($ja -match "On pace|Guess")) "no pace projection for an account not in use"

# rebuild in place (pinned refresh) keeps the chosen tab
$mo2 = Build-Menu $script:accounts "b@y.ca" $m
Assert ($m.Items["TabsHost"].Control.SelectedTab.Name -eq "a@x.ca") "refresh keeps selected tab"
$visA = & $texts "a@x.ca"
Assert ($visA.Count -gt 5) "refresh keeps selected tab's items shown"

$script:selectedEmail = $null
$m1 = (Build-Menu ([ordered]@{ "a@x.ca" = $sa }) "a@x.ca").Menu
Assert ($null -eq $m1.Items["TabsHost"]) "single account -> no tab strip"
Assert (@($m1.Items | Where-Object { $_.Text -match "On pace|Guess" }).Count -ge 1) "single live account keeps pace projection"
} catch {
    $script:fail++; Write-Host "ERROR: $_`n$($_.ScriptStackTrace)" -ForegroundColor Red
} finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
Write-Host "$($script:pass) passed, $($script:fail) failed"
exit $script:fail
