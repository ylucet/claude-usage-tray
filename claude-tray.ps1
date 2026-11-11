# Claude Code Usage - System Tray Monitor

# --- Istanza singola --------------------------------------------------------
# Evita icone duplicate quando lo script viene lanciato piu' volte (es. avvio
# automatico al login + avvio manuale). Il mutex e' di sessione ("Local\"):
# ogni sessione interattiva ha la sua area di notifica, quindi la sua icona.
# Il SO rilascia il mutex alla chiusura del processo, anche se viene ucciso.
$script:singleInstanceCreated = $false
$script:singleInstanceMutex   = New-Object System.Threading.Mutex($true, "Local\ClaudeUsageTray", [ref]$script:singleInstanceCreated)
if (-not $script:singleInstanceCreated) {
    # Un'altra istanza ha gia' l'icona: si esce senza toccare nulla.
    exit 0
}

$LogFile = Join-Path $PSScriptRoot "tray-error.log"
if (Test-Path $LogFile) {
    if ((Get-Item $LogFile).Length -gt 102400) {
        Move-Item $LogFile (Join-Path $PSScriptRoot "tray-error.old.log") -Force -ErrorAction SilentlyContinue
    }
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type -MemberDefinition @'
    [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
'@ -Name NativeMethods -Namespace Win32 -ErrorAction SilentlyContinue

$CredFile       = Join-Path $env:USERPROFILE ".claude\.credentials.json"
$ClaudeConfigFile = Join-Path $env:USERPROFILE ".claude.json"
$HistoryFile    = Join-Path $env:USERPROFILE ".claude\claude-usage-history.json"
$ClientId       = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
$HistoryMaxDays = 30
$CooldownSec    = 30

# Quota condivisa dalla status line di Claude Code eseguito come altro utente
# Windows (vedi README). Prima radice esistente; stessa lista della status line.
$SharedUsageFile = $null
foreach ($root in @('D:\AI','C:\AI-local')) {
    if (Test-Path $root) { $SharedUsageFile = Join-Path $root ".claude-usage\usage.json"; break }
}
# Un file per account (accounts\<email>.json): Claude Code passa da un account
# all'altro con /login e l'account lasciato conserva l'ultima quota nota.
$SharedAccountsDir = if ($SharedUsageFile) { Join-Path (Split-Path $SharedUsageFile) "accounts" } else { $null }

$SettingsFile          = Join-Path $env:USERPROFILE ".claude\tray-settings.json"
$DefaultRefreshMinutes = 5
$RefreshRatePresets    = @(1,2,5,10,15,30,60)   # minuti

$script:LastGoodStats    = $null
$script:LastCallTime     = [datetime]::MinValue
$script:lastIconLevel    = -1
$script:lastIconHandle   = [IntPtr]::Zero
$script:notified85       = $false
$script:notified90       = $false
$script:lastIconPeak     = $false
$script:lastSessResetsAt = ""
$script:refreshIntervalMinutes = $DefaultRefreshMinutes
$script:menuPinned       = $false
$script:lastMenuClickedName = $null
$SessionEventFile        = Join-Path $PSScriptRoot "session-event.json"

# ─── Utilità ──────────────────────────────────────────────────────────────────
function Parse-IsoDate($str) {
    if (-not $str) { return $null }
    try {
        return [System.DateTimeOffset]::Parse($str,[System.Globalization.CultureInfo]::InvariantCulture).LocalDateTime
    } catch { return $null }
}
function Read-JsonFile($path) {
    $raw = Get-Content $path -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    if (-not $raw) { return $null }
    return ($raw -replace '^\xEF\xBB\xBF','') | ConvertFrom-Json
}
function Write-JsonFile($path, $obj) {
    [System.IO.File]::WriteAllText($path, ($obj | ConvertTo-Json -Depth 10), [System.Text.Encoding]::UTF8)
}
function Get-AccountEmail {
    # Nota: ~/.claude.json puo' contenere chiavi "projects" duplicate a meno di
    # maiuscole/minuscole (es. C:/Users/x vs C:/users/x), che mandano in errore
    # ConvertFrom-Json (dizionario case-insensitive). Si estrae il campo con una
    # regex mirata invece di fare il parse completo del file.
    try {
        $raw = Get-Content $ClaudeConfigFile -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        if (-not $raw) { return $null }
        if ($raw -match '"emailAddress"\s*:\s*"([^"]*)"') {
            return $Matches[1]
        }
    } catch {}
    return $null
}
function Get-AccountPlan {
    # Il piano di abbonamento e' in ~/.claude/.credentials.json (claudeAiOauth.
    # subscriptionType: free|pro|max|team|enterprise). Si legge con una regex per
    # gli stessi motivi di robustezza di Get-AccountEmail. Fallback: il tier di
    # rate limit in ~/.claude.json (es. "default_claude_max_5x").
    param($plan = $null)
    if (-not $plan) { try {
        $raw = Get-Content $CredFile -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        if ($raw -and $raw -match '"subscriptionType"\s*:\s*"([^"]+)"') { $plan = $Matches[1] }
    } catch {} }
    if (-not $plan) {
        try {
            $raw = Get-Content $ClaudeConfigFile -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
            if ($raw -and $raw -match '"(?:organizationRateLimitTier|userRateLimitTier)"\s*:\s*"([^"]+)"') {
                $tier = $Matches[1]
                foreach ($k in @('enterprise','team','max','pro','free')) {
                    if ($tier -match $k) { $plan = $k; break }
                }
            }
        } catch {}
    }
    if (-not $plan) { return $null }
    switch ($plan.ToLower()) {
        'free'       { return 'Free' }
        'pro'        { return 'Pro' }
        'max'        { return 'Max' }
        'team'       { return 'Team' }
        'enterprise' { return 'Enterprise' }
        default      {
            # Valore sconosciuto: si mostra comunque, con l'iniziale maiuscola.
            if ($plan.Length -eq 1) { return $plan.ToUpper() }
            return $plan.Substring(0,1).ToUpper() + $plan.Substring(1)
        }
    }
}
function Load-Settings {
    $s = $null
    try { $s = Read-JsonFile $SettingsFile } catch { $s = $null }
    $mins = $DefaultRefreshMinutes
    if ($s -and $s.refreshRateMinutes) {
        $candidate = [int]$s.refreshRateMinutes
        if ($candidate -gt 0) { $mins = $candidate }
    }
    $script:refreshIntervalMinutes = $mins
    $script:menuPinned = if ($s -and $null -ne $s.menuPinned) { [bool]$s.menuPinned } else { $false }
}
function Save-Settings {
    try {
        Write-JsonFile $SettingsFile ([pscustomobject]@{ refreshRateMinutes = $script:refreshIntervalMinutes; menuPinned = $script:menuPinned })
    } catch {
        "$([datetime]::Now) Save-Settings ERRORE: $_" | Out-File $LogFile -Append -Encoding UTF8
    }
}
function Fmt-Tokens([long]$n) {
    if ($n -ge 1000000) { return "$([math]::Round($n/1000000,2))M" }
    if ($n -ge 1000)    { return "$([math]::Round($n/1000,1))K" }
    return "$n"
}
$script:ptZone = [System.TimeZoneInfo]::FindSystemTimeZoneById("Pacific Standard Time")
function Get-PacificTime { return [System.TimeZoneInfo]::ConvertTimeFromUtc([datetime]::UtcNow, $script:ptZone) }
function Get-IsPeakHour {
    # Peak = Mon-Fri 05:00-11:00 PT = 8AM-2PM ET = 12PM-6PM GMT (source: claude2x.com)
    $pt  = Get-PacificTime
    $dow = [int]$pt.DayOfWeek   # 0=Sun, 6=Sat
    return ($dow -ge 1 -and $dow -le 5 -and $pt.Hour -ge 5 -and $pt.Hour -lt 11)
}

# ─── Legge JSONL locali (~/.claude/projects/) ────────────────────────────────
function Get-LocalTokenData {
    $projectsDir = Join-Path $env:USERPROFILE ".claude\projects"
    if (-not (Test-Path $projectsDir)) { return $null }
    $byDate    = @{}
    $bySession = @{}
    $byHour    = @{}
    $todayStr  = (Get-Date).ToString("yyyy-MM-dd")
    try {
        $files = Get-ChildItem $projectsDir -Recurse -Filter "*.jsonl" -ErrorAction SilentlyContinue
        foreach ($file in $files) {
            $lines = Get-Content $file.FullName -Encoding UTF8 -ErrorAction SilentlyContinue
            if (-not $lines) { continue }
            foreach ($line in $lines) {
                if (-not $line -or $line.Length -lt 10) { continue }
                try {
                    $e = $line | ConvertFrom-Json -ErrorAction SilentlyContinue
                    if (-not $e -or -not $e.timestamp) { continue }
                    $usage = $null; try { $usage = $e.message.usage } catch { }
                    $cost  = [double]0; try { if ($null -ne $e.costUSD) { $cost = [double]$e.costUSD } } catch { }
                    if (-not $usage -and $cost -eq 0) { continue }
                    $dt = $null
                    try { $dt = [System.DateTimeOffset]::Parse("$($e.timestamp)",[System.Globalization.CultureInfo]::InvariantCulture).LocalDateTime } catch { continue }
                    $date  = $dt.ToString("yyyy-MM-dd")
                    $sid   = if ($e.sessionId)     { "$($e.sessionId)" }     else { "unknown" }
                    $model = if ($e.message.model) { "$($e.message.model)" } else { "" }
                    $inp=[long]0; $out=[long]0; $cc=[long]0; $cr=[long]0
                    if ($usage) {
                        try { $inp = [long]$usage.input_tokens }                    catch { }
                        try { $out = [long]$usage.output_tokens }                   catch { }
                        try { $cc  = [long]$usage.cache_creation_input_tokens }     catch { }
                        try { $cr  = [long]$usage.cache_read_input_tokens }         catch { }
                    }
                    $total = $inp + $out
                    if ($date -eq $todayStr) {
                        $hr = $dt.Hour
                        if (-not $byHour[$hr]) { $byHour[$hr] = @{ hour=$hr; inp=0L; out=0L } }
                        $byHour[$hr].inp += $inp; $byHour[$hr].out += $out
                    }
                    if (-not $byDate[$date]) {
                        $byDate[$date] = @{ date=$date; inp=0L; out=0L; cc=0L; cr=0L; total=0L; cost=0.0; models=@{} }
                    }
                    $byDate[$date].inp   += $inp;  $byDate[$date].out  += $out
                    $byDate[$date].cc    += $cc;   $byDate[$date].cr   += $cr
                    $byDate[$date].total += $total; $byDate[$date].cost += $cost
                    if ($model) { $byDate[$date].models[$model] = 1 }
                    if (-not $bySession[$sid]) {
                        $bySession[$sid] = @{ sid=$sid; inp=0L; out=0L; cc=0L; cr=0L; total=0L; cost=0.0; lastTs=$dt; models=@{} }
                    }
                    $bySession[$sid].inp   += $inp;  $bySession[$sid].out  += $out
                    $bySession[$sid].cc    += $cc;   $bySession[$sid].cr   += $cr
                    $bySession[$sid].total += $total; $bySession[$sid].cost += $cost
                    if ($dt -gt $bySession[$sid].lastTs) { $bySession[$sid].lastTs = $dt }
                    if ($model) { $bySession[$sid].models[$model] = 1 }
                } catch { }
            }
        }
    } catch { }
    if ($byDate.Count -eq 0) { return $null }
    $days     = @($byDate.Values | Sort-Object date)
    $sessions = @($bySession.Values | Sort-Object { $_.total } -Descending | Select-Object -First 20)
    return @{ Days=$days; Sessions=$sessions; Hours=$byHour }
}

# ─── Storico: salva entry ─────────────────────────────────────────────────────
function Save-HistoryEntry($stats) {
    if (-not $stats -or $stats.Error) { return }
    try {
        $history = @()
        if (Test-Path $HistoryFile) { $loaded = Read-JsonFile $HistoryFile; if ($loaded) { $history = @($loaded) } }
        $cutoff  = (Get-Date).AddDays(-$HistoryMaxDays)
        $history = @($history | Where-Object { $d = Parse-IsoDate $_.ts; $d -and $d -gt $cutoff })
        # ts = istante del dato (non del polling): lo stesso snapshot condiviso
        # letto a due refresh consecutivi non viene registrato due volte.
        $ts    = if ($stats.LastUpdated) { ([datetime]$stats.LastUpdated).ToString("o") } else { (Get-Date).ToString("o") }
        $email = if ($stats.Email) { "$($stats.Email)" } else { $null }
        if (@($history | Where-Object { $_.ts -eq $ts -and "$($_.email)" -eq "$email" }).Count) { return }
        $history += [ordered]@{
            ts    = $ts
            email = $email
            sess = if ($null -ne $stats.Session.Utilization) { $stats.Session.Utilization } else { $null }
            week = if ($null -ne $stats.Week.Utilization)    { $stats.Week.Utilization }    else { $null }
        }
        Write-JsonFile $HistoryFile $history
    } catch { }
}

# ─── Dashboard HTML ───────────────────────────────────────────────────────────
function Show-HistoryChart {
  try {
    $history = @()
    if (Test-Path $HistoryFile) { $loaded = Read-JsonFile $HistoryFile; if ($loaded) { $history = @($loaded) } }
    # Solo l'account della scheda selezionata (le voci senza email sono precedenti
    # alla gestione di piu' account).
    $acctEmail = "$($script:stats.Email)"
    if ($acctEmail) { $history = @($history | Where-Object { -not $_.email -or $_.email -eq $acctEmail }) }

    $jsRows =($history | ForEach-Object {
        $ts = if ($_.ts -match '^\d{4}-\d{2}-\d{2}T[\d:+.\-Z]+$') { $_.ts } else { '' }
        $s  = if ("$($_.sess)" -match '^\d+(\.\d+)?$') { $_.sess } else { 'null' }
        $w  = if ("$($_.week)" -match '^\d+(\.\d+)?$') { $_.week } else { 'null' }
        if ($ts) { "{ts:`"$ts`",sess:$s,week:$w}" }
    }) -join ','

    $localData = Get-LocalTokenData
    $days      = if ($localData) { @($localData.Days     | Sort-Object { $_.date }) } else { @() }
    $sessions  = if ($localData) { @($localData.Sessions | Sort-Object { $_.total } -Descending | Select-Object -First 15) } else { @() }

    $jsDays = if ($days.Count) {
        '[' + (($days | ForEach-Object {
            $mods = ($_.models.Keys |
                     Where-Object { $_ -notmatch '<synthetic>|^$' } |
                     ForEach-Object { $_ -replace 'claude-','' -replace '-\d{8}$','' } |
                     Sort-Object -Unique) -join ', '
            $dt2 = [long]$_.inp + [long]$_.out
            "{date:`"$($_.date)`",total:$dt2,inp:$($_.inp),out:$($_.out),models:`"$mods`"}"
        }) -join ',') + ']'
    } else { '[]' }

    $jsSessions = if ($sessions.Count) {
        $i = 0
        '[' + (($sessions | ForEach-Object {
            $i++
            $lts = if ($_.lastTs) { $_.lastTs.ToString("o") } else { '' }
            $dt2 = [long]$_.inp + [long]$_.out
            "{n:$i,total:$dt2,lastTs:`"$lts`"}"
        }) -join ',') + ']'
    } else { '[]' }

    $jsHours = '[' + ((0..23 | ForEach-Object {
        $h2 = $_; $hd = if ($localData -and $localData.Hours) { $localData.Hours[$h2] } else { $null }
        if ($hd) { [long]$hd.inp + [long]$hd.out } else { 0 }
    }) -join ',') + ']'

    $st     = $script:stats
    $sessU  = if ($null -ne $st.Session.Utilization) { [double]$st.Session.Utilization } else { $null }
    $weekU  = if ($null -ne $st.Week.Utilization)    { [double]$st.Week.Utilization }    else { $null }
    $lastSess   = if ($null -ne $sessU) { "$sessU" } else { "?" }
    $lastWeek   = if ($null -ne $weekU) { "$weekU" } else { "?" }
    $sessBarPct = if ($null -ne $sessU) { [math]::Min(100,[math]::Max(0,[int]$sessU)) } else { 0 }
    $weekBarPct = if ($null -ne $weekU) { [math]::Min(100,[math]::Max(0,[int]$weekU)) } else { 0 }
    $lastUpd    = if ($st -and $st.LastUpdated) { $st.LastUpdated.ToString("MM/dd/yyyy HH:mm:ss") } else { "never" }
    $isCached   = if ($st.Cached) { " (cached)" } else { "" }

    function ColU($v) {
        if ($null -eq $v)  { return '#44aa66' }
        if ($v -ge 95)     { '#7a0000' }
        elseif ($v -ge 80) { '#cc2222' }
        elseif ($v -ge 50) { '#cc8800' }
        else               { '#44aa66' }
    }
    $sessColor = ColU $sessU
    $weekColor = ColU $weekU

    $sessReset = if ($st.Session.ResetsAt) {
        $m = [math]::Round(($st.Session.ResetsAt - (Get-Date)).TotalMinutes)
        if ($m -le 0) { "now" } elseif ($m -lt 60) { "in ${m} min" } else { "at " + $st.Session.ResetsAt.ToString("HH:mm") }
    } else { "unknown" }
    $weekReset = if ($st.Week.ResetsAt) {
        $d2 = [math]::Ceiling(($st.Week.ResetsAt - (Get-Date)).TotalDays)
        if ($d2 -le 0) { "today" } elseif ($d2 -eq 1) { "tomorrow" } else { "in $d2 days (" + $st.Week.ResetsAt.ToString("ddd MM/dd") + ")" }
    } else { "unknown" }

    $today    = (Get-Date).ToString("yyyy-MM-dd")
    $yest     = (Get-Date).AddDays(-1).ToString("yyyy-MM-dd")
    $todayRow = $days | Where-Object { $_.date -eq $today } | Select-Object -First 1
    $yestRow  = $days | Where-Object { $_.date -eq $yest }  | Select-Object -First 1
    $todayTk  = if ($todayRow) { [long]$todayRow.inp + [long]$todayRow.out } else { 0 }
    $yestTk   = if ($yestRow)  { [long]$yestRow.inp  + [long]$yestRow.out  } else { 0 }
    $weekStart = (Get-Date).AddDays(-6).ToString("yyyy-MM-dd")
    $monthStr  = (Get-Date).ToString("yyyy-MM")
    $weekTk    = [long]0
    foreach ($dw in @($days | Where-Object { $_.date -ge $weekStart }))  { $weekTk  += [long]$dw.inp + [long]$dw.out }
    $monthTk   = [long]0
    foreach ($dm in @($days | Where-Object { $_.date -like "$monthStr*" })) { $monthTk += [long]$dm.inp + [long]$dm.out }

    $sessVals = @($history | Where-Object { "$($_.sess)" -match '^\d+(\.\d+)?$' } | ForEach-Object { [double]$_.sess })
    $weekVals = @($history | Where-Object { "$($_.week)" -match '^\d+(\.\d+)?$' } | ForEach-Object { [double]$_.week })
    $sAvg = if ($sessVals.Count) { [math]::Round(($sessVals|Measure-Object -Average).Average,1) } else { 'null' }
    $sMax = if ($sessVals.Count) { [math]::Round(($sessVals|Measure-Object -Maximum).Maximum,1) } else { 'null' }
    $wAvg = if ($weekVals.Count) { [math]::Round(($weekVals|Measure-Object -Average).Average,1) } else { 'null' }
    $wMax = if ($weekVals.Count) { [math]::Round(($weekVals|Measure-Object -Maximum).Maximum,1) } else { 'null' }

    $totalTk   = [long]0
    foreach ($dd in $days) { $totalTk += ([long]$dd.inp + [long]$dd.out) }
    $avgDayTk  = if ($days.Count) { [long]($totalTk / $days.Count) } else { 0L }
    $peakDay   = if ($days.Count) { $days | Sort-Object { [long]$_.inp + [long]$_.out } -Descending | Select-Object -First 1 } else { $null }
    $peakDateStr = if ($peakDay) { $peakDay.date } else { '' }
    $peakTkVal   = if ($peakDay) { [long]$peakDay.inp + [long]$peakDay.out } else { 0 }
    $hasLocal    = if ($days.Count -gt 0) { 'true' } else { 'false' }
    $count       = $history.Count
    $daysCount   = $days.Count

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Claude Code Usage</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4/dist/chart.umd.min.js"></script>
<script src="https://cdn.jsdelivr.net/npm/chartjs-adapter-date-fns@3/dist/chartjs-adapter-date-fns.bundle.min.js"></script>
<style>
*{box-sizing:border-box;margin:0;padding:0}
:root{--bg:#0f0f0f;--bg2:#181818;--bg3:#222;--border:#2e2e2e;--text:#e8e8e8;--muted:#888;--accent:#d97706;--blue:#3b82f6;--green:#22c55e;--red:#ef4444;--orange:#f59e0b;--purple:#a855f7}
@media(prefers-color-scheme:light){:root{--bg:#f4f4f4;--bg2:#fff;--bg3:#f0f0f0;--border:#ddd;--text:#111;--muted:#666}}
body{font-family:'Segoe UI',system-ui,sans-serif;background:var(--bg);color:var(--text);padding:20px;max-width:1000px;margin:0 auto;font-size:15px;line-height:1.4}
.hdr{display:flex;align-items:center;justify-content:space-between;flex-wrap:wrap;gap:8px;margin-bottom:18px;padding-bottom:14px;border-bottom:1px solid var(--border)}
.hdr h1{font-size:1.05rem;color:var(--accent);font-weight:700}
.meta{font-size:.78rem;color:var(--muted)}
.qrow{display:grid;grid-template-columns:1fr 1fr;gap:14px;margin-bottom:14px}
@media(max-width:560px){.qrow,.krow{grid-template-columns:1fr}}
.qcard{background:var(--bg2);border:1px solid var(--border);border-radius:12px;padding:16px 20px}
.qlbl{font-size:.69rem;color:var(--muted);text-transform:uppercase;letter-spacing:.07em;margin-bottom:5px}
.qpct{font-size:2.4rem;font-weight:800;line-height:1;margin-bottom:6px}
.qbar{height:8px;background:var(--bg3);border-radius:4px;overflow:hidden;margin-bottom:7px}
.qbar-f{height:100%;border-radius:4px}
.qmeta{font-size:.79rem;color:var(--muted)}
.qmeta strong{color:var(--text)}
.tabs{display:flex;gap:4px;margin-bottom:14px;border-bottom:2px solid var(--border);padding-bottom:0}
.tab{background:none;border:none;border-bottom:2px solid transparent;margin-bottom:-2px;padding:8px 18px;cursor:pointer;font-size:.82rem;color:var(--muted);font-family:inherit;transition:color .15s}
.tab:hover{color:var(--text)}
.tab.active{color:var(--accent);border-bottom-color:var(--accent);font-weight:600}
.panel{display:none}
.panel.active{display:block}
.krow{display:grid;grid-template-columns:repeat(auto-fit,minmax(130px,1fr));gap:12px;margin-bottom:14px}
.kpi{background:var(--bg2);border:1px solid var(--border);border-radius:10px;padding:14px 16px}
.kl{font-size:.67rem;color:var(--muted);text-transform:uppercase;letter-spacing:.06em;margin-bottom:5px}
.kv{font-size:1.45rem;font-weight:700;line-height:1}
.ks{font-size:.69rem;color:var(--muted);margin-top:4px}
.blu{color:var(--blue)}.grn{color:var(--green)}.org{color:var(--orange)}.pur{color:var(--purple)}
.up{color:var(--orange)}.dn{color:var(--green)}
.sec{background:var(--bg2);border:1px solid var(--border);border-radius:12px;padding:16px 20px;margin-bottom:14px}
.st{font-size:.82rem;font-weight:700;margin-bottom:3px}
.ss{font-size:.71rem;color:var(--muted);margin-bottom:12px}
.rbar{display:flex;align-items:center;gap:8px;margin-bottom:12px;flex-wrap:wrap}
.rtab{background:var(--bg3);border:1px solid var(--border);border-radius:6px;padding:4px 14px;cursor:pointer;font-size:.75rem;color:var(--muted);font-family:inherit}
.rtab.active{background:var(--accent);border-color:var(--accent);color:#fff;font-weight:600}
.rinfo{font-size:.71rem;color:var(--muted)}
canvas{width:100%!important;display:block}
.legend{display:flex;gap:14px;margin-top:10px;font-size:.73rem;color:var(--muted);flex-wrap:wrap}
.dot{display:inline-block;width:9px;height:9px;border-radius:50%;margin-right:4px;vertical-align:middle}
table{width:100%;border-collapse:collapse;font-size:.81rem}
th{text-align:left;padding:7px 10px;color:var(--muted);font-size:.67rem;text-transform:uppercase;letter-spacing:.05em;border-bottom:1px solid var(--border)}
td{padding:7px 10px;border-bottom:1px solid var(--border)}
tr:last-child td{border-bottom:none}
tr:hover td{background:var(--bg3)}
.num{text-align:right;font-variant-numeric:tabular-nums;font-family:'Consolas',monospace}
.s2{display:grid;grid-template-columns:1fr 1fr;gap:10px}
@media(max-width:560px){.s2{grid-template-columns:1fr}}
.sr{display:flex;justify-content:space-between;align-items:center;padding:6px 0;border-bottom:1px solid var(--border);font-size:.82rem}
.sr:last-child{border-bottom:none}
.sk{color:var(--muted)}.sv{font-weight:600}
.nodata{text-align:center;padding:28px;color:var(--muted);font-size:.84rem}
</style>
</head>
<body>
<div class="hdr">
  <h1>Claude Code &mdash; Usage Monitor</h1>
  <span class="meta">Updated: $lastUpd$isCached</span>
</div>

<div class="qrow">
  <div class="qcard">
    <div class="qlbl">Session quota &mdash; 5h window</div>
    <div class="qpct" style="color:$sessColor">$lastSess%</div>
    <div class="qbar"><div class="qbar-f" style="width:${sessBarPct}%;background:$sessColor"></div></div>
    <div class="qmeta">Resets: <strong>$sessReset</strong></div>
  </div>
  <div class="qcard">
    <div class="qlbl">Weekly quota &mdash; 7d window</div>
    <div class="qpct" style="color:$weekColor">$lastWeek%</div>
    <div class="qbar"><div class="qbar-f" style="width:${weekBarPct}%;background:$weekColor"></div></div>
    <div class="qmeta">Resets: <strong>$weekReset</strong></div>
  </div>
</div>

<nav class="tabs">
  <button class="tab active" data-tab="today" onclick="switchTab('today')">Today</button>
  <button class="tab" data-tab="week" onclick="switchTab('week')">This Week</button>
  <button class="tab" data-tab="month" onclick="switchTab('month')">This Month</button>
  <button class="tab" data-tab="history" onclick="switchTab('history')">All Time</button>
</nav>

<!-- TODAY -->
<div id="tab-today" class="panel active">
  <div class="krow">
    <div class="kpi"><div class="kl">Tokens today</div><div class="kv blu" id="kT1">--</div><div class="ks" id="kT1s">&nbsp;</div></div>
    <div class="kpi"><div class="kl">vs Yesterday</div><div class="kv" id="kT2">--</div><div class="ks" id="kT2s">&nbsp;</div></div>
    <div class="kpi"><div class="kl">Sessions today</div><div class="kv grn" id="kT3">--</div><div class="ks">active today</div></div>
    <div class="kpi"><div class="kl">Peak hour</div><div class="kv org" id="kT4">--</div><div class="ks" id="kT4s">&nbsp;</div></div>
  </div>
  <div class="sec">
    <div class="st">Tokens by hour</div>
    <div class="ss">Input + output tokens per hour for today. Blue = low, orange = medium, red = high relative to peak.</div>
    <canvas id="cHour" height="150"></canvas>
  </div>
  <div class="sec">
    <div class="st">Sessions active today</div>
    <div id="tblToday"></div>
  </div>
</div>

<!-- THIS WEEK -->
<div id="tab-week" class="panel">
  <div class="krow">
    <div class="kpi"><div class="kl">Tokens this week</div><div class="kv blu" id="kW1">--</div><div class="ks">last 7 days</div></div>
    <div class="kpi"><div class="kl">Active days</div><div class="kv grn" id="kW2">--</div><div class="ks">out of 7</div></div>
    <div class="kpi"><div class="kl">Peak day</div><div class="kv org" id="kW3" style="font-size:1.05rem;padding-top:4px">--</div><div class="ks" id="kW3s">&nbsp;</div></div>
    <div class="kpi"><div class="kl">Daily average</div><div class="kv pur" id="kW4">--</div><div class="ks">tokens / day</div></div>
  </div>
  <div class="sec">
    <div class="st">Tokens per day &mdash; last 7 days</div>
    <canvas id="cWeek" height="150"></canvas>
  </div>
  <div class="sec">
    <div class="st">Day breakdown</div>
    <div id="tblWeek"></div>
  </div>
</div>

<!-- THIS MONTH -->
<div id="tab-month" class="panel">
  <div class="krow">
    <div class="kpi"><div class="kl">Tokens this month</div><div class="kv blu" id="kM1">--</div><div class="ks" id="kM1s">&nbsp;</div></div>
    <div class="kpi"><div class="kl">Active days</div><div class="kv grn" id="kM2">--</div><div class="ks">this month</div></div>
    <div class="kpi"><div class="kl">Peak day</div><div class="kv org" id="kM3" style="font-size:1.05rem;padding-top:4px">--</div><div class="ks" id="kM3s">&nbsp;</div></div>
    <div class="kpi"><div class="kl">Daily average</div><div class="kv pur" id="kM4">--</div><div class="ks">tokens / day</div></div>
  </div>
  <div class="sec">
    <div class="st">Tokens per day &mdash; this month</div>
    <canvas id="cMonth" height="150"></canvas>
  </div>
  <div class="sec">
    <div class="st">Day breakdown</div>
    <div id="tblMonth"></div>
  </div>
</div>

<!-- ALL TIME -->
<div id="tab-history" class="panel">
  <div class="sec">
    <div class="st">Quota usage over time</div>
    <div class="ss">Percentage of quota consumed per measurement. A drop to 0 is normal &mdash; the window expired and reset.</div>
    <div class="rbar">
      <button class="rtab active" onclick="setRange(1)">Last 24h</button>
      <button class="rtab" onclick="setRange(7)">Last 7 days</button>
      <button class="rtab" onclick="setRange(30)">All history</button>
      <span class="rinfo" id="rInfo"></span>
    </div>
    <canvas id="cUsage" height="200"></canvas>
    <div class="legend">
      <span><span class="dot" style="background:#d97706"></span>Session (5h)</span>
      <span><span class="dot" style="background:#3b82f6"></span>Weekly (7d)</span>
      <span style="opacity:.55"><span class="dot" style="background:#f59e0b;border-radius:2px"></span>Warning threshold (80%)</span>
      <span style="opacity:.55"><span class="dot" style="background:#ef4444;border-radius:2px"></span>Critical threshold (95%)</span>
    </div>
  </div>
  <div class="krow">
    <div class="kpi"><div class="kl">Total tokens</div><div class="kv blu" id="kH1">--</div><div class="ks">all time</div></div>
    <div class="kpi"><div class="kl">All-time peak</div><div class="kv org" id="kH2" style="font-size:1.05rem;padding-top:4px">--</div><div class="ks" id="kH2s">&nbsp;</div></div>
    <div class="kpi"><div class="kl">Daily average</div><div class="kv pur" id="kH3">--</div><div class="ks" id="kH3s">&nbsp;</div></div>
    <div class="kpi"><div class="kl">Avg session quota</div><div class="kv" id="kH4">--</div><div class="ks">$count measurements</div></div>
  </div>
  <div class="sec">
    <div class="st">Top sessions</div>
    <div class="ss">Top 15 sessions by token usage. One session = one conversation with Claude.</div>
    <div id="tblSess"></div>
  </div>
  <div class="sec">
    <div class="st">All days</div>
    <div id="tblAll"></div>
  </div>
  <div class="sec">
    <div class="st">Statistics summary</div>
    <div class="ss">Based on $count quota measurements and $daysCount days of local logs.</div>
    <div class="s2">
      <div>
        <div class="sr"><span class="sk">Average session quota (5h)</span><span class="sv" id="sAvgEl">--</span></div>
        <div class="sr"><span class="sk">Peak session quota</span><span class="sv" id="sMaxEl">--</span></div>
        <div class="sr"><span class="sk">Average weekly quota (7d)</span><span class="sv" id="wAvgEl">--</span></div>
        <div class="sr"><span class="sk">Peak weekly quota</span><span class="sv" id="wMaxEl">--</span></div>
      </div>
      <div>
        <div class="sr"><span class="sk">Total tokens processed</span><span class="sv" id="totTkEl">--</span></div>
        <div class="sr"><span class="sk">Average tokens per day</span><span class="sv" id="avgDEl">--</span></div>
        <div class="sr"><span class="sk">Record day</span><span class="sv" id="peakDEl">--</span></div>
        <div class="sr"><span class="sk">Days with activity</span><span class="sv" id="actDEl">--</span></div>
      </div>
    </div>
  </div>
</div>

<script>
var ALL_DATA=[$jsRows];
var DAYS=$jsDays;
var SESSIONS=$jsSessions;
var HOURS=$jsHours;
var TODAY='$today';
var HAS_LOCAL=$hasLocal;
var STATS={sAvg:$sAvg,sMax:$sMax,wAvg:$wAvg,wMax:$wMax,totalTk:$totalTk,avgDayTk:$avgDayTk,count:$count,peakDate:'$peakDateStr',peakTk:$peakTkVal,weekTk:$weekTk,monthTk:$monthTk,todayTk:$todayTk,yestTk:$yestTk};

function fmtTk(n){if(!n||isNaN(n)||n===0)return '--';if(n>=1e6)return(n/1e6).toFixed(1)+'\u00a0M';if(n>=1000)return Math.round(n/1000)+'\u00a0K';return String(n);}
function fmtD(s){var d=new Date(s+'T12:00:00');return d.toLocaleDateString('en-US',{weekday:'short',month:'2-digit',day:'2-digit'});}
function fmtTs(s){if(!s)return '--';var d=new Date(s);return d.toLocaleString('en-US',{month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',hour12:false});}
function pct(v){return(v!=null&&v!=='null')?v+'%':'--';}
function g(id){return document.getElementById(id);}
function st(id,v){var e=g(id);if(e)e.textContent=v;}
function barColors(data,mx){return data.map(function(v){var r=mx>0?v/mx:0;return r>=.8?'rgba(239,68,68,.75)':r>=.5?'rgba(245,158,11,.75)':'rgba(59,130,246,.75)';});}
function mkBar(id,labels,data){
  var mx=Math.max.apply(null,data.concat([1]));
  new Chart(g(id).getContext('2d'),{type:'bar',
    data:{labels:labels,datasets:[{label:'Tokens',data:data,backgroundColor:barColors(data,mx),borderRadius:4}]},
    options:{responsive:true,plugins:{legend:{display:false},tooltip:{callbacks:{label:function(c){return' '+fmtTk(c.parsed.y);}}}},
      scales:{x:{ticks:{color:'#888',font:{size:10},maxRotation:0},grid:{display:false}},
              y:{ticks:{color:'#888',callback:function(v){return fmtTk(v);},font:{size:10}},grid:{color:'rgba(128,128,128,.08)'}}}}});
}
function mkDayTable(el,arr){
  if(!arr||!arr.length){el.innerHTML='<div class="nodata">No data available.</div>';return;}
  var h='<table><thead><tr><th>Day</th><th class="num">Tokens</th><th>Models</th></tr></thead><tbody>';
  arr.slice().reverse().forEach(function(d){
    h+='<tr><td>'+fmtD(d.date)+'</td><td class="num"><strong>'+fmtTk(d.total)+'</strong></td><td style="color:#888;font-size:.78rem">'+(d.models||'--')+'</td></tr>';
  });
  el.innerHTML=h+'</tbody></table>';
}

var inited={};
function switchTab(id){
  document.querySelectorAll('.tab').forEach(function(t){t.classList.toggle('active',t.dataset.tab===id);});
  document.querySelectorAll('.panel').forEach(function(p){p.classList.toggle('active',p.id==='tab-'+id);});
  if(!inited[id]){inited[id]=true;({today:initToday,week:initWeek,month:initMonth,history:initHistory})[id]();}
}

function initToday(){
  st('kT1',fmtTk(STATS.todayTk));
  if(STATS.todayTk&&STATS.yestTk){
    var p=Math.round((STATS.todayTk-STATS.yestTk)/STATS.yestTk*100);
    var el=g('kT2');if(el){el.textContent=(p>0?'+':'')+p+'%';el.className='kv '+(p>0?'up':p<0?'dn':'');}
    st('kT2s','vs yesterday ('+fmtTk(STATS.yestTk)+')');
  }else{st('kT2','--');st('kT2s','no yesterday data');}
  st('kT1s',STATS.todayTk?'yesterday: '+fmtTk(STATS.yestTk):'');
  var maxV=0,maxH=0;
  HOURS.forEach(function(v,i){if(v>maxV){maxV=v;maxH=i;}});
  st('kT4',maxV>0?maxH+':00':'--');
  st('kT4s',maxV>0?fmtTk(maxV)+' tokens':'no activity');
  var todaySess=SESSIONS.filter(function(s){return s.lastTs&&new Date(s.lastTs).toISOString().slice(0,10)===TODAY;});
  st('kT3',String(todaySess.length));
  mkBar('cHour',HOURS.map(function(_,i){return i+':00';}),HOURS);
  var el=g('tblToday');
  if(!todaySess.length){el.innerHTML='<div class="nodata">No sessions active today.</div>';return;}
  var h='<table><thead><tr><th>Session</th><th class="num">Tokens</th><th>Last active</th></tr></thead><tbody>';
  todaySess.forEach(function(s){h+='<tr><td>Session\u00a0'+s.n+'</td><td class="num"><strong>'+fmtTk(s.total)+'</strong></td><td style="color:#888">'+fmtTs(s.lastTs)+'</td></tr>';});
  el.innerHTML=h+'</tbody></table>';
}

function initWeek(){
  var cut=new Date(Date.now()-6*864e5).toISOString().slice(0,10);
  var wd=DAYS.filter(function(d){return d.date>=cut;});
  var wt=STATS.weekTk;
  var act=wd.filter(function(d){return d.total>0;}).length;
  var pk=wd.reduce(function(a,b){return(b.total||0)>(a.total||0)?b:a;},{total:0,date:''});
  var avg=wd.length?Math.round(wt/wd.length):0;
  st('kW1',fmtTk(wt));st('kW2',act+' / 7');
  st('kW3',pk.date?fmtD(pk.date):'--');st('kW3s',pk.date?fmtTk(pk.total):'');
  st('kW4',fmtTk(avg));
  mkBar('cWeek',wd.map(function(d){return fmtD(d.date);}),wd.map(function(d){return d.total||0;}));
  mkDayTable(g('tblWeek'),wd);
}

function initMonth(){
  var mp=TODAY.slice(0,7);
  var md=DAYS.filter(function(d){return d.date.slice(0,7)===mp;});
  var mt=STATS.monthTk;
  var act=md.filter(function(d){return d.total>0;}).length;
  var pk=md.reduce(function(a,b){return(b.total||0)>(a.total||0)?b:a;},{total:0,date:''});
  var avg=md.length?Math.round(mt/md.length):0;
  var mLabel=new Date(mp+'-15').toLocaleDateString('en-US',{month:'long',year:'numeric'});
  st('kM1',fmtTk(mt));st('kM1s',mLabel);
  st('kM2',act+' days');
  st('kM3',pk.date?fmtD(pk.date):'--');st('kM3s',pk.date?fmtTk(pk.total):'');
  st('kM4',fmtTk(avg));
  mkBar('cMonth',md.map(function(d){return fmtD(d.date);}),md.map(function(d){return d.total||0;}));
  mkDayTable(g('tblMonth'),md);
}

var cUsageChart=null;
function setRange(days){
  var rTabs=document.querySelectorAll('.rtab');
  rTabs.forEach(function(t,i){t.classList.toggle('active',[1,7,30][i]===days);});
  if(!cUsageChart)return;
  var cut=new Date(Date.now()-days*864e5);
  var rows=days>=30?ALL_DATA:ALL_DATA.filter(function(d){return d.ts&&new Date(d.ts)>=cut;});
  var info=g('rInfo');
  if(!rows.length){if(info)info.textContent='No data in this period';cUsageChart.data.datasets.forEach(function(ds){ds.data=[];});cUsageChart.update();return;}
  var x0=rows[0].ts,x1=rows[rows.length-1].ts;
  cUsageChart.data.datasets[0].data=rows.map(function(d){return{x:d.ts,y:d.sess};});
  cUsageChart.data.datasets[1].data=rows.map(function(d){return{x:d.ts,y:d.week};});
  cUsageChart.data.datasets[2].data=[{x:x0,y:80},{x:x1,y:80}];
  cUsageChart.data.datasets[3].data=[{x:x0,y:95},{x:x1,y:95}];
  cUsageChart.update();
  var f=new Date(rows[0].ts).toLocaleDateString('en-US',{month:'2-digit',day:'2-digit'});
  var t2=new Date(rows[rows.length-1].ts).toLocaleDateString('en-US',{month:'2-digit',day:'2-digit'});
  if(info)info.textContent=rows.length+' measurements'+(f!==t2?' ('+f+' to '+t2+')':'');
}

function initHistory(){
  st('kH1',fmtTk(STATS.totalTk));
  if(STATS.peakDate){st('kH2',fmtD(STATS.peakDate));st('kH2s',fmtTk(STATS.peakTk));}
  st('kH3',fmtTk(STATS.avgDayTk));st('kH3s',DAYS.length+' days avg');
  st('kH4',pct(STATS.sAvg));
  st('sAvgEl',pct(STATS.sAvg));st('sMaxEl',pct(STATS.sMax));
  st('wAvgEl',pct(STATS.wAvg));st('wMaxEl',pct(STATS.wMax));
  st('totTkEl',fmtTk(STATS.totalTk));st('avgDEl',fmtTk(STATS.avgDayTk));
  if(STATS.peakDate)st('peakDEl',fmtD(STATS.peakDate)+' \u2014 '+fmtTk(STATS.peakTk));
  st('actDEl',DAYS.length+' days');
  var sel=g('tblSess');
  if(!SESSIONS.length){sel.innerHTML='<div class="nodata">No session data.</div>';}
  else{
    var h='<table><thead><tr><th>Session</th><th class="num">Tokens</th><th>Last active</th></tr></thead><tbody>';
    SESSIONS.forEach(function(s){h+='<tr><td>Session\u00a0'+s.n+'</td><td class="num"><strong>'+fmtTk(s.total)+'</strong></td><td style="color:#888">'+fmtTs(s.lastTs)+'</td></tr>';});
    sel.innerHTML=h+'</tbody></table>';
  }
  mkDayTable(g('tblAll'),DAYS);
  var ctxU=g('cUsage').getContext('2d');
  cUsageChart=new Chart(ctxU,{type:'line',data:{datasets:[
    {label:'Session 5h',borderColor:'#d97706',backgroundColor:'rgba(217,119,6,.07)',pointRadius:2,pointHoverRadius:5,tension:.3,yAxisID:'y',data:[]},
    {label:'Weekly 7d',borderColor:'#3b82f6',backgroundColor:'rgba(59,130,246,.07)',pointRadius:2,pointHoverRadius:5,tension:.3,yAxisID:'y',data:[]},
    {label:'Warning 80%',borderColor:'rgba(245,158,11,.4)',borderDash:[6,4],pointRadius:0,fill:false,yAxisID:'y',data:[]},
    {label:'Critical 95%',borderColor:'rgba(239,68,68,.45)',borderDash:[3,3],pointRadius:0,fill:false,yAxisID:'y',data:[]}
  ]},options:{responsive:true,interaction:{mode:'index',intersect:false},
    plugins:{legend:{display:false},tooltip:{callbacks:{
      title:function(it){return new Date(it[0].parsed.x).toLocaleString('en-US',{month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',hour12:false});},
      label:function(it){if(it.datasetIndex>=2)return null;return'  '+it.dataset.label+': '+(it.parsed.y!=null?it.parsed.y.toFixed(1)+'%':'N/A');},
      filter:function(it){return it.datasetIndex<2;}
    }}},
    scales:{
      x:{type:'time',time:{tooltipFormat:'MM/dd HH:mm'},ticks:{color:'#888',maxRotation:0,font:{size:11}},grid:{color:'rgba(128,128,128,.07)'}},
      y:{min:0,max:100,ticks:{color:'#888',callback:function(v){return v+'%';},font:{size:11}},grid:{color:'rgba(128,128,128,.07)'}}
    }
  }});
  setRange(1);
}

inited['today']=true;
initToday();
</script>
</body>
</html>
"@

    $htmlPath = Join-Path $env:TEMP "claude-usage-dashboard.html"
    [System.IO.File]::WriteAllText($htmlPath, $html, [System.Text.Encoding]::UTF8)
    Start-Process $htmlPath
  } catch {
    "$([datetime]::Now) Show-HistoryChart ERRORE: $_`n$($_.ScriptStackTrace)" | Out-File $LogFile -Append -Encoding UTF8
  }
}
# ─── Credenziali ──────────────────────────────────────────────────────────────
function Get-Credentials {
    $all = Read-JsonFile $CredFile
    if (-not $all) { return $null }
    return $all.claudeAiOauth
}

# ─── Refresh token ────────────────────────────────────────────────────────────
function Invoke-TokenRefresh([bool]$force = $false) {
    $creds = Get-Credentials
    if (-not $creds -or -not $creds.refreshToken) { return $creds }
    $now = [long](([datetime]::UtcNow - [datetime]'1970-01-01').TotalMilliseconds)
    if (-not $force -and $creds.expiresAt -gt ($now + 60000)) { return $creds }
    if (-not $force) {
        $fresh = Get-Credentials
        if ($fresh -and $fresh.accessToken -ne $creds.accessToken) { return $fresh }
        if ($fresh -and $fresh.expiresAt -gt ($now + 60000)) { return $fresh }
    }
    try {
        $body = "grant_type=refresh_token&refresh_token=$([System.Uri]::EscapeDataString($creds.refreshToken))&client_id=$ClientId"
        $resp = Invoke-WebRequest `
            -Uri "https://api.anthropic.com/v1/oauth/token" `
            -Method Post -ContentType "application/x-www-form-urlencoded" `
            -Headers @{ "User-Agent"="claude-code/2.1.78"; "anthropic-beta"="oauth-2025-04-20" } `
            -Body $body -UseBasicParsing -ErrorAction Stop
        $data = $resp.Content | ConvertFrom-Json
        $all  = Read-JsonFile $CredFile
        $nowMs= [long](([datetime]::UtcNow - [datetime]'1970-01-01').TotalMilliseconds)
        $all.claudeAiOauth.accessToken  = $data.access_token
        $all.claudeAiOauth.refreshToken = $data.refresh_token
        $all.claudeAiOauth.expiresAt    = $nowMs + ([long]$data.expires_in * 1000L)
        Write-JsonFile $CredFile $all
        return $all.claudeAiOauth
    } catch { return $creds }
}

# ─── Cache stdin (Claude Code status line) ────────────────────────────────────
$RateLimitCacheFile = Join-Path $env:USERPROFILE ".claude\rate-limits-cache.json"
function Read-CacheFile($path, [long]$maxAgeSec) {
    if (-not $path -or -not (Test-Path $path)) { return $null }
    try {
        $c = Read-JsonFile $path
        if (-not $c -or -not $c.cached_at) { return $null }
        # Non [datetime]::new(1970,1,1,0,0,0,'Utc'): in PS 5.1 'Utc' finisce nei
        # millisecondi, l'eccezione restituiva sempre $null e la cache non veniva mai usata.
        $nowUnix = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        if (($nowUnix - [long]$c.cached_at) -gt $maxAgeSec) { return $null }
        return $c
    } catch { return $null }
}

# ─── Account condivisi (status line di Claude Code, altro utente Windows) ─────
# Ultimo snapshot per account: i file accounts\*.json piu' usage.json (scritto
# anche dalle status line precedenti). Per ogni email vince il piu' recente.
function Get-SharedSnapshots {
    $byEmail = [ordered]@{}   # chiavi case-insensitive
    $files = @()
    if ($SharedAccountsDir -and (Test-Path $SharedAccountsDir)) {
        $files += @(Get-ChildItem $SharedAccountsDir -Filter '*.json' -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.Extension -eq '.json' } | ForEach-Object { $_.FullName })
    }
    if ($SharedUsageFile) { $files += $SharedUsageFile }
    foreach ($f in $files) {
        $c = Read-CacheFile $f ([long]::MaxValue)
        if (-not $c -or -not $c.email) { continue }
        $prev = $byEmail[$c.email]
        if (-not $prev -or [long]$c.cached_at -gt [long]$prev.cached_at) { $byEmail[$c.email] = $c }
    }
    return $byEmail
}

# Snapshot (formato status line) -> statistiche del menu. Piu' vecchio di
# $freshSec = "Cached". Una finestra il cui reset e' gia' passato e' ripartita
# da 0 (salvo uso fuori da Claude Code, che la status line non vede).
function ConvertFrom-Snapshot($sc, [long]$freshSec = 600) {
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $r = [ordered]@{
        Session     = [ordered]@{}
        Week        = [ordered]@{}
        ExtraUsage  = $null          # la status line non lo riporta
        Error       = ""
        Email       = $sc.email
        Plan        = $sc.plan
        LastUpdated = [DateTimeOffset]::FromUnixTimeSeconds([long]$sc.cached_at).LocalDateTime
    }
    foreach ($p in @(@('five_hour','Session'), @('seven_day','Week'))) {
        $w = $sc.($p[0])
        if (-not $w) { continue }
        $rs = [long]$w.resets_at
        if ($rs -gt 0 -and $rs -le $now) {
            $r[$p[1]] = [ordered]@{ Utilization = 0.0; ResetsAt = $null; ResetSince = $true }
        } else {
            $r[$p[1]] = [ordered]@{
                Utilization = [math]::Round([double]$w.used_percentage, 1)
                ResetsAt    = if ($rs -gt 0) { [DateTimeOffset]::FromUnixTimeSeconds($rs).LocalDateTime } else { $null }
            }
        }
    }
    if (($now - [long]$sc.cached_at) -gt $freshSec) { $r["Cached"] = $true } else { $r["Source"] = "live" }
    return $r
}

function Copy-AsCached($s) {
    $c = [ordered]@{}
    foreach ($k in $s.Keys) { if ($k -ne "Source") { $c[$k] = $s[$k] } }
    $c["Cached"] = $true
    return $c
}

# ─── Login proprio (utente Windows del tray) ──────────────────────────────────
function Get-OwnLoginStats {
    param([bool]$retried = $false)
    $result = [ordered]@{
        Session     = [ordered]@{}
        Week        = [ordered]@{}
        ExtraUsage  = $false
        Error       = ""
        Email       = Get-AccountEmail
        Plan        = $null
        LastUpdated = (Get-Date)
    }
    # Priorità 1: cache stdin della status line di questo utente (zero OAuth calls)
    if (-not $retried) {
        $sc = Read-CacheFile $RateLimitCacheFile 600
        if ($sc) {
            $r = ConvertFrom-Snapshot $sc
            if (-not $r.Email) { $r.Email = $result.Email }
            $script:LastGoodStats = $r
            return $r
        }
    }
    # Priorità 2: cooldown cache OAuth
    $elapsed = ((Get-Date) - $script:LastCallTime).TotalSeconds
    if (-not $retried -and $elapsed -lt $CooldownSec -and $script:LastGoodStats) {
        return Copy-AsCached $script:LastGoodStats
    }
    $script:LastCallTime = Get-Date
    try {
        $creds = Invoke-TokenRefresh
        if (-not $creds -or -not $creds.accessToken) { throw "Nessun token trovato" }
        $result.Plan = $creds.subscriptionType
        $resp = Invoke-WebRequest `
            -Uri "https://api.anthropic.com/api/oauth/usage" `
            -Method Get `
            -Headers @{
                "Authorization"  = "Bearer $($creds.accessToken)"
                "Content-Type"   = "application/json"
                "User-Agent"     = "claude-code/2.1.78"
                "anthropic-beta" = "oauth-2025-04-20"
            } -UseBasicParsing -ErrorAction Stop
        $data = $resp.Content | ConvertFrom-Json
        if ($data.five_hour) {
            $result.Session = [ordered]@{
                Utilization = [math]::Round([double]$data.five_hour.utilization,1)
                ResetsAt    = Parse-IsoDate $data.five_hour.resets_at
            }
        }
        if ($data.seven_day) {
            $result.Week = [ordered]@{
                Utilization = [math]::Round([double]$data.seven_day.utilization,1)
                ResetsAt    = Parse-IsoDate $data.seven_day.resets_at
            }
        }
        if ($data.extra_usage -and $null -ne $data.extra_usage.is_enabled) {
            $result.ExtraUsage = [bool]$data.extra_usage.is_enabled
        }
    } catch {
        $msg = $_.Exception.Message
        if ($msg -match "401" -and -not $retried) {
            $nc = Invoke-TokenRefresh -force $true
            if ($nc) { return Get-OwnLoginStats -retried $true }
        }
        # Rate limit o qualsiasi errore: restituisce cache se disponibile
        if ($script:LastGoodStats) { return Copy-AsCached $script:LastGoodStats }
        $result.Error = if ($msg -match "429") { "Rate limit - dati in cache" } else {
            $s = $msg.Substring(0,[Math]::Min(77,$msg.Length)); if ($msg.Length -gt 77) { $s+'...' } else { $s }
        }
    }
    if (-not $result.Error) {
        $result["Source"] = "live"
        $script:LastGoodStats = $result
    }
    return $result
}

# ─── Tutti gli account ────────────────────────────────────────────────────────
# Accounts: email -> statistiche, in ordine alfabetico (schede stabili).
# Active: l'account in uso da Claude Code = snapshot condiviso piu' recente;
# senza file condivisi, il login proprio. L'icona mostra l'account attivo.
function Get-AllAccountStats {
    $acc    = [ordered]@{}
    $active = $null
    $newest = [long]-1
    $snaps  = Get-SharedSnapshots
    foreach ($e in @($snaps.Keys)) {
        $acc[$e] = ConvertFrom-Snapshot $snaps[$e]
        if ([long]$snaps[$e].cached_at -gt $newest) { $newest = [long]$snaps[$e].cached_at; $active = $e }
    }
    # Login proprio: solo se il suo account non ha gia' un dato condiviso fresco.
    $own = $null
    if (Test-Path $CredFile) {
        $ownEmail = Get-AccountEmail
        $sh = if ($ownEmail) { $acc[$ownEmail] } else { $null }
        if (-not ($sh -and $sh.Source -eq 'live')) {
            $own = Get-OwnLoginStats
            if ($own -and -not $own.Error) {
                $key = if ($own.Email) { "$($own.Email)" } else { "(this Windows user)" }
                if (-not $sh -or $own.LastUpdated -gt $sh.LastUpdated) { $acc[$key] = $own }
                if (-not $active) { $active = $key }
            }
        }
    }
    $sorted = [ordered]@{}
    foreach ($k in @($acc.Keys | Sort-Object)) { $sorted[$k] = $acc[$k] }
    if ($sorted.Count -eq 0) {
        $sorted[""] = if ($own) { $own } else {
            [ordered]@{ Session=[ordered]@{}; Week=[ordered]@{}; ExtraUsage=$null
                        Error="No Claude login or shared quota found"; LastUpdated=(Get-Date) }
        }
        $active = ""
    }
    return [pscustomobject]@{ Accounts = $sorted; Active = $active }
}

function Save-AllHistory($accounts) {
    foreach ($e in @($accounts.Keys)) {
        $s = $accounts[$e]
        if ($e -and $s.Source -eq 'live') { Save-HistoryEntry $s }
    }
}

# Legge tutti gli account; $script:stats = account della scheda selezionata
# (usato dalla dashboard), di default quello in uso.
function Update-Accounts {
    $r = Get-AllAccountStats
    $script:accounts    = $r.Accounts
    $script:activeEmail = $r.Active
    $sel = if ($script:selectedEmail -and $script:accounts.Contains($script:selectedEmail)) { $script:selectedEmail } else { $script:activeEmail }
    $script:stats = $script:accounts[$sel]
    Save-AllHistory $script:accounts
}

function Format-Pct($v) { if ($null -ne $v) { "{0:0}%" -f [double]$v } else { "?" } }

# Tooltip: NotifyIcon.Text in .NET Framework accetta al massimo 63 caratteri.
function Get-TrayTooltip($accounts, [string]$active, [bool]$isPeak) {
    $peak = if ($isPeak) { "PEAK" } else { "off-peak" }
    $s = $accounts[$active]
    if ($accounts.Count -le 1) {
        $text = if ($s.Error) { "Claude - $($s.Error)" } else {
            "Claude  Sess:$(Format-Pct $s.Session.Utilization) | Week:$(Format-Pct $s.Week.Utilization) | $peak"
        }
    } else {
        $parts = foreach ($e in @($accounts.Keys)) {
            $a = $accounts[$e]
            $mark = if ($e -eq $active) { [string][char]0x25CF } else { "" }
            "$mark$(($e -split '@')[0]) $(Format-Pct $a.Session.Utilization)/$(Format-Pct $a.Week.Utilization)"
        }
        $text = ($parts -join " | ") + " | $peak"
    }
    return $text.Substring(0, [Math]::Min(63, $text.Length))
}

function Get-BalloonText($accounts, [string]$active) {
    $lines = foreach ($e in @($accounts.Keys)) {
        $st = $accounts[$e]
        $who = if ($accounts.Count -gt 1) { if ($e -eq $active) { "$e (in use)`n" } else { "$e`n" } } else { "" }
        if ($st.Error) { "$who$($st.Error)" } else {
            $sr = if ($st.Session.ResetSince) { "reset" } elseif ($st.Session.ResetsAt) { $st.Session.ResetsAt.ToString("HH:mm") } else { "?" }
            $wr = if ($st.Week.ResetSince) { "reset" } elseif ($st.Week.ResetsAt) { $st.Week.ResetsAt.ToString("ddd dd/MM HH:mm") } else { "?" }
            "${who}Session: $(Format-Pct $st.Session.Utilization)   [resets $sr]`nWeekly: $(Format-Pct $st.Week.Utilization)   [resets $wr]"
        }
    }
    return ($lines -join "`n")
}

# ─── Barra testo ──────────────────────────────────────────────────────────────
function Draw-Bar([double]$pct, [int]$width = 18) {
    $filled = [math]::Max(0,[math]::Min($width,[math]::Round($pct/100*$width)))
    return "[" + ("=" * $filled) + (" " * ($width-$filled)) + "]"
}

# ─── Velocità run precedente (fallback quando la finestra corrente non ha ancora dati) ──
# $field: "sess" o "week" (chiave nella history). $resetDrop: calo che segnala un reset
# di finestra. $gapMin: buco temporale oltre il quale non ci si fida della continuità.
function Get-PreviousRate([datetime]$beforeTime, [string]$field, [double]$resetDrop, [double]$gapMin, [string]$email = "") {
    try {
        if (-not (Test-Path $HistoryFile)) { return $null }
        $raw = Read-JsonFile $HistoryFile
        if (-not $raw) { return $null }
        $pts = @()
        foreach ($h in @($raw)) {
            $v = $h.$field
            if ($null -eq $v) { continue }
            # Solo l'account richiesto; le voci senza email precedono i piu' account.
            if ($email -and $h.email -and $h.email -ne $email) { continue }
            $dt = Parse-IsoDate $h.ts
            if (-not $dt -or $dt -ge $beforeTime) { continue }
            $pts += [pscustomobject]@{ dt = $dt; val = [double]$v }
        }
        $pts = @($pts | Sort-Object dt)
        if ($pts.Count -lt 2) { return $null }
        # Segmenta in "run": una nuova run inizia quando il valore crolla (reset
        # di finestra) o quando c'e' un buco temporale troppo grande.
        $runs = @(); $cur = @($pts[0])
        for ($i = 1; $i -lt $pts.Count; $i++) {
            $prev = $pts[$i-1]; $p = $pts[$i]
            $gapActual = ($p.dt - $prev.dt).TotalMinutes
            if ($p.val -lt ($prev.val - $resetDrop) -or $gapActual -gt $gapMin) {
                $runs += ,$cur
                $cur = @($p)
            } else {
                $cur += $p
            }
        }
        $runs += ,$cur
        $lastRun = $runs[-1]
        if ($lastRun.Count -lt 2) { return $null }
        $first = $lastRun[0]; $last = $lastRun[-1]
        $elapsedMin = ($last.dt - $first.dt).TotalMinutes
        if ($elapsedMin -le 0) { return $null }
        $rate = ($last.val - $first.val) / $elapsedMin
        if ($rate -le 0) { return $null }
        return $rate
    } catch { return $null }
}
function Get-PreviousSessionRate([datetime]$beforeTime, [string]$email = "") { return Get-PreviousRate $beforeTime "sess" 5 360 $email }
function Get-PreviousWeekRate([datetime]$beforeTime, [string]$email = "")    { return Get-PreviousRate $beforeTime "week" 5 4320 $email }

# ─── Menu contestuale ─────────────────────────────────────────────────────────
function Format-Ago([datetime]$t) {
    $m = [math]::Round(((Get-Date) - $t).TotalMinutes)
    if ($m -lt 1)    { return "just now" }
    if ($m -lt 60)   { return "${m} min ago" }
    if ($m -lt 1440) { return "$([math]::Floor($m/60))h $($m%60)min ago" }
    return "$([math]::Floor($m/1440))d $([math]::Floor(($m%1440)/60))h ago"
}

# Mostra solo le voci dell'account $email (Tag "acct:<email>"); le voci comuni
# non hanno Tag. Available, non Visible: vale anche a menu chiuso.
function Set-MenuTab($menu, [string]$email) {
    $menu.SuspendLayout()
    foreach ($it in $menu.Items) {
        $t = "$($it.Tag)"
        if ($t.StartsWith("acct:")) { $it.Available = ($t -eq "acct:$email") }
    }
    $menu.ResumeLayout()
}

# $accounts: email -> statistiche (Get-AllAccountStats). Con piu' account, una
# scheda per account in cima al menu; $active (in uso da Claude Code) ha il pallino.
# $existingMenu: se passato, ripopola quel ContextMenuStrip invece di crearne uno
# nuovo (usato per aggiornare i dati mentre il menu e' aperto/pinnato).
function Build-Menu($accounts, [string]$active, $existingMenu = $null) {
    $isNewMenu = ($null -eq $existingMenu)
    if ($isNewMenu) {
        $menu = New-Object System.Windows.Forms.ContextMenuStrip
    } else {
        $menu = $existingMenu
        $menu.SuspendLayout()
        $menu.Items.Clear()
    }
    function Add-Label($text,[bool]$bold=$false) {
        $item = New-Object System.Windows.Forms.ToolStripMenuItem
        $item.Text = $text; $item.Enabled = $false
        $item.Font = if ($bold) { New-Object System.Drawing.Font("Segoe UI",9,[System.Drawing.FontStyle]::Bold) } `
                     else       { New-Object System.Drawing.Font("Consolas",8.5) }
        $menu.Items.Add($item) | Out-Null
    }
    function Add-Sep() { $menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null }

    $emails = @($accounts.Keys)
    $multi  = ($emails.Count -gt 1)
    $sel    = if ($script:selectedEmail -and $accounts.Contains($script:selectedEmail)) { $script:selectedEmail } else { $active }

    if ($multi) {
        $tabs = New-Object System.Windows.Forms.TabControl
        $tabFont = New-Object System.Drawing.Font("Segoe UI",9)
        $tabs.Font = $tabFont
        $tabW = 16
        foreach ($e in $emails) {
            $tp = New-Object System.Windows.Forms.TabPage
            $tp.Name = $e
            $tp.Text = if ($e -eq $active) { [string][char]0x25CF + " $e" } else { $e }
            $tabs.TabPages.Add($tp)
            $tabW += [System.Windows.Forms.TextRenderer]::MeasureText($tp.Text, $tabFont).Width + 12
        }
        $tabs.SelectedIndex = [math]::Max(0, [array]::IndexOf($emails, $sel))
        $tabs.add_SelectedIndexChanged({
            param($sndr,$e)
            $script:selectedEmail = $sndr.SelectedTab.Name
            if ($script:accounts) { $script:stats = $script:accounts[$script:selectedEmail] }
            $owner = if ($sndr.Parent -is [System.Windows.Forms.ToolStrip]) { $sndr.Parent } else { $script:menuObj.Menu }
            Set-MenuTab $owner $script:selectedEmail
        })
        $tabHost = New-Object System.Windows.Forms.ToolStripControlHost($tabs)
        $tabHost.Name     = "TabsHost"
        $tabHost.AutoSize = $false
        # Altezza = sola fila delle linguette: le pagine restano vuote.
        $tabHost.Size     = New-Object System.Drawing.Size([math]::Max(300, $tabW), 24)
        $menu.Items.Add($tabHost) | Out-Null
    }

    $miPin = New-Object System.Windows.Forms.ToolStripMenuItem
    $miPin.Name = "PinMenuItem"
    $miPin.Text = if ($script:menuPinned) { "  Pinned (click to unpin)" } else { "  Pin menu (keep open)" }
    $miPin.CheckOnClick = $true
    $miPin.Checked = $script:menuPinned
    $miPin.add_Click({
        param($sndr,$e)
        $script:menuPinned = $sndr.Checked
        $sndr.Text = if ($sndr.Checked) { "  Pinned (click to unpin)" } else { "  Pin menu (keep open)" }
        Save-Settings
    })
    $menu.Items.Add($miPin) | Out-Null

    if ($isNewMenu) {
        $menu.add_ItemClicked({
            param($sndr,$e)
            $script:lastMenuClickedName = $e.ClickedItem.Name
        })
        $menu.add_Closing({
            param($sndr,$e)
            if ($e.CloseReason -eq [System.Windows.Forms.ToolStripDropDownCloseReason]::ItemClicked -and
                $script:lastMenuClickedName -in @("PinMenuItem","TabsHost")) {
                $e.Cancel = $true
                return
            }
            if ($script:menuPinned -and (
                    $e.CloseReason -eq [System.Windows.Forms.ToolStripDropDownCloseReason]::AppClicked -or
                    $e.CloseReason -eq [System.Windows.Forms.ToolStripDropDownCloseReason]::AppFocusChange)) {
                $e.Cancel = $true
            }
        })
    }

    $ownEmail = Get-AccountEmail
    foreach ($acctEmail in $emails) {
        $start = $menu.Items.Count
        $stats = $accounts[$acctEmail]
        $isActive = ($acctEmail -eq $active)
        Add-Sep
        # Piano: dal dato stesso; dai file locali solo se e' il login di questo utente.
        $plan = if ($stats.Plan) { Get-AccountPlan $stats.Plan } elseif ($acctEmail -and $acctEmail -eq $ownEmail) { Get-AccountPlan } else { $null }
        $label = if ($plan) { "Claude $plan" } else { "Claude usage" }
        $headerText = if ($acctEmail) { "  ${label}: $acctEmail" } else { "  $label" }
        Add-Label $headerText $true
        if ($multi) {
            if ($isActive) { Add-Label "  In use by Claude Code" }
            else           { Add-Label ("  Not in use - last seen {0}" -f (Format-Ago $stats.LastUpdated)) }
        }
        # Proiezione: non per un account fermo, i cui valori sono vecchi.
        $showPace = $isActive -or -not $stats.Cached

        Add-Sep
        if ($stats.Error) {
            Add-Label "  $($stats.Error)"
        } else {
            if ($null -ne $stats.Session.Utilization) {
                $pct = $stats.Session.Utilization; $rst = $stats.Session.ResetsAt
                $mins = if ($rst) { [math]::Round(($rst-(Get-Date)).TotalMinutes) } else { 0 }
                $relPart = if ($mins -le 0) { "now" } elseif ($mins -lt 60) { "in ${mins}min" } else { "in $([math]::Floor($mins/60))h $($mins%60)min" }
                $rstStr = if ($stats.Session.ResetSince) { "reset since last seen" } elseif (-not $rst) { "?" } else { $rst.ToString("ddd HH:mm") + "  ($relPart)" }
                Add-Label "  Current session (5h)" $true
                Add-Label ("  {0}  {1,5:N1}%" -f (Draw-Bar $pct), $pct)
                Add-Label "  Resets: $rstStr"
                if ($rst -and $showPace) {
                    $sessionStart    = $rst.AddHours(-5)
                    $elapsedMin      = ((Get-Date) - $sessionStart).TotalMinutes
                    $remainMin       = ($rst - (Get-Date)).TotalMinutes
                    $rateFromCurrent = ($elapsedMin -ge 2 -and $pct -gt 0)
                    $rate = if ($rateFromCurrent) { $pct / $elapsedMin } else { Get-PreviousSessionRate $sessionStart $acctEmail }
                    $isGuess = (-not $rateFromCurrent) -and $rate -and $rate -gt 0
                    if ($rate -and $rate -gt 0 -and $remainMin -gt 0) {
                        $minutesToFull = ([math]::Max(0,100 - $pct)) / $rate
                        if ($minutesToFull -le $remainMin) {
                            $projTime = (Get-Date).AddMinutes($minutesToFull)
                            $paceStr  = "100% at " + $projTime.ToString("HH:mm")
                        } else {
                            $pctAtReset = $pct + $rate * $remainMin
                            $leftPct    = [math]::Max(0,[math]::Round(100 - $pctAtReset))
                            $paceStr    = "~${leftPct}% left at reset"
                        }
                    } else {
                        $paceStr = "--  (insufficient data)"
                    }
                    $paceLabel = if ($isGuess) { "Guess (prev. session speed)" } else { "On pace" }
                    Add-Label "  ${paceLabel}: $paceStr"
                }
            }
            Add-Sep
            if ($null -ne $stats.Week.Utilization) {
                $pct = $stats.Week.Utilization; $rst = $stats.Week.ResetsAt
                $daysLeft = if ($rst) { [math]::Round(($rst-(Get-Date)).TotalDays,1) } else { 0 }
                $rstStr = if ($stats.Week.ResetSince) { "reset since last seen" } elseif ($rst) { $rst.ToString("ddd MM/dd  HH:mm") + "  (in $daysLeft d)" } else { "?" }
                Add-Label "  Current week (7d)" $true
                Add-Label ("  {0}  {1,5:N1}%" -f (Draw-Bar $pct), $pct)
                Add-Label "  Resets: $rstStr"
                if ($rst -and $showPace) {
                    $weekStart       = $rst.AddDays(-7)
                    $elapsedMin      = ((Get-Date) - $weekStart).TotalMinutes
                    $remainMin       = ($rst - (Get-Date)).TotalMinutes
                    $rateFromCurrent = ($elapsedMin -ge 2 -and $pct -gt 0)
                    $rate = if ($rateFromCurrent) { $pct / $elapsedMin } else { Get-PreviousWeekRate $weekStart $acctEmail }
                    $isGuess = (-not $rateFromCurrent) -and $rate -and $rate -gt 0
                    if ($rate -and $rate -gt 0 -and $remainMin -gt 0) {
                        $minutesToFull = ([math]::Max(0,100 - $pct)) / $rate
                        if ($minutesToFull -le $remainMin) {
                            $projTime = (Get-Date).AddMinutes($minutesToFull)
                            $paceStr  = "100% at " + $projTime.ToString("ddd HH:mm")
                        } else {
                            $pctAtReset = $pct + $rate * $remainMin
                            $leftPct    = [math]::Max(0,[math]::Round(100 - $pctAtReset))
                            $paceStr    = "~${leftPct}% left at reset"
                        }
                    } else {
                        $paceStr = "--  (insufficient data)"
                    }
                    $paceLabel = if ($isGuess) { "Guess (prev. week speed)" } else { "On pace" }
                    Add-Label "  ${paceLabel}: $paceStr"
                }
            }
            if ($null -ne $stats.ExtraUsage) {
                Add-Sep
                $euText = if ($stats.ExtraUsage) { "  Extra usage: ENABLED" } else { "  Extra usage: disabled" }
                Add-Label $euText
            }
        }
        Add-Sep
        $cacheNote = if ($stats.Cached) { " (cached)" } else { "" }
        $updFmt = if ($stats.LastUpdated -and ([datetime]$stats.LastUpdated).Date -ne (Get-Date).Date) { "{0:ddd MM/dd HH:mm}" } else { "{0:HH:mm:ss}" }
        Add-Label ("  Updated: $updFmt{1}" -f $stats.LastUpdated, $cacheNote)
        for ($i = $start; $i -lt $menu.Items.Count; $i++) { $menu.Items[$i].Tag = "acct:$acctEmail" }
    }

    Add-Sep
    $ptNow    = Get-PacificTime
    $dow      = [int]$ptNow.DayOfWeek
    $isPeakM  = ($dow -ge 1 -and $dow -le 5 -and $ptNow.Hour -ge 5 -and $ptNow.Hour -lt 11)
    if ($isPeakM) {
        # ends today at 11:00 PT
        $endPT    = $ptNow.Date.AddHours(11)
        $minLeft  = [math]::Round(($endPT - $ptNow).TotalMinutes)
        $timeStr  = if ($minLeft -ge 60) { "$([math]::Floor($minLeft/60))h $($minLeft % 60)min" } else { "${minLeft}min" }
        $peakText = "  Peak hours: ACTIVE  (ends in $timeStr)"
    } else {
        # find next Mon-Fri 05:00 PT
        $next = $ptNow.Date.AddHours(5)
        if ($ptNow.Hour -ge 11) { $next = $next.AddDays(1) }
        for ($i = 0; $i -lt 7; $i++) {
            $d = [int]$next.DayOfWeek
            if ($d -ge 1 -and $d -le 5) { break }
            $next = $next.AddDays(1)
        }
        $minLeft  = [math]::Round(($next - $ptNow).TotalMinutes)
        $timeStr  = if ($minLeft -ge 1440) { "$([math]::Floor($minLeft/1440))d $([math]::Floor(($minLeft%1440)/60))h" } `
                    elseif ($minLeft -ge 60) { "$([math]::Floor($minLeft/60))h $($minLeft % 60)min" } `
                    else { "${minLeft}min" }
        $peakText = "  Peak hours: off  (starts in $timeStr)"
    }
    Add-Label $peakText
    Add-Sep
    $miHistory = New-Object System.Windows.Forms.ToolStripMenuItem; $miHistory.Text = "  Usage history..."
    $menu.Items.Add($miHistory) | Out-Null
    $miRefresh = New-Object System.Windows.Forms.ToolStripMenuItem; $miRefresh.Text = "  Refresh now"
    $menu.Items.Add($miRefresh) | Out-Null
    $miRate = New-Object System.Windows.Forms.ToolStripMenuItem; $miRate.Text = "  Refresh rate"
    foreach ($m in $RefreshRatePresets) {
        $mi = New-Object System.Windows.Forms.ToolStripMenuItem
        $mi.Text    = "  $m min"
        $mi.Checked = ($m -eq $script:refreshIntervalMinutes)
        $mi.Tag     = $m
        $mi.add_Click({
            param($sndr,$e)
            foreach ($sibling in $sndr.OwnerItem.DropDownItems) { $sibling.Checked = $false }
            $sndr.Checked = $true
            $script:refreshIntervalMinutes = [int]$sndr.Tag
            $script:refreshTimer.Interval  = [int]$sndr.Tag * 60000
            Save-Settings
        })
        $miRate.DropDownItems.Add($mi) | Out-Null
    }
    $menu.Items.Add($miRate) | Out-Null
    $miExit = New-Object System.Windows.Forms.ToolStripMenuItem; $miExit.Text = "  Exit"
    $menu.Items.Add($miExit) | Out-Null
    Set-MenuTab $menu $sel
    if (-not $isNewMenu) { $menu.ResumeLayout() }
    return [pscustomobject]@{ Menu=$menu; History=$miHistory; Refresh=$miRefresh; Exit=$miExit }
}

# ─── Icona tray ───────────────────────────────────────────────────────────────
function New-TrayIcon([double]$pctSess=0,[double]$pctWeek=0,[bool]$isPeak=$false) {
    function BarColor([double]$p) {
        if ($p -ge 100) { return [System.Drawing.Color]::FromArgb(55,55,55) }
        if ($p -ge 95)  { return [System.Drawing.Color]::FromArgb(100,0,0) }
        if ($p -ge 80)  { return [System.Drawing.Color]::FromArgb(200,30,30) }
        if ($p -ge 50)  { return [System.Drawing.Color]::FromArgb(200,120,0) }
        return [System.Drawing.Color]::FromArgb(40,160,65)
    }
    $bmp = New-Object System.Drawing.Bitmap(16,16)
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::FromArgb(25,25,25))
    # Bordo 1px tutto intorno: giallo durante peak hour, blu fuori peak
    $borderColor = if ($isPeak) { [System.Drawing.Color]::FromArgb(255,215,0) } else { [System.Drawing.Color]::FromArgb(60,120,255) }
    $br = New-Object System.Drawing.SolidBrush($borderColor)
    $g.FillRectangle($br,0,0,16,1)
    $g.FillRectangle($br,0,15,16,1)
    $g.FillRectangle($br,0,0,1,16)
    $g.FillRectangle($br,15,0,1,16)
    $br.Dispose()
    # Barra sessione dentro il bordo (righe 1-7, larghezza max 14px)
    $wS = [math]::Max(1,[math]::Round($pctSess/100*14))
    $br = New-Object System.Drawing.SolidBrush((BarColor $pctSess))
    $g.FillRectangle($br,1,1,$wS,7); $br.Dispose()
    # Separatore
    $br = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(10,10,10))
    $g.FillRectangle($br,1,8,14,1); $br.Dispose()
    # Barra settimana (righe 9-14, larghezza max 14px)
    $wW = [math]::Max(1,[math]::Round($pctWeek/100*14))
    $br = New-Object System.Drawing.SolidBrush((BarColor $pctWeek))
    $g.FillRectangle($br,1,9,$wW,6); $br.Dispose()
    $g.Dispose()
    $icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    $bmp.Dispose()
    return $icon
}

# ─── Init ─────────────────────────────────────────────────────────────────────
try {

Load-Settings

$tray      = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = New-TrayIcon
$script:lastIconHandle = $tray.Icon.Handle
$tray.Visible = $true
$tray.Text    = "Claude Code Usage - loading..."

$script:hiddenForm = New-Object System.Windows.Forms.Form
$script:hiddenForm.ShowInTaskbar = $false
$script:hiddenForm.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$script:hiddenForm.Size = New-Object System.Drawing.Size(1,1)
$script:hiddenForm.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$script:hiddenForm.Location = New-Object System.Drawing.Point(-32000,-32000)
$script:hiddenForm.Show(); $script:hiddenForm.Hide()

Update-Accounts
$script:menuObj = Build-Menu $script:accounts $script:activeEmail

# Icona, avvisi e file evento seguono l'account in uso da Claude Code.
function Update-Tray {
    $s = $script:accounts[$script:activeEmail]
    $isPeak = Get-IsPeakHour
    $tray.Text = Get-TrayTooltip $script:accounts $script:activeEmail $isPeak
    if ($s.Error) { return }

    $sPct   = if ($null -ne $s.Session.Utilization) { [double]$s.Session.Utilization } else { 0.0 }
    $wPct   = if ($null -ne $s.Week.Utilization)    { [double]$s.Week.Utilization }    else { 0.0 }
    $maxPct = [math]::Max($sPct, $wPct)
    $sR = [math]::Round($sPct); $wR = [math]::Round($wPct)
    if ($sR -ne $script:lastSessPct -or $wR -ne $script:lastWeekPct -or $isPeak -ne $script:lastIconPeak) {
        $script:lastSessPct  = $sR
        $script:lastWeekPct  = $wR
        $script:lastIconPeak = $isPeak
        $newIcon = New-TrayIcon $sPct $wPct $isPeak
        if ($script:lastIconHandle -ne [IntPtr]::Zero) {
            try { [Win32.NativeMethods]::DestroyIcon($script:lastIconHandle) | Out-Null } catch { }
        }
        $script:lastIconHandle = $newIcon.Handle
        $tray.Icon = $newIcon
    }
    if ($maxPct -ge 90 -and -not $script:notified90) {
        $script:notified90 = $true
        $tray.ShowBalloonTip(8000,"Claude Code - Limit almost reached","Usage at $([math]::Round($maxPct,1))%",[System.Windows.Forms.ToolTipIcon]::Warning)
    } elseif ($maxPct -ge 85 -and -not $script:notified85) {
        $script:notified85 = $true
        $tray.ShowBalloonTip(6000,"Claude Code - High usage","Usage at $([math]::Round($maxPct,1))%",[System.Windows.Forms.ToolTipIcon]::Warning)
    } elseif ($maxPct -lt 75) {
        $script:notified85 = $false; $script:notified90 = $false
    }
    # Session event file — per trigger agenti esterni
    $curResetsAt = if ($s.Session.ResetsAt) { $s.Session.ResetsAt.ToString("o") } else { "" }
    # Cambio di account (/login) non e' un reset: confronta solo lo stesso account.
    if ($script:activeEmail -ne $script:lastSessEmail) { $script:lastSessResetsAt = ""; $script:lastSessEmail = $script:activeEmail }
    if ($curResetsAt -and $script:lastSessResetsAt -and $curResetsAt -ne $script:lastSessResetsAt) {
        # ResetsAt cambiato = nuova sessione 5h iniziata
        try {
            $evJson = "{`"event`":`"session_reset`",`"timestamp`":`"$([datetime]::Now.ToString('o'))`",`"utilization`":$sPct,`"resetsAt`":`"$curResetsAt`"}"
            [System.IO.File]::WriteAllText($SessionEventFile, $evJson, [System.Text.Encoding]::UTF8)
        } catch { }
    }
    if ($sPct -ge 95 -and $curResetsAt) {
        try {
            $evJson = "{`"event`":`"session_full`",`"timestamp`":`"$([datetime]::Now.ToString('o'))`",`"utilization`":$sPct,`"resetsAt`":`"$curResetsAt`"}"
            [System.IO.File]::WriteAllText($SessionEventFile, $evJson, [System.Text.Encoding]::UTF8)
        } catch { }
    }
    if ($curResetsAt) { $script:lastSessResetsAt = $curResetsAt }
}
Update-Tray

$script:DoShowHistory = { Show-HistoryChart }

# DoRefresh: aggiorna dati API e icona (chiamato da timer e "Aggiorna ora")
$script:DoRefresh = {
    try {
        Update-Accounts
        Update-Tray
        # Se il menu e' aperto (es. pinnato), ripopola i suoi contenuti sul posto
        # cosi' i dati mostrati non restano bloccati al momento dell'apertura.
        if ($script:menuObj -and $script:menuObj.Menu.Visible) {
            $script:menuObj = Build-Menu $script:accounts $script:activeEmail $script:menuObj.Menu
            $script:menuObj.History.add_Click($script:DoShowHistory)
            $script:menuObj.Refresh.add_Click($script:DoRefresh)
            $script:menuObj.Exit.add_Click($script:DoExit)
        }
    } catch {
        "$([datetime]::Now) DoRefresh ERRORE: $_" | Out-File $LogFile -Append -Encoding UTF8
    }
}

$script:DoExit = {
    $script:refreshTimer.Stop(); $script:refreshTimer.Dispose()
    if ($script:hiddenForm) { $script:hiddenForm.Dispose() }
    $tray.Visible = $false; $tray.Dispose()
    [System.Windows.Forms.Application]::Exit()
}

$script:menuObj.History.add_Click($script:DoShowHistory)
$script:menuObj.Refresh.add_Click($script:DoRefresh)
$script:menuObj.Exit.add_Click($script:DoExit)

$tray.add_MouseClick({
    param($s,$e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right) {
        if ($script:menuObj -and $script:menuObj.Menu.Visible) {
            # Menu already open (e.g. pinned): right-click again to close it
            $script:menuObj.Menu.Close()
            return
        }
        [Win32.NativeMethods]::SetForegroundWindow($script:hiddenForm.Handle) | Out-Null
        # Ricostruisce menu da cache (nessuna chiamata API)
        $old = $script:menuObj
        # Ogni apertura parte dalla scheda dell'account in uso.
        $script:selectedEmail = $null
        $script:stats = $script:accounts[$script:activeEmail]
        $script:menuObj = Build-Menu $script:accounts $script:activeEmail
        $script:menuObj.History.add_Click($script:DoShowHistory)
        $script:menuObj.Refresh.add_Click($script:DoRefresh)
        $script:menuObj.Exit.add_Click($script:DoExit)
        if ($old) { $old.Menu.Dispose() }
        # Mostra nel punto corretto (PointToClient converte coord schermo → client)
        $pos = $script:hiddenForm.PointToClient([System.Windows.Forms.Cursor]::Position)
        $script:menuObj.Menu.Show($script:hiddenForm, $pos)
    } elseif ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $msg = Get-BalloonText $script:accounts $script:activeEmail
        $s.ShowBalloonTip(5000,"Claude Code /usage",$msg,[System.Windows.Forms.ToolTipIcon]::Info)
    }
})

# Auto-refresh (intervallo configurabile da "Refresh rate")
$script:refreshTimer = New-Object System.Windows.Forms.Timer
$script:refreshTimer.Interval = $script:refreshIntervalMinutes * 60000
$script:refreshTimer.add_Tick({ & $script:DoRefresh })
$script:refreshTimer.Start()

[System.Windows.Forms.Application]::Run()

} catch {
    "$([datetime]::Now) ERRORE: $_`n$($_.ScriptStackTrace)" |
        Out-File $LogFile -Append -Encoding UTF8
}
