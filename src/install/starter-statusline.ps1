# Your Claude Code statusline.
#
# Oriel wrote this file because you did not have a statusline, and it needed one to
# attach to. It is yours now: an ordinary script you can read, edit, or throw away.
# Nothing here is managed except the block marked "oriel tee", which the installer
# inserts and the uninstaller removes.
#
# It shows: model │ effort │ context use │ 5-hour window │ 7-day window, and the
# current directory on a second line.
#
# The reset time is adaptive: a bare clock time when the reset falls today, weekday
# plus clock time otherwise. A weekday is exactly enough resolution for a seven-day
# window, and a bare "10:29" on one reads as today and is simply wrong.
#
# Must parse under Windows PowerShell 5.1 and must keep its UTF-8 BOM: 5.1 reads a
# BOM-less .ps1 as ANSI, and the glyphs below then fail to parse rather than merely
# render wrong.

$ErrorActionPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

# --- Read stdin (decode bytes explicitly as UTF-8) --------------------------
# Read once, into a variable, and keep it. Standard input cannot be read twice, so a
# statusline that pipes it straight through leaves nothing for anything else to use.
$reader = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), [System.Text.UTF8Encoding]::new($false))
$raw = $reader.ReadToEnd()
try { $d = $raw | ConvertFrom-Json } catch { $d = $null }
if (-not $d) { Write-Host ""; exit 0 }

# --- ANSI helpers -----------------------------------------------------------
$e = [char]27
function C($r, $g, $b) { "$e[38;2;$r;$g;${b}m" }   # truecolor foreground
$RESET = "$e[0m"
$BOLD  = "$e[1m"
$DIM   = "$e[2m"

# Palette (tuned for dark themes)
$cModel = C 137 180 250    # blue
$cDir   = C 148 226 213    # teal
$cSep   = C 88 91 112      # muted grey separator
$cLabel = C 108 112 134    # dim label
$cReset = C 186 194 222    # brighter than the dim label

# The same green/amber/red bands the widget uses, so the terminal and the pill agree.
function UsageColor($pct) {
    if ($null -eq $pct) { return (C 108 112 134) }
    if ($pct -lt 50) { return (C 166 227 161) }
    elseif ($pct -lt 80) { return (C 249 226 175) }
    else { return (C 243 139 168) }
}

function EffortColor($lvl) {
    switch ($lvl) {
        'low'    { C 147 153 178 }
        'medium' { C 137 220 235 }
        'high'   { C 166 227 161 }
        'xhigh'  { C 249 226 175 }
        'max'    { C 245 194 231 }
        default  { C 205 214 244 }
    }
}

# --- A compact progress bar --------------------------------------------------
function Bar($pct, $width = 10) {
    if ($null -eq $pct) { $pct = 0 }
    $pct = [math]::Max(0, [math]::Min(100, [double]$pct))
    $filled = [int][math]::Round($pct / 100 * $width)
    $col = UsageColor $pct
    ("{0}{1}{2}{3}" -f $col, ('█' * $filled), $DIM, ('░' * ($width - $filled))) + $RESET
}

# A small five-step donut, for the window segments.
function Donut($pct) {
    if ($null -eq $pct) { $pct = 0 }
    $pct = [math]::Max(0, [math]::Min(100, [double]$pct))
    $glyphs = @([char]0x25EF, [char]0x25D4, [char]0x25D1, [char]0x25D5, [char]0x2B24)  # ◯ ◔ ◑ ◕ ⬤
    $glyphs[[int][math]::Round($pct / 100 * 4)]
}

# --- Reset-time text ---------------------------------------------------------
# Clock time when the reset falls today; weekday plus clock time otherwise. The
# 5-hour window therefore reads as a bare time permanently, and the 7-day one
# returns to one as it comes due.
function ResetText($epoch) {
    if (-not $epoch) { return '' }
    $rt = [DateTimeOffset]::FromUnixTimeSeconds([long]$epoch).ToLocalTime()
    if ($rt.Date -eq (Get-Date).Date) { return " $cReset$($rt.ToString('HH:mm'))$RESET" }
    return " $cReset$($rt.ToString('ddd HH:mm'))$RESET"
}

# The 5h and 7d segments are identical in shape, so they are one function. Returns
# nothing when the window is absent — rate-limit data only exists on Pro/Max accounts
# and only after the first API response of a session.
function WindowSegment($window, $label) {
    if ($null -eq $window) { return $null }
    $pct = $window.used_percentage
    if ($null -eq $pct) { return $null }
    $col = UsageColor $pct
    $pctTxt = "{0:N0}" -f [double]$pct
    "$col$(Donut $pct)$RESET $col$pctTxt%$RESET $cLabel($label)$RESET$(ResetText $window.resets_at)"
}

$sep = " $cSep" + '│' + "$RESET "
$segments = @()

# --- Model -------------------------------------------------------------------
$model = $d.model.display_name
if ($model) { $segments += "$cModel$BOLD$model$RESET" }

# --- Effort ------------------------------------------------------------------
$effort = $d.effort.level
if ($effort) { $segments += "$(EffortColor $effort)$effort$RESET" }

# --- Context use -------------------------------------------------------------
# Labelled "(ctx)" so it cannot be mistaken for one of the rate-limit windows.
$ctxPct = $d.context_window.used_percentage
if ($null -eq $ctxPct) { $ctxPct = 0 }
$col = UsageColor $ctxPct
$pctTxt = "{0:N0}" -f [double]$ctxPct
$segments += (Bar $ctxPct) + " $col$pctTxt%$RESET $cLabel(ctx)$RESET"

# --- Rate-limit windows: 5-hour then 7-day -----------------------------------
foreach ($w in @(
    @{ Data = $d.rate_limits.five_hour; Label = '5h' },
    @{ Data = $d.rate_limits.seven_day; Label = '7d' }
)) {
    $seg = WindowSegment $w.Data $w.Label
    if ($seg) { $segments += $seg }
}

# --- Directory (leaf) on a second line ---------------------------------------
$dir = $d.workspace.current_dir
if (-not $dir) { $dir = $d.cwd }
$line2 = ''
if ($dir) { $line2 = "$cDir$(Split-Path $dir -Leaf)$RESET" }

# --- Emit --------------------------------------------------------------------
$out = ($segments -join $sep)
if ($line2) { $out += "`n" + $line2 }
Write-Host $out -NoNewline
